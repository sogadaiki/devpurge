#!/usr/bin/env bash
# devpurge - Duplicate and stale-file detection (report-only, review tier)
#
# Neither scanner deletes anything. They surface candidates for the human
# (or the AI triage flow) to judge; protected patterns are skipped entirely.

DEVPURGE_STALE_DAYS="${DEVPURGE_STALE_DAYS:-90}"

# _dp_nfc lives in lib/utils.sh (shared with protected-pattern matching)

# Identify a repository file across linked worktrees. The common Git directory
# is essential: unrelated repositories can have the same relative filenames.
_dp_repo_file_key() {
  local path="$1" top common
  top=$(git -C "$(dirname "$path")" rev-parse --show-toplevel 2>/dev/null) || return 1
  common=$(git -C "$top" rev-parse --git-common-dir 2>/dev/null) || return 1
  common=$(cd "$top" && cd "$common" && pwd -P) || return 1
  printf '%s|%s' "$common" "$(_dp_nfc "${path#"$top"/}")"
}

_dp_same_repo_file() {
  local key_a key_b
  key_a=$(_dp_repo_file_key "$1") || return 1
  key_b=$(_dp_repo_file_key "$2") || return 1
  [[ "$key_a" == "$key_b" ]]
}

# Minimum size (MB) for identical-copy detection, and the per-scan caps that
# keep the review list readable
DEVPURGE_DUPE_MIN_MB="${DEVPURGE_DUPE_MIN_MB:-10}"
DEVPURGE_DUPE_MAX="${DEVPURGE_DUPE_MAX:-15}"
DEVPURGE_VERSION_MAX="${DEVPURGE_VERSION_MAX:-20}"

# Directories never descended into by the user-file scanners: dependency
# trees, VCS data, worktree farms (handled by worktree.sh), app bundles
_dp_user_find() {
  local dir="$1"; shift
  find "$dir" -maxdepth 8 \
    \( -name node_modules -o -name .git -o -name .worktrees -o -name '*.app' \
       -o -name .next -o -name .open-next -o -name .venv -o -name venv \
       -o -name Library -o -name .Trash -o -name '.env*' \) -prune -o \
    -type f "$@" -print 2>/dev/null
}

# Cheap content fingerprint: first + last 1MB. Only files whose quick
# signature collides are fully hashed, so same-size camera splits (e.g. 4GB
# FAT32 chunks) never trigger a multi-GB read.
_dp_quick_sig() {
  local f="$1" size="$2"
  { head -c 1048576 "$f"; [[ "$size" -gt 2097152 ]] && tail -c 1048576 "$f"; } 2>/dev/null | \
    shasum -a 1 | cut -c1-40
}

# Hash one same-size group. Emits "sha256|size|mtime|path" for every member
# whose quick signature collides with another member's.
# Args: $1=newline-separated paths $2=size $3=output file (appended)
_dp_hash_group() {
  local g="$1" s="$2" out="$3" members
  members=$(printf '%s' "$g" | grep -c . || true)
  [[ "$members" -lt 2 ]] && return 0
  printf '%s' "$g" | while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    printf '%s|%s\n' "$(_dp_quick_sig "$m" "$s")" "$m"
  done | awk -F'|' '{c[$1]++; k[NR]=$1; l[NR]=$0}
    END {for (i=1;i<=NR;i++) if (c[k[i]]>1) {sub(/^[^|]*\|/, "", l[i]); print l[i]}}' | \
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    printf '%s|%s|%s|%s\n' "$(shasum -a 256 "$m" 2>/dev/null | cut -d' ' -f1)" "$s" "$(stat -f %m "$m" 2>/dev/null)" "$m"
  done >> "$out"
}

# Byte-identical files (same size, same SHA-256) >= DEVPURGE_DUPE_MIN_MB
# across user dirs, regardless of name. One copy per group is kept as the
# reference: outside Downloads first, then the oldest mtime.
# Args: optional search dirs (default: ~/Desktop ~/Documents ~/Downloads)
_dp_scan_duplicates() {
  local search_dirs=("${HOME}/Desktop" "${HOME}/Documents" "${HOME}/Downloads")
  [[ $# -gt 0 ]] && search_dirs=("$@")
  local tmp_sizes tmp_hashes
  tmp_sizes=$(mktemp "${TMPDIR:-/tmp}/devpurge-dupes.XXXXXX")
  tmp_hashes=$(mktemp "${TMPDIR:-/tmp}/devpurge-hashes.XXXXXX")

  local dir
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    _dp_user_find "$dir" -size +"$((DEVPURGE_DUPE_MIN_MB * 1024 * 2))" | \
      while IFS= read -r f; do stat -f "%z|%N" "$f" 2>/dev/null; done
  done | sort -t'|' -k1,1n > "$tmp_sizes" || true

  # Same-size groups -> quick signature -> full hash on collision
  local prev_size="" group="" line size path
  while IFS= read -r line; do
    size="${line%%|*}"
    path="${line#*|}"
    if [[ "$size" != "$prev_size" ]]; then
      [[ -n "$group" ]] && _dp_hash_group "$group" "$prev_size" "$tmp_hashes"
      group="" prev_size="$size"
    fi
    group="${group}${path}"$'\n'
  done < "$tmp_sizes"
  [[ -n "$group" ]] && _dp_hash_group "$group" "$prev_size" "$tmp_hashes"

  # Group by hash; keeper = non-Downloads first, then oldest mtime
  local dup_count=0 sha keep_path
  while IFS='|' read -r sha size keep_path path; do
    [[ -z "$path" ]] && continue
    if devpurge_is_protected "$path" || devpurge_is_protected "$keep_path" \
       || devpurge_is_excluded "$path" || _dp_same_repo_file "$path" "$keep_path"; then
      continue
    fi
    dup_count=$((dup_count + 1))
    [[ "$dup_count" -gt "$DEVPURGE_DUPE_MAX" ]] && break
    RV_COUNT=$((RV_COUNT + 1))
    SCAN_RESULTS+=("$(printf "R%02d" "$RV_COUNT")|${path}|review|identical copy of: ${keep_path}|$(bytes_to_human "$size")|${size}|")
    SCAN_REVIEW_BYTES=$((SCAN_REVIEW_BYTES + size))
  done < <(awk -F'|' -v dl="${HOME}/Downloads/" '
      { rank = (index($4, dl) == 1) ? 1 : 0; print $1 "|" rank "|" $3 "|" $2 "|" $4 }' "$tmp_hashes" | \
    sort -t'|' -k1,1 -k2,2n -k3,3n | \
    awk -F'|' '{ path=$0; sub(/^([^|]*\|){4}/, "", path)
                 if ($1 != cur) { cur=$1; keep=path; next }
                 print $1 "|" $4 "|" keep "|" path }' | \
    sort -t'|' -k2,2rn)

  rm -f "$tmp_sizes" "$tmp_hashes"
  return 0
}

# Explicit version variants in one folder: foo.mp4 / foo-v2.mp4 / foo_final.mp4
# / "foo (1).zip" / "foo 2.png" / 資料のコピー.pdf. Everything but the newest
# (mtime) is reported. Bare "_1/_2" suffixes are deliberately NOT markers:
# they are usually parts or series (camera splits, story_23..27), not versions.
# Args: optional search dirs (default: ~/Desktop ~/Documents ~/Downloads)
_dp_scan_versions() {
  local search_dirs=("${HOME}/Desktop" "${HOME}/Documents" "${HOME}/Downloads")
  [[ $# -gt 0 ]] && search_dirs=("$@")

  local ver_count=0 size path newest dir key i
  local seen_keys=() seen_paths=()
  while IFS='|' read -r size path newest; do
    [[ -z "$path" ]] && continue
    if devpurge_is_protected "$path" || devpurge_is_excluded "$path"; then
      continue
    fi
    # One report row for identical copies of the same repository file. Keep
    # different bytes and unrelated repositories visible; apply the cap AFTER
    # collapsing worktree copies so they do not crowd out other candidates.
    key=$(_dp_repo_file_key "$path") || key=""
    if [[ -n "$key" ]]; then
      for ((i=0; i<${#seen_keys[@]}; i++)); do
        if [[ "${seen_keys[$i]}" == "$key" ]] && cmp -s "$path" "${seen_paths[$i]}"; then
          continue 2
        fi
      done
      seen_keys+=("$key")
      seen_paths+=("$path")
    fi
    ver_count=$((ver_count + 1))
    [[ "$ver_count" -gt "$DEVPURGE_VERSION_MAX" ]] && break
    RV_COUNT=$((RV_COUNT + 1))
    SCAN_RESULTS+=("$(printf "R%02d" "$RV_COUNT")|${path}|review|older version (newest: ${newest})|$(bytes_to_human "$size")|${size}|")
    SCAN_REVIEW_BYTES=$((SCAN_REVIEW_BYTES + size))
  done < <(
    for dir in "${search_dirs[@]}"; do
      [[ -d "$dir" ]] || continue
      _dp_user_find "$dir" -size +2048 | \
        while IFS= read -r f; do stat -f "%m|%z|%N" "$f" 2>/dev/null; done
    done | awk -F'|' '
      NF != 3 { next }
      {
        path = $3; n = split(path, seg, "/"); name = seg[n]
        d = substr(path, 1, length(path) - length(name))
        dot = 0
        for (i = length(name); i > 1; i--) if (substr(name, i, 1) == ".") { dot = i; break }
        if (dot == 0) next
        stem = tolower(substr(name, 1, dot - 1)); ext = tolower(substr(name, dot))
        s = stem; changed = 1
        while (changed) {
          changed = 0
          if (sub(/(^|[ _.-]+)(v[0-9]+([.][0-9]+)*|ver[0-9]+|final|old|bak|backup|copy|draft[0-9]*|rev[0-9]+)$/, "", s)) changed = 1
          if (sub(/ ?\([0-9]+\)$/, "", s)) changed = 1
          if (sub(/ [0-9]+$/, "", s)) changed = 1
          if (sub(/[ _-]*(のコピー|コピー|最終版|最終|修正版|修正)$/, "", s)) changed = 1
        }
        if (s == "") next
        key = d "\t" s ext
        cnt[key]++; p[key, cnt[key]] = path; m[key, cnt[key]] = $1; z[key, cnt[key]] = $2
        if (s != stem) marked[key] = 1
      }
      END {
        for (key in cnt) {
          if (cnt[key] < 2 || !(key in marked)) continue
          best = 1
          for (i = 2; i <= cnt[key]; i++) if (m[key, i] + 0 > m[key, best] + 0) best = i
          nb = p[key, best]; sub(/.*\//, "", nb)
          for (i = 1; i <= cnt[key]; i++) if (i != best) print z[key, i] "|" p[key, i] "|" nb
        }
      }' | sort -t'|' -k1,1rn
  )
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
