#!/usr/bin/env bash
# devpurge - Duplicate and stale-file detection (report-only, review tier)
#
# Neither scanner deletes anything. They surface candidates for the human
# (or the AI triage flow) to judge; protected patterns are skipped entirely.

DEVPURGE_STALE_DAYS="${DEVPURGE_STALE_DAYS:-90}"

# _dp_nfc lives in lib/utils.sh (shared with protected-pattern matching)

# True if both paths sit at the same relative location inside git checkouts
# (i.e. the same repo file seen through multiple worktrees - not a stray copy)
_dp_same_repo_file() {
  local a="$1" b="$2"
  local top_a top_b
  top_a=$(git -C "$(dirname "$a")" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_b=$(git -C "$(dirname "$b")" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -z "$top_a" || -z "$top_b" ]] && return 1
  [[ "$(_dp_nfc "${a#"$top_a"/}")" == "$(_dp_nfc "${b#"$top_b"/}")" ]]
}

# Same-name + same-size files >=50MB across user dirs -> likely stray copies
_dp_scan_duplicates() {
  local search_dirs=("${HOME}/Desktop" "${HOME}/Documents" "${HOME}/Downloads")
  local tmp_list
  tmp_list=$(mktemp "${TMPDIR:-/tmp}/devpurge-dupes.XXXXXX")

  local dir
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 6 -type f -size +50M \
      -not -path "*/node_modules/*" -not -path "*/.git/*" \
      -exec stat -f "%N|%z" {} + 2>/dev/null
  done | awk -F'|' '{n=split($1,p,"/"); print p[n] "|" $2 "|" $1}' | sort > "$tmp_list" || true

  # Adjacent rows with identical basename|size are duplicate candidates
  local prev_key="" prev_path="" line key path size dup_count=0
  while IFS= read -r line; do
    # line is "basename|size|path"; key is "basename|size"
    path="${line##*|}"
    key="${line%"|${path}"}"
    if [[ "$key" == "$prev_key" && -n "$prev_path" ]]; then
      if ! devpurge_is_protected "$path" && ! devpurge_is_protected "$prev_path" \
         && ! devpurge_is_excluded "$path" && ! devpurge_is_excluded "$prev_path" \
         && ! _dp_same_repo_file "$path" "$prev_path"; then
        dup_count=$((dup_count + 1))
        [[ "$dup_count" -gt 10 ]] && break
        size="${key##*|}"
        RV_COUNT=$((RV_COUNT + 1))
        local size_bytes=$((size))
        SCAN_RESULTS+=("$(printf "R%02d" "$RV_COUNT")|${path}|review|duplicate of: ${prev_path}|$(bytes_to_human "$size_bytes")|${size_bytes}|")
        SCAN_REVIEW_BYTES=$((SCAN_REVIEW_BYTES + size_bytes))
      fi
    fi
    prev_key="$key"
    prev_path="$path"
  done < "$tmp_list"

  rm -f "$tmp_list"
  return 0
}

# Large files not opened in DEVPURGE_STALE_DAYS+ (Spotlight kMDItemLastUsedDate)
_dp_scan_stale_unused() {
  command -v mdfind >/dev/null 2>&1 || return 0

  local stale_sec=$((DEVPURGE_STALE_DAYS * 86400))
  local stale_count=0
  local f
  while IFS= read -r f; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    if devpurge_is_protected "$f" || devpurge_is_excluded "$f"; then
      continue
    fi
    stale_count=$((stale_count + 1))
    [[ "$stale_count" -gt 10 ]] && break

    local size_kb
    size_kb=$(_dp_size_kb "$f")
    [[ -z "$size_kb" ]] && continue
    local size_bytes=$((size_kb * 1024))
    RV_COUNT=$((RV_COUNT + 1))
    SCAN_RESULTS+=("$(printf "R%02d" "$RV_COUNT")|${f}|review|not opened in ${DEVPURGE_STALE_DAYS}d+|$(bytes_to_human "$size_bytes")|${size_bytes}|")
    SCAN_REVIEW_BYTES=$((SCAN_REVIEW_BYTES + size_bytes))
  done < <(mdfind -onlyin "${HOME}/Desktop" -onlyin "${HOME}/Documents" -onlyin "${HOME}/Downloads" \
      "kMDItemFSSize > 104857600 && kMDItemLastUsedDate < \$time.now(-${stale_sec})" 2>/dev/null | head -40)

  return 0
}
