#!/usr/bin/env bash
# devpurge - Scan logic

# Results array: "ID|PATH|TIER|DESC|SIZE_HUMAN|SIZE_BYTES|META"
# META: worktree handling instructions ("remove:<repo>" / "prune:<repo>"), else empty
SCAN_RESULTS=()
SCAN_TOTAL_BYTES=0
SCAN_REVIEW_BYTES=0
WT_COUNT=0
RV_COUNT=0
# Roots of worktrees marked deletable (project scan skips inside these)
DEVPURGE_WT_ROOTS=()

# Measure a path in KB (accurate, no human-format rounding).
# du exits non-zero on partially unreadable trees but still prints a total;
# never propagate that failure (callers run under set -e).
_dp_size_kb() {
  du -sk "$1" 2>/dev/null | cut -f1 || true
}

# Append a scan result and update totals.
# Args: $1=id $2=path $3=tier $4=desc $5=size_kb
_dp_add_result() {
  local id="$1" path="$2" tier="$3" desc="$4" size_kb="$5"
  # '|' is the field separator; strip it from names derived from paths
  desc="${desc//|/_}"
  local size_bytes=$((size_kb * 1024))
  local size_human
  size_human=$(bytes_to_human "$size_bytes")

  SCAN_RESULTS+=("${id}|${path}|${tier}|${desc}|${size_human}|${size_bytes}|")
  if [[ "$tier" == "review" ]]; then
    SCAN_REVIEW_BYTES=$((SCAN_REVIEW_BYTES + size_bytes))
  else
    SCAN_TOTAL_BYTES=$((SCAN_TOTAL_BYTES + size_bytes))
  fi
}

# Generic project-artifact scanner (node_modules, .next, etc.)
# Args: $1=dir_name_to_find $2=id_prefix $3=desc_template ("%s" = repo name)
_dp_scan_project_dirs() {
  local target_name="$1" id_prefix="$2" desc_template="$3"
  local search_dirs=(Desktop Documents Projects Developer src repos code dev workspace work)
  local count=0

  for dir_name in "${search_dirs[@]}"; do
    local search_path="${HOME}/${dir_name}"
    [[ -d "$search_path" ]] || continue

    while IFS= read -r found_path; do
      [[ -z "$found_path" ]] && continue

      if devpurge_is_excluded "$found_path"; then
        continue
      fi

      # Skip artifacts inside worktrees already marked for removal
      local wt_root skip_wt=0
      for wt_root in "${DEVPURGE_WT_ROOTS[@]+"${DEVPURGE_WT_ROOTS[@]}"}"; do
        [[ -z "$wt_root" ]] && continue
        if [[ "$found_path" == "$wt_root"/* ]]; then
          skip_wt=1
          break
        fi
      done
      [[ "$skip_wt" -eq 1 ]] && continue

      local size_kb
      size_kb=$(_dp_size_kb "$found_path")
      # Skip if less than 1MB
      [[ -z "$size_kb" || "$size_kb" -lt 1024 ]] && continue

      count=$((count + 1))
      local id
      id=$(printf "%s%02d" "$id_prefix" "$count")

      local repo_name desc
      repo_name=$(basename "$(dirname "$found_path")")
      # shellcheck disable=SC2059
      desc=$(printf "$desc_template" "$repo_name")

      _dp_add_result "$id" "$found_path" "project" "$desc" "$size_kb"

      printf "\r  Scanning %s: %-6s  %s" "$target_name" "$(bytes_to_human $((size_kb * 1024)))" "$desc"
    done < <(find "$search_path" -maxdepth 5 -name "$target_name" -type d -prune 2>/dev/null)
  done
  return 0
}

# Check whether a path is already covered by a static target (parent or child)
_dp_is_covered() {
  local candidate="$1"
  shift
  local covered
  for covered in "$@"; do
    [[ -z "$covered" ]] && continue
    if [[ "$candidate" == "$covered" || "$candidate" == "$covered"/* || "$covered" == "$candidate"/* ]]; then
      return 0
    fi
  done
  return 1
}

# Auto-detect ~/Library/Caches entries not covered by static targets
_dp_scan_misc_caches() {
  [[ -d "${HOME}/Library/Caches" ]] || return 0

  # Collect already-targeted cache paths
  local covered_caches=()
  local entry
  for entry in "${DEVPURGE_PATHS[@]}"; do
    local _cp
    IFS='|' read -r _ _cp _ _ <<< "$entry"
    case "$_cp" in
      "${HOME}/Library/Caches/"*) covered_caches+=("$_cp") ;;
    esac
  done

  local misc_count=0
  local cache_dir
  for cache_dir in "${HOME}/Library/Caches"/*/; do
    [[ -d "$cache_dir" ]] || continue
    cache_dir="${cache_dir%/}"

    if devpurge_is_excluded "$cache_dir"; then
      continue
    fi

    if _dp_is_covered "$cache_dir" "${covered_caches[@]+"${covered_caches[@]}"}"; then
      # A child of this dir is statically targeted; still surface uncovered
      # siblings one level down (e.g. Caches/Google/AndroidStudio next to
      # the covered Caches/Google/Chrome)
      local child
      for child in "$cache_dir"/*/; do
        [[ -d "$child" ]] || continue
        child="${child%/}"
        if _dp_is_covered "$child" "${covered_caches[@]+"${covered_caches[@]}"}"; then
          continue
        fi
        if devpurge_is_excluded "$child"; then
          continue
        fi
        local child_kb
        child_kb=$(_dp_size_kb "$child")
        [[ -z "$child_kb" || "$child_kb" -lt 10240 ]] && continue
        misc_count=$((misc_count + 1))
        _dp_add_result "$(printf "M%02d" "$misc_count")" "$child" "dev" \
          "Cache: $(basename "$cache_dir")/$(basename "$child")" "$child_kb"
      done
      continue
    fi

    local size_kb
    size_kb=$(_dp_size_kb "$cache_dir")
    # Skip if less than 10MB (only show meaningful cache dirs)
    [[ -z "$size_kb" || "$size_kb" -lt 10240 ]] && continue

    misc_count=$((misc_count + 1))
    local misc_id
    misc_id=$(printf "M%02d" "$misc_count")
    _dp_add_result "$misc_id" "$cache_dir" "dev" "Cache: $(basename "$cache_dir")" "$size_kb"
  done
  return 0
}

# Auto-detect Electron/Chromium disk caches inside Application Support
# (Cache, Code Cache, GPUCache, DawnCache variants - pure disk caches, safe)
_dp_scan_electron_caches() {
  local as_dir="${HOME}/Library/Application Support"
  [[ -d "$as_dir" ]] || return 0

  # Collect statically-targeted App Support paths to avoid double listing
  local covered=()
  local entry
  for entry in "${DEVPURGE_PATHS[@]}"; do
    local _cp
    IFS='|' read -r _ _cp _ _ <<< "$entry"
    case "$_cp" in
      "${as_dir}/"*) covered+=("$_cp") ;;
    esac
  done

  local el_count=0
  local app_dir cache_name
  for app_dir in "$as_dir"/*/; do
    [[ -d "$app_dir" ]] || continue
    app_dir="${app_dir%/}"

    for cache_name in "Cache" "Code Cache" "GPUCache" "DawnCache" "DawnGraphiteCache" "DawnWebGPUCache"; do
      local cache_path="${app_dir}/${cache_name}"
      [[ -d "$cache_path" ]] || continue

      if _dp_is_covered "$cache_path" "${covered[@]+"${covered[@]}"}"; then
        continue
      fi
      if devpurge_is_excluded "$cache_path"; then
        continue
      fi

      local size_kb
      size_kb=$(_dp_size_kb "$cache_path")
      # Skip if less than 10MB
      [[ -z "$size_kb" || "$size_kb" -lt 10240 ]] && continue

      el_count=$((el_count + 1))
      local el_id
      el_id=$(printf "E%02d" "$el_count")
      _dp_add_result "$el_id" "$cache_path" "dev" "App cache: $(basename "$app_dir")/${cache_name}" "$size_kb"

      printf "\r  Scanning app caches: %-6s  %s" "$(bytes_to_human $((size_kb * 1024)))" "$(basename "$app_dir")"
    done
  done
  return 0
}

# Auto-detect sandboxed app caches (~/Library/Containers/<id>/Data/Library/Caches)
_dp_scan_container_caches() {
  local ct_dir="${HOME}/Library/Containers"
  [[ -d "$ct_dir" ]] || return 0

  local ct_count=0
  local container
  for container in "$ct_dir"/*/; do
    [[ -d "$container" ]] || continue
    container="${container%/}"

    local cache_path="${container}/Data/Library/Caches"
    [[ -d "$cache_path" ]] || continue

    if devpurge_is_excluded "$cache_path"; then
      continue
    fi

    local size_kb
    size_kb=$(_dp_size_kb "$cache_path")
    # Skip if less than 10MB
    [[ -z "$size_kb" || "$size_kb" -lt 10240 ]] && continue

    ct_count=$((ct_count + 1))
    local ct_id
    ct_id=$(printf "K%02d" "$ct_count")
    _dp_add_result "$ct_id" "$cache_path" "dev" "Container cache: $(basename "$container")" "$size_kb"
  done
  return 0
}

# Report-only review targets: large user data devpurge will never delete
_dp_scan_review_targets() {
  local entry
  for entry in "${DEVPURGE_REVIEW_PATHS[@]}"; do
    local id path tier desc
    IFS='|' read -r id path tier desc <<< "$entry"

    [[ -e "$path" ]] || continue
    if devpurge_is_excluded "$path"; then
      continue
    fi

    local size_kb
    size_kb=$(_dp_size_kb "$path")
    # Only report review items of 100MB or more
    [[ -z "$size_kb" || "$size_kb" -lt 102400 ]] && continue

    _dp_add_result "$id" "$path" "review" "$desc" "$size_kb"
  done

  # Screen recordings sitting on the Desktop
  if [[ -d "${HOME}/Desktop" ]]; then
    local rec_kb=0 rec_count=0
    local f
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local fkb
      fkb=$(_dp_size_kb "$f")
      [[ -z "$fkb" ]] && continue
      rec_kb=$((rec_kb + fkb))
      rec_count=$((rec_count + 1))
    done < <(find "${HOME}/Desktop" -maxdepth 1 \( -name "画面収録*.mov" -o -name "Screen Recording*.mov" \) 2>/dev/null)

    if [[ "$rec_count" -gt 0 && "$rec_kb" -ge 102400 ]]; then
      RV_COUNT=$((RV_COUNT + 1))
      _dp_add_result "$(printf "R%02d" "$RV_COUNT")" "${HOME}/Desktop/*.mov" "review" \
        "Screen recordings on Desktop (${rec_count} files)" "$rec_kb"
    fi
  fi

  # Time Machine local snapshots (space is reclaimed by macOS on demand)
  local snap_count
  snap_count=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple.TimeMachine" || true)
  if [[ "${snap_count:-0}" -gt 0 ]]; then
    RV_COUNT=$((RV_COUNT + 1))
    SCAN_RESULTS+=("$(printf "R%02d" "$RV_COUNT")|local APFS snapshots|review|Time Machine local snapshots (${snap_count}) - thin: tmutil thinlocalsnapshots / 999999999999 4|-|0|")
  fi
  return 0
}

# Scan all paths and populate SCAN_RESULTS
# Args: $1 = "all" to include caution tier, "ai" for AI-only, "" for ai+dev
devpurge_scan() {
  local mode="${1:-default}"
  SCAN_RESULTS=()
  SCAN_TOTAL_BYTES=0
  SCAN_REVIEW_BYTES=0
  WT_COUNT=0
  RV_COUNT=0
  DEVPURGE_WT_ROOTS=()

  dp_info "Scanning cache directories..."
  printf "\n"

  local count=0
  local total=${#DEVPURGE_PATHS[@]}

  local entry
  for entry in "${DEVPURGE_PATHS[@]}"; do
    local id path tier desc
    IFS='|' read -r id path tier desc <<< "$entry"

    count=$((count + 1))

    # Filter by mode
    if [[ "$mode" == "ai" && "$tier" != "ai" ]]; then
      continue
    fi
    if [[ "$mode" == "default" && "$tier" == "caution" ]]; then
      continue
    fi

    if devpurge_is_excluded "$path"; then
      continue
    fi

    if [[ ! -d "$path" ]]; then
      continue
    fi

    local size_kb
    size_kb=$(_dp_size_kb "$path")

    # Skip if essentially empty (less than 4KB)
    [[ -z "$size_kb" || "$size_kb" -lt 4 ]] && continue

    _dp_add_result "$id" "$path" "$tier" "$desc" "$size_kb"

    # Progress indicator
    printf "\r  [%d/%d] Found: %-6s  %s" "$count" "$total" "$(bytes_to_human $((size_kb * 1024)))" "$desc"
  done

  printf "\r%-80s\r" " "

  # Stale git worktree detection (before project scan so artifacts inside
  # removable worktrees are not double-counted)
  if [[ "$mode" != "ai" && "${DEVPURGE_SKIP_WORKTREES:-}" != "1" ]]; then
    devpurge_scan_worktrees
    printf "\r%-80s\r" " "
  fi

  # Scan project artifacts (node_modules, .next) in project directories
  if [[ "$mode" != "ai" && "${DEVPURGE_SKIP_NODE_MODULES:-}" != "1" ]]; then
    _dp_scan_project_dirs "node_modules" "N" "node_modules (%s)"
    printf "\r%-80s\r" " "
    _dp_scan_project_dirs ".next" "X" ".next cache (%s)"
    printf "\r%-80s\r" " "
  fi

  # Auto-detect caches not covered by static targets
  if [[ "$mode" != "ai" && "${DEVPURGE_SKIP_MISC_CACHES:-}" != "1" ]]; then
    _dp_scan_misc_caches
    _dp_scan_electron_caches
    printf "\r%-80s\r" " "
    _dp_scan_container_caches
  fi

  # Report-only review targets
  if [[ "$mode" != "ai" && "${DEVPURGE_SKIP_REVIEW:-}" != "1" ]]; then
    _dp_scan_review_targets
    printf "\r%-80s\r" " "
  fi

  # Scan system-level paths (root only)
  if [[ "${DEVPURGE_IS_ROOT:-0}" == "1" ]]; then
    local sys_count=0
    local sys_total=${#DEVPURGE_SYSTEM_PATHS[@]}

    for entry in "${DEVPURGE_SYSTEM_PATHS[@]}"; do
      local id path tier desc
      IFS='|' read -r id path tier desc <<< "$entry"

      sys_count=$((sys_count + 1))

      if devpurge_is_excluded "$path"; then
        continue
      fi

      # Check if path exists (file or directory)
      if [[ ! -e "$path" ]]; then
        continue
      fi

      local size_kb
      size_kb=$(_dp_size_kb "$path")

      # Skip if less than 1MB
      [[ -z "$size_kb" || "$size_kb" -lt 1024 ]] && continue

      _dp_add_result "$id" "$path" "$tier" "$desc" "$size_kb"

      printf "\r  [S%d/%d] Found: %-6s  %s" "$sys_count" "$sys_total" "$(bytes_to_human $((size_kb * 1024)))" "$desc"
    done
    printf "\r%-80s\r" " "
  fi

  # Sort results by size (descending)
  if [[ ${#SCAN_RESULTS[@]} -gt 0 ]]; then
    local sorted=()
    local line
    while IFS= read -r line; do
      sorted+=("$line")
    done < <(printf '%s\n' "${SCAN_RESULTS[@]}" | sort -t'|' -k6 -rn)
    SCAN_RESULTS=("${sorted[@]}")
  fi
}
