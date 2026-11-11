#!/usr/bin/env bash
# devpurge - Quarantine: recoverable staging for AI-triage deletions
#
# Nothing judged by heuristics or AI is deleted directly. It is moved into
# ~/.devpurge/quarantine/ with a manifest, restorable for QUARANTINE_DAYS
# (default 30). Age prompts review; permanent deletion requires the app.
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
_dp_quarantine_add_locked() {
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
  local last_id=0
  if [[ -f "${DEVPURGE_QUARANTINE_DIR}/last-id" ]]; then
    read -r last_id < "${DEVPURGE_QUARANTINE_DIR}/last-id"
    case "$last_id" in ''|*[!0-9]*) dp_error "Invalid quarantine ID counter"; return 1 ;; esac
    [[ "$last_id" -gt "$max_id" ]] && max_id="$last_id"
  fi
  local qid
  qid=$(printf "Q%03d" $((max_id + 1)))
  printf '%s\n' "$((max_id + 1))" > "${DEVPURGE_QUARANTINE_DIR}/last-id" || return 1

  local stored="${DEVPURGE_QUARANTINE_DIR}/${qid}-$(basename "$target")"
  if [[ -e "$stored" || -L "$stored" ]]; then
    dp_error "Quarantine destination already exists; nothing moved"
    return 1
  fi
  if ! mv "$target" "$stored" 2>/dev/null; then
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
  dp_dim "  Restore until you confirm deletion in the app: devpurge quarantine --restore ${qid}"
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
  dp_bold "  devpurge quarantine (review after ${DEVPURGE_QUARANTINE_DAYS} days; no automatic deletion)"
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
      state="REVIEW"
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
_dp_quarantine_restore_locked() {
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

# Review only. Legacy callers, including unattended cleanup, cannot delete.
# Args: $1 = "dry" to only report
devpurge_quarantine_expire() {
  local dry="${1:-}"
  local manifest
  manifest=$(_dp_quarantine_manifest)
  [[ -f "$manifest" && -s "$manifest" ]] || return 0

  local now
  now=$(date +%s)
  local expired_kb=0 expired_count=0

  local qid epoch orig size_kb stored reason
  while IFS=$'\t' read -r qid epoch orig size_kb stored reason; do
    [[ -z "$qid" || ! -e "$stored" ]] && continue
    local age_days=$(( (now - epoch) / 86400 ))
    [[ "$age_days" -lt "$DEVPURGE_QUARANTINE_DAYS" ]] && continue

    expired_count=$((expired_count + 1))
    expired_kb=$((expired_kb + size_kb))
  done < "$manifest"

  if [[ "$expired_count" -gt 0 ]]; then
    dp_info "  Quarantine: ${expired_count} items ($(bytes_to_human $((expired_kb * 1024)))) past the grace period; nothing deleted"
    dp_dim "  Review and delete them yourself: devpurge quarantine --purge"
  fi
  return 0
}

# Same atomic directory lock used by the native app. A crash leaves a visible
# lock rather than permitting concurrent or guessed stale-lock recovery.
_dp_quarantine_locked() {
  mkdir -p "$DEVPURGE_QUARANTINE_DIR" || return 1
  local lock="${DEVPURGE_QUARANTINE_DIR}/.operation-lock"
  if ! mkdir "$lock" 2>/dev/null; then
    dp_error "Quarantine operation is busy or interrupted; nothing changed"
    return 1
  fi
  local result=0
  if [[ ! -e "${DEVPURGE_QUARANTINE_DIR}/last-id" ]]; then
    local initial=0 manifest
    manifest=$(_dp_quarantine_manifest)
    if [[ -f "$manifest" ]]; then
      initial=$(cut -f1 "$manifest" | sed 's/^Q0*//' | sort -rn | head -1 || true)
      case "$initial" in ''|*[!0-9]*) initial=0 ;; esac
    fi
    printf '%s\n' "$initial" > "${DEVPURGE_QUARANTINE_DIR}/last-id"
  fi
  "$@" || result=$?
  rmdir "$lock" || return 1
  return "$result"
}
devpurge_quarantine_add() { _dp_quarantine_locked _dp_quarantine_add_locked "$@"; }
devpurge_quarantine_restore() { _dp_quarantine_locked _dp_quarantine_restore_locked "$@"; }

# ── Purge: the exit for quarantine ───────────────────────────────────────────
# Age alone never deletes. `devpurge quarantine --purge` lists entries past the
# grace period, the person at the terminal confirms, and only then are they
# removed. Unattended runs (-y, launchd) never reach this code.
#
#   verified    linked git worktree that git itself vouches for: clean, HEAD
#               kept by a ref in the main repo, ignored files all regenerable.
#               Removed with `git worktree remove` (no --force).
#   unverified  plain copies, and worktrees whose git registration was pruned
#               (git can no longer tell whether they held uncommitted work).
#               Confirmed separately; removed with rm -rf after the guards.
#   held        never deleted here; the reason is shown.

DEVPURGE_PURGE_VERIFIED=()
DEVPURGE_PURGE_UNVERIFIED=()

# Print the first path inside a copy that nothing could regenerate or that
# must not be bulk-deleted (empty output = none found). Only for copies git
# cannot vouch for; the name list follows _dp_ignored_unique in worktree.sh.
# Args: $1=stored path
_dp_quarantine_unique_inside() {
  local root="$1" found listing pat
  found=$(find "$root" -name node_modules -prune -o \( \
      -name .git -type d \
      -o -name '.env*' ! -name '*.example' ! -name '*.sample' ! -name '*.template' \
      -o -name export_credentials.cfg -o -name id_rsa -o -name id_ed25519 \
      -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
      -o -name '*.ipa' -o -name '*.pck' -o -name '*.xcarchive' -o -name '*.dSYM' \
      -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \
    \) -print -quit 2>/dev/null) || { printf 'could not be inspected'; return 0; }
  if [[ -n "$found" ]]; then
    printf '%s' "$found"
    return 0
  fi
  # Protected names anywhere inside (NFD names from Finder must match too)
  local args=()
  for pat in "${DEVPURGE_PROTECT_PATTERNS[@]+"${DEVPURGE_PROTECT_PATTERNS[@]}"}"; do
    [[ -n "$pat" ]] && args+=(-e "$pat")
  done
  [[ ${#args[@]} -eq 0 ]] && return 0
  listing=$(mktemp "${TMPDIR:-/tmp}/devpurge-purge.XXXXXX") || { printf 'could not be inspected'; return 0; }
  if ! find "$root" -name node_modules -prune -o -print > "$listing" 2>/dev/null; then
    rm -f "$listing"
    printf 'could not be inspected'
    return 0
  fi
  found=$(grep -F -m1 "${args[@]}" "$listing" 2>/dev/null || true)
  if [[ -z "$found" ]]; then
    found=$(iconv -c -f UTF-8-MAC -t UTF-8 < "$listing" 2>/dev/null | grep -F -m1 "${args[@]}" 2>/dev/null || true)
  fi
  rm -f "$listing"
  printf '%s' "$found"
}

# Retention extensions made in the app (catalog.json review_after). Prints
# "QID<TAB>STORED<TAB>EPOCH" per extended entry; fails if the catalog exists
# but cannot be read, so a broken catalog holds everything.
_dp_quarantine_holds() {
  local catalog="${DEVPURGE_QUARANTINE_DIR}/catalog.json"
  [[ -e "$catalog" ]] || return 0
  python3 -c '
import json, sys
for entry in json.load(open(sys.argv[1])).get("entries", {}).values():
    if entry.get("review_after"):
        print("%s\t%s\t%d" % (entry.get("qid", ""), entry.get("path", ""), int(entry["review_after"])))
' "$catalog"
}

# Print a future retention-extension epoch for an entry, or 0.
# Args: $1=holds listing $2=qid $3=stored path $4=now
_dp_quarantine_extended() {
  local holds="$1" qid="$2" stored="$3" now="$4" hq hp ha extended=0
  while IFS=$'\t' read -r hq hp ha; do
    if [[ "$hq" == "$qid" && "$hp" == "$stored" && "$ha" -gt "$now" ]]; then extended=$ha; fi
  done <<< "$holds"
  printf '%s' "$extended"
}

# Classify one entry. Prints "CLASS<TAB>DETAIL" where CLASS is verified
# (DETAIL = main repo), unverified (DETAIL = why git cannot vouch) or held
# (DETAIL = reason). Read-only. Args: $1=original path $2=stored path
_dp_quarantine_purge_class() {
  local orig="$1" stored="$2" phys qphys
  if [[ -L "$stored" ]] || ! devpurge_rm_guard "$stored"; then
    printf 'held\tstored path failed the safety guard'; return 0
  fi
  phys=$(devpurge_resolve_physical "$stored") || { printf 'held\tstored path could not be resolved'; return 0; }
  qphys=$(cd -P "$DEVPURGE_QUARANTINE_DIR" 2>/dev/null && pwd -P) || { printf 'held\tquarantine folder could not be resolved'; return 0; }
  if [[ "$(dirname "$phys")" != "$qphys" ]]; then
    printf 'held\tstored copy is not directly inside the quarantine folder'; return 0
  fi
  if devpurge_is_protected "$orig" || devpurge_is_protected "$stored"; then
    printf 'held\tpath matches a protected pattern'; return 0
  fi

  local common="" unique
  if [[ -f "$stored/.git" ]]; then
    common=$(git -C "$stored" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  elif [[ -d "$stored/.git" ]]; then
    printf 'held\tstandalone git repository with its own history'; return 0
  fi

  if [[ -n "$common" && "$(basename "$common")" == ".git" && -d "$common" ]]; then
    local repo lock_path status sha branch kept
    repo=$(dirname "$common")
    lock_path=$(git -C "$stored" rev-parse --git-path locked 2>/dev/null) || { printf 'held\tgit state could not be read'; return 0; }
    if [[ -e "$lock_path" ]]; then
      printf 'held\tworktree is locked'; return 0
    fi
    status=$(git -C "$stored" status --porcelain --untracked-files=all 2>/dev/null) || { printf 'held\tgit status failed'; return 0; }
    if [[ -n "$status" ]]; then
      printf 'held\tuncommitted or untracked files'; return 0
    fi
    unique=$(_dp_ignored_unique "$stored")
    if [[ -n "$unique" ]]; then
      printf 'held\tignored file git cannot restore: %s' "${unique#"$stored"/}"; return 0
    fi
    sha=$(git -C "$stored" rev-parse HEAD 2>/dev/null) || { printf 'held\tHEAD could not be read'; return 0; }
    branch=$(git -C "$stored" symbolic-ref -q --short HEAD 2>/dev/null || true)
    if [[ -n "$branch" ]]; then
      kept=$(git -C "$repo" rev-parse -q --verify "refs/heads/${branch}" 2>/dev/null || true)
      if [[ "$kept" != "$sha" ]]; then
        printf 'held\tbranch %s in the main repo does not match this copy' "$branch"; return 0
      fi
    else
      kept=$(git -C "$repo" for-each-ref --count=1 --contains "$sha" refs/heads refs/remotes refs/tags 2>/dev/null || true)
      if [[ -z "$kept" ]]; then
        printf 'held\tdetached HEAD is not kept by any branch or tag'; return 0
      fi
    fi
    printf 'verified\t%s' "$repo"; return 0
  fi

  unique=$(_dp_quarantine_unique_inside "$stored")
  if [[ -n "$unique" ]]; then
    printf 'held\tcontains data that cannot be regenerated or is protected: %s' "${unique#"$stored"/}"; return 0
  fi
  if [[ -f "$stored/.git" ]]; then
    printf 'unverified\tgit registration was pruned; uncommitted work cannot be checked'
  else
    printf 'unverified\tplain copy; nothing to check it against'
  fi
  return 0
}

# Build and print the purge plan. Fills DEVPURGE_PURGE_VERIFIED/UNVERIFIED
# with quarantine IDs. Read-only.
_dp_quarantine_purge_plan() {
  DEVPURGE_PURGE_VERIFIED=()
  DEVPURGE_PURGE_UNVERIFIED=()
  local manifest holds
  manifest=$(_dp_quarantine_manifest)
  if [[ ! -f "$manifest" || ! -s "$manifest" ]]; then
    dp_info "Quarantine is empty."
    return 0
  fi
  if ! holds=$(_dp_quarantine_holds 2>/dev/null); then
    dp_error "quarantine --purge: retention records could not be read; nothing deleted"
    return 1
  fi

  local now
  now=$(date +%s)
  local out_v="" out_u="" out_h=""
  local kb_v=0 kb_u=0 kb_h=0 early_count=0 early_kb=0 next_due=0
  local qid epoch orig size_kb stored reason due class detail result extended line
  while IFS=$'\t' read -r qid epoch orig size_kb stored reason; do
    [[ -z "$qid" ]] && continue
    [[ -e "$stored" || -L "$stored" ]] || continue
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$size_kb" in ''|*[!0-9]*) size_kb=0 ;; esac
    due=$((epoch + DEVPURGE_QUARANTINE_DAYS * 86400))
    if [[ "$now" -lt "$due" ]]; then
      early_count=$((early_count + 1))
      early_kb=$((early_kb + size_kb))
      if [[ "$next_due" -eq 0 || "$due" -lt "$next_due" ]]; then next_due=$due; fi
      continue
    fi

    extended=$(_dp_quarantine_extended "$holds" "$qid" "$stored" "$now")
    if [[ "$extended" -gt 0 ]]; then
      class="held"; detail="retention extended in the app until $(date -r "$extended" +%Y-%m-%d)"
    else
      result=$(_dp_quarantine_purge_class "$orig" "$stored")
      class="${result%%$'\t'*}"; detail="${result#*$'\t'}"
    fi

    line=$(printf "  %-5s %-9s %-6s %s" "$qid" "$(bytes_to_human $((size_kb * 1024)))" "$(( (now - epoch) / 86400 ))d" "$orig")
    case "$class" in
      verified)
        DEVPURGE_PURGE_VERIFIED+=("$qid")
        kb_v=$((kb_v + size_kb))
        out_v="${out_v}${line}"$'\n'"        reason: ${reason}"$'\n'
        ;;
      unverified)
        DEVPURGE_PURGE_UNVERIFIED+=("$qid")
        kb_u=$((kb_u + size_kb))
        out_u="${out_u}${line}"$'\n'"        not checked: ${detail}"$'\n'"        reason: ${reason}"$'\n'
        ;;
      *)
        kb_h=$((kb_h + size_kb))
        out_h="${out_h}${line}"$'\n'"        held: ${detail}"$'\n'
        ;;
    esac
  done < "$manifest"

  printf "\n"
  dp_bold "  devpurge quarantine --purge (grace period: ${DEVPURGE_QUARANTINE_DAYS} days)"
  printf "\n"
  if [[ -n "$out_v" ]]; then
    dp_bold "  Checked by git: clean, commits kept in the repo  ($(bytes_to_human $((kb_v * 1024))))"
    printf '%s\n' "$out_v"
  fi
  if [[ -n "$out_u" ]]; then
    dp_bold "  Could not be checked: relies on the judgement made when quarantined  ($(bytes_to_human $((kb_u * 1024))))"
    printf '%s\n' "$out_u"
  fi
  if [[ -n "$out_h" ]]; then
    dp_bold "  Held: --purge never deletes these  ($(bytes_to_human $((kb_h * 1024))))"
    printf '%s\n' "$out_h"
  fi
  if [[ "$early_count" -gt 0 ]]; then
    dp_dim "  Not due yet: ${early_count} items ($(bytes_to_human $((early_kb * 1024)))); next due $(date -r "$next_due" +%Y-%m-%d)"
  fi
  if [[ -z "$out_v" && -z "$out_u" ]]; then
    dp_info "  Nothing is ready to delete."
  fi
  printf "\n"
  return 0
}

# Delete confirmed entries. Every entry is re-read and re-classified right
# before deletion; an entry whose class changed is kept.
# Args: "QID:CLASS" ...
_dp_quarantine_purge_locked() {
  local manifest holds now
  manifest=$(_dp_quarantine_manifest)
  [[ -f "$manifest" ]] || return 0
  if ! holds=$(_dp_quarantine_holds 2>/dev/null); then
    dp_error "quarantine --purge: retention records could not be read; nothing deleted"
    return 1
  fi
  now=$(date +%s)
  mkdir -p "$DEVPURGE_LOG_DIR" || return 1
  local log="${DEVPURGE_LOG_DIR}/quarantine-purge-$(date +%Y%m%d).tsv"
  local free_before free_after deleted=0 deleted_kb=0 kept=0 item
  free_before=$(df -k "$DEVPURGE_QUARANTINE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')

  local want expected matches qid epoch orig size_kb stored reason found class detail result ok
  for item in "$@"; do
    want="${item%%:*}"; expected="${item#*:}"
    matches=$(cut -f1 "$manifest" 2>/dev/null | grep -c "^${want}$" || true)
    found=0
    if [[ "${matches:-0}" -eq 1 ]]; then
      while IFS=$'\t' read -r qid epoch orig size_kb stored reason; do
        if [[ "$qid" == "$want" ]]; then found=1; break; fi
      done < "$manifest"
    fi
    if [[ "$found" -ne 1 ]]; then
      dp_warn "  ${want}: record changed; kept"
      kept=$((kept + 1))
      continue
    fi
    case "$epoch" in ''|*[!0-9]*) epoch=$now ;; esac
    case "$size_kb" in ''|*[!0-9]*) size_kb=0 ;; esac

    class="held"; detail="not due"
    if [[ "$(_dp_quarantine_extended "$holds" "$qid" "$stored" "$now")" -gt 0 ]]; then
      detail="retention extended in the app"
    elif [[ "$now" -ge $((epoch + DEVPURGE_QUARANTINE_DAYS * 86400)) && -e "$stored" ]]; then
      result=$(_dp_quarantine_purge_class "$orig" "$stored")
      class="${result%%$'\t'*}"; detail="${result#*$'\t'}"
    fi
    if [[ "$class" == "held" || "$class" != "$expected" ]]; then
      dp_warn "  ${qid}: changed since the list was shown (${detail}); kept"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$qid" "$orig" "$size_kb" "$expected" "kept" >> "$log"
      kept=$((kept + 1))
      continue
    fi

    ok=1
    if [[ "$class" == "verified" ]]; then
      # The registration may still point at the pre-quarantine path
      git -C "$detail" worktree repair "$stored" >/dev/null 2>&1 || true
      _dp_remove_worktree "$stored" "$detail" || ok=0
    else
      rm -rf "$stored" 2>/dev/null || ok=0
    fi
    if [[ "$ok" -eq 1 && ! -e "$stored" ]]; then
      _dp_manifest_drop "$qid"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$qid" "$orig" "$size_kb" "$class" "deleted" >> "$log"
      dp_success "  Deleted ${qid}: $(bytes_to_human $((size_kb * 1024)))  $orig"
      deleted=$((deleted + 1))
      deleted_kb=$((deleted_kb + size_kb))
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$qid" "$orig" "$size_kb" "$class" "failed" >> "$log"
      dp_warn "  ${qid}: could not be deleted; kept"
      kept=$((kept + 1))
    fi
  done

  free_after=$(df -k "$DEVPURGE_QUARANTINE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  printf "\n"
  dp_info "  Deleted ${deleted} items (recorded size $(bytes_to_human $((deleted_kb * 1024)))); ${kept} kept"
  case "${free_before}${free_after}" in
    ''|*[!0-9]*) ;;
    *) dp_dim "  Disk free space changed by $(( (free_after - free_before) / 1024 )) MB during this run" ;;
  esac
  [[ "$kept" -eq 0 ]]
}

# Entry point. Args: $1 = "dry" to only show the plan
devpurge_quarantine_purge() {
  local dry="${1:-}"
  _dp_quarantine_purge_plan || return 1
  if [[ "$dry" == "dry" ]]; then
    dp_dim "  Dry run - nothing was deleted."
    return 0
  fi
  local n_v=${#DEVPURGE_PURGE_VERIFIED[@]} n_u=${#DEVPURGE_PURGE_UNVERIFIED[@]}
  if [[ $((n_v + n_u)) -eq 0 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    dp_error "quarantine --purge needs your confirmation in a terminal; nothing deleted"
    return 1
  fi

  local chosen=() qid
  if [[ "$n_v" -gt 0 ]] && dp_confirm "  Permanently delete the ${n_v} items checked by git?"; then
    for qid in "${DEVPURGE_PURGE_VERIFIED[@]}"; do chosen+=("${qid}:verified"); done
  fi
  if [[ "$n_u" -gt 0 ]] && dp_confirm "  Permanently delete the ${n_u} items that could NOT be checked? They cannot be restored."; then
    for qid in "${DEVPURGE_PURGE_UNVERIFIED[@]}"; do chosen+=("${qid}:unverified"); done
  fi
  if [[ ${#chosen[@]} -eq 0 ]]; then
    dp_info "  Cancelled. Nothing was deleted."
    return 0
  fi
  _dp_quarantine_locked _dp_quarantine_purge_locked "${chosen[@]}"
}
