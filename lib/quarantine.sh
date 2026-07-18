#!/usr/bin/env bash
# devpurge - Quarantine: recoverable staging for AI-triage deletions
#
# Nothing judged by heuristics or AI is deleted directly. It is moved into
# ~/.devpurge/quarantine/ with a manifest, restorable for QUARANTINE_DAYS
# (default 30), and only expired entries are actually deleted.
#
# Manifest format (TSV): ID  DATE_EPOCH  ORIGINAL_PATH  SIZE_KB  STORED_PATH  REASON
#
# NOTE: lives under Application Support, NOT ~/.devpurge — the curl installer
# wipes ~/.devpurge on reinstall and must never take the quarantine with it.

DEVPURGE_QUARANTINE_DIR="${DEVPURGE_QUARANTINE_DIR:-${HOME}/Library/Application Support/devpurge/quarantine}"
DEVPURGE_QUARANTINE_DAYS="${DEVPURGE_QUARANTINE_DAYS:-30}"

_dp_quarantine_manifest() {
  printf '%s/manifest.tsv' "$DEVPURGE_QUARANTINE_DIR"
}

# Protected-pattern check: paths whose name suggests irreplaceable material
# (legal evidence, court filings, etc.) are refused by quarantine AND by the
# regular cleanup path. Patterns are literal substrings matched against the
# full path. Extend via ~/.devpurgerc: protect=SUBSTRING
DEVPURGE_PROTECT_PATTERNS=(
  "証拠" "裁判" "訴訟" "別訴" "告訴" "準備書面" "判決" "弁護士" "法務"
  "原本" "契約書"
)

devpurge_is_protected() {
  # NFC-normalize: an NFD-named "証拠" folder (Finder-created) must match the
  # NFC patterns in this file
  local target
  target=$(_dp_nfc "$1")
  local pat
  for pat in "${DEVPURGE_PROTECT_PATTERNS[@]+"${DEVPURGE_PROTECT_PATTERNS[@]}"}"; do
    [[ -z "$pat" ]] && continue
    case "$target" in
      *"$pat"*) return 0 ;;
    esac
  done
  return 1
}

# Move a path into quarantine.
# Args: $1=path $2=reason
devpurge_quarantine_add() {
  local target="$1" reason="${2:-manual}"

  # Normalize: strip trailing slash, require absolute existing path under $HOME
  target="${target%/}"
  if [[ -z "$target" || "$target" != /* || ! -e "$target" ]]; then
    dp_error "quarantine: path not found: $target"
    return 1
  fi
  # TSV manifest cannot represent control characters; a tab/newline in the
  # path would corrupt the record and make the item silently unrestorable
  case "$target" in
    *$'\t'*|*$'\n'*|*$'\r'*)
      dp_error "quarantine: REFUSED - path contains tab/newline (rename it first)"
      return 1
      ;;
  esac
  case "$target" in
    "$HOME"/*) ;;
    *) dp_error "quarantine: only paths under \$HOME are supported"; return 1 ;;
  esac
  case "$target" in
    "$DEVPURGE_QUARANTINE_DIR"*) dp_error "quarantine: already quarantined"; return 1 ;;
  esac
  if devpurge_is_protected "$target"; then
    dp_error "quarantine: REFUSED - path matches a protected pattern (legal material?)"
    dp_error "  $target"
    return 1
  fi
  if ! devpurge_rm_guard "$target"; then
    dp_error "quarantine: path failed the safety guard: $target"
    return 1
  fi

  mkdir -p "$DEVPURGE_QUARANTINE_DIR" || return 1
  local manifest
  manifest=$(_dp_quarantine_manifest)

  local size_kb
  size_kb=$(_dp_size_kb "$target")
  [[ -z "$size_kb" ]] && size_kb=0

  # Next ID: max existing + 1 (line counting collides after manual edits)
  local max_id=0
  if [[ -f "$manifest" ]]; then
    max_id=$(cut -f1 "$manifest" 2>/dev/null | sed 's/^Q0*//' | sort -rn | head -1 || true)
    case "$max_id" in
      ''|*[!0-9]*) max_id=0 ;;
    esac
  fi
  local qid
  qid=$(printf "Q%03d" $((max_id + 1)))

  local stored="${DEVPURGE_QUARANTINE_DIR}/${qid}-$(basename "$target")"
  if ! mv "$target" "$stored" 2>/dev/null; then
    rm -rf "$stored" 2>/dev/null
    dp_error "quarantine: move failed for $target"
    return 1
  fi

  # Reason must not break TSV (tabs AND newlines)
  reason="${reason//$'\t'/ }"
  reason="${reason//$'\n'/ }"
  reason="${reason//$'\r'/ }"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$qid" "$(date +%s)" "$target" "$size_kb" "$stored" "$reason" >> "$manifest"

  dp_success "  Quarantined ${qid}: $(bytes_to_human $((size_kb * 1024)))  $target"
  dp_dim "  Restore anytime within ${DEVPURGE_QUARANTINE_DAYS} days: devpurge quarantine --restore ${qid}"
  return 0
}

# List quarantine contents with age and expiry
devpurge_quarantine_list() {
  local manifest
  manifest=$(_dp_quarantine_manifest)
  if [[ ! -f "$manifest" || ! -s "$manifest" ]]; then
    dp_info "Quarantine is empty."
    return 0
  fi

  local now
  now=$(date +%s)
  printf "\n"
  dp_bold "  devpurge quarantine (expires after ${DEVPURGE_QUARANTINE_DAYS} days)"
  printf "\n"
  printf "  ${CLR_DIM}%-5s %-9s %-9s %-8s %s${CLR_RESET}\n" "ID" "Size" "Age" "State" "Original path"

  local qid epoch orig size_kb stored reason
  while IFS=$'\t' read -r qid epoch orig size_kb stored reason; do
    [[ -z "$qid" ]] && continue
    if [[ ! -e "$stored" ]]; then
      dp_warn "  ${qid}: stored copy missing (moved manually?): ${stored}"
      continue
    fi
    local age_days=$(( (now - epoch) / 86400 ))
    local state="held"
    if [[ "$age_days" -ge "$DEVPURGE_QUARANTINE_DAYS" ]]; then
      state="EXPIRED"
    fi
    printf "  %-5s %-9s %-9s %-8s %s\n" \
      "$qid" "$(bytes_to_human $((size_kb * 1024)))" "${age_days}d" "$state" "$orig"
    dp_dim "        reason: ${reason}"
  done < "$manifest"
  printf "\n"
  return 0
}

# Drop a manifest row by ID (called after successful restore/expire)
_dp_manifest_drop() {
  local drop_id="$1"
  local manifest
  manifest=$(_dp_quarantine_manifest)
  [[ -f "$manifest" ]] || return 0
  local tmp="${manifest}.tmp.$$"
  awk -F'\t' -v id="$drop_id" '$1 != id' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
}

# Restore an entry by ID
devpurge_quarantine_restore() {
  local want="$1"
  local manifest
  manifest=$(_dp_quarantine_manifest)
  [[ -f "$manifest" ]] || { dp_error "Quarantine is empty."; return 1; }

  # Refuse ambiguous IDs (should not happen, but fail safe)
  local matches
  matches=$(cut -f1 "$manifest" 2>/dev/null | grep -c "^${want}$" || true)
  if [[ "${matches:-0}" -gt 1 ]]; then
    dp_error "restore: ID ${want} appears ${matches} times in the manifest - refusing."
    dp_error "  Inspect manually: $manifest"
    return 1
  fi

  local qid epoch orig size_kb stored reason
  while IFS=$'\t' read -r qid epoch orig size_kb stored reason; do
    [[ "$qid" == "$want" ]] || continue
    if [[ ! -e "$stored" ]]; then
      dp_error "restore: stored copy not found (moved manually?): $stored"
      return 1
    fi
    if [[ -e "$orig" ]]; then
      dp_error "restore: original path already exists: $orig"
      return 1
    fi
    mkdir -p "$(dirname "$orig")" || return 1
    if mv "$stored" "$orig" 2>/dev/null; then
      _dp_manifest_drop "$want"
      dp_success "Restored ${qid} -> ${orig}"
      return 0
    fi
    dp_error "restore: move failed"
    return 1
  done < "$manifest"

  dp_error "restore: ID not found: $want"
  return 1
}

# Delete entries older than DEVPURGE_QUARANTINE_DAYS. Called from cleanup runs.
# Args: $1 = "dry" to only report
devpurge_quarantine_expire() {
  local dry="${1:-}"
  local manifest
  manifest=$(_dp_quarantine_manifest)
  [[ -f "$manifest" && -s "$manifest" ]] || return 0

  local now
  now=$(date +%s)
  local expired_kb=0 expired_count=0
  local dropped_ids=()

  local qid epoch orig size_kb stored reason
  while IFS=$'\t' read -r qid epoch orig size_kb stored reason; do
    [[ -z "$qid" || ! -e "$stored" ]] && continue
    local age_days=$(( (now - epoch) / 86400 ))
    [[ "$age_days" -lt "$DEVPURGE_QUARANTINE_DAYS" ]] && continue

    if [[ "$dry" == "dry" ]]; then
      expired_count=$((expired_count + 1))
      expired_kb=$((expired_kb + size_kb))
      continue
    fi

    # Stored path is always inside the quarantine dir; guard anyway
    case "$stored" in
      "$DEVPURGE_QUARANTINE_DIR"/*) ;;
      *) continue ;;
    esac
    if rm -rf "$stored" 2>/dev/null; then
      expired_count=$((expired_count + 1))
      expired_kb=$((expired_kb + size_kb))
      dropped_ids+=("$qid")
      dp_dim "  Expired from quarantine: ${qid} $(basename "$stored") (held ${age_days}d)"
    fi
  done < "$manifest"

  # Remove expired rows so IDs never collide with future entries
  local did
  for did in "${dropped_ids[@]+"${dropped_ids[@]}"}"; do
    [[ -n "$did" ]] && _dp_manifest_drop "$did"
  done

  if [[ "$expired_count" -gt 0 ]]; then
    if [[ "$dry" == "dry" ]]; then
      dp_info "  Quarantine: ${expired_count} expired items ($(bytes_to_human $((expired_kb * 1024)))) will be deleted on next cleanup"
    else
      dp_success "  Quarantine expired: ${expired_count} items, $(bytes_to_human $((expired_kb * 1024))) freed"
    fi
  fi
  return 0
}
