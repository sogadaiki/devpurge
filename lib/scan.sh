#!/usr/bin/env bash
# devpurge - Scan logic

# Results array: "ID|PATH|TIER|DESC|SIZE_HUMAN|SIZE_BYTES"
SCAN_RESULTS=()
SCAN_TOTAL_BYTES=0

# Scan node_modules in common project directories under $HOME
_scan_node_modules() {
  local search_dirs=(Desktop Documents Projects Developer src repos code dev workspace work)
  local nm_count=0

  for dir_name in "${search_dirs[@]}"; do
    local search_path="${HOME}/${dir_name}"
    [[ -d "$search_path" ]] || continue

    while IFS= read -r nm_path; do
      [[ -z "$nm_path" ]] && continue

      # Skip excluded paths
      if devpurge_is_excluded "$nm_path"; then
        continue
      fi

      local size_human
      size_human=$(du -sh "$nm_path" 2>/dev/null | cut -f1 | xargs)
      [[ -z "$size_human" || "$size_human" == "0B" || "$size_human" == "0" ]] && continue

      local size_bytes
      size_bytes=$(size_to_bytes "$size_human")

      # Skip if less than 1MB
      if [[ "${size_bytes%.*}" -lt 1048576 ]] 2>/dev/null; then
        continue
      fi

      nm_count=$((nm_count + 1))
      local nm_id
      nm_id=$(printf "N%02d" "$nm_count")

      # Extract repo name from parent directory
      local repo_name
      repo_name=$(basename "$(dirname "$nm_path")")

      SCAN_RESULTS+=("${nm_id}|${nm_path}|project|node_modules (${repo_name})|${size_human}|${size_bytes}")
      SCAN_TOTAL_BYTES=$((SCAN_TOTAL_BYTES + ${size_bytes%.*}))

      printf "\r  Scanning node_modules: %-6s  %s" "$size_human" "node_modules (${repo_name})"
    done < <(find "$search_path" -maxdepth 4 -name node_modules -type d -prune 2>/dev/null)
  done
}

# Scan .next build caches in common project directories under $HOME
_scan_next_cache() {
  local search_dirs=(Desktop Documents Projects Developer src repos code dev workspace work)
  local next_count=0

  for dir_name in "${search_dirs[@]}"; do
    local search_path="${HOME}/${dir_name}"
    [[ -d "$search_path" ]] || continue

    while IFS= read -r next_path; do
      [[ -z "$next_path" ]] && continue

      # Skip excluded paths
      if devpurge_is_excluded "$next_path"; then
        continue
      fi

      local size_human
      size_human=$(du -sh "$next_path" 2>/dev/null | cut -f1 | xargs)
      [[ -z "$size_human" || "$size_human" == "0B" || "$size_human" == "0" ]] && continue

      local size_bytes
      size_bytes=$(size_to_bytes "$size_human")

      # Skip if less than 1MB
      if [[ "${size_bytes%.*}" -lt 1048576 ]] 2>/dev/null; then
        continue
      fi

      next_count=$((next_count + 1))
      local next_id
      next_id=$(printf "X%02d" "$next_count")

      # Extract repo name from parent directory
      local repo_name
      repo_name=$(basename "$(dirname "$next_path")")

      SCAN_RESULTS+=("${next_id}|${next_path}|project|.next cache (${repo_name})|${size_human}|${size_bytes}")
      SCAN_TOTAL_BYTES=$((SCAN_TOTAL_BYTES + ${size_bytes%.*}))

      printf "\r  Scanning .next caches: %-6s  %s" "$size_human" ".next cache (${repo_name})"
    done < <(find "$search_path" -maxdepth 4 -name .next -type d -prune 2>/dev/null)
  done
}

# Scan all paths and populate SCAN_RESULTS
# Args: $1 = "all" to include caution tier, "ai" for AI-only, "" for ai+dev
devpurge_scan() {
  local mode="${1:-default}"
  SCAN_RESULTS=()
  SCAN_TOTAL_BYTES=0

  dp_info "Scanning cache directories..."
  printf "\n"

  local count=0
  local total=${#DEVPURGE_PATHS[@]}

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

    # Skip excluded paths
    if devpurge_is_excluded "$path"; then
      continue
    fi

    # Check if path exists
    if [[ ! -d "$path" ]]; then
      continue
    fi

    # Get size with timeout
    local size_human
    size_human=$(du -sh "$path" 2>/dev/null | cut -f1 | xargs)

    if [[ -z "$size_human" || "$size_human" == "0B" || "$size_human" == "0" ]]; then
      continue
    fi

    local size_bytes
    size_bytes=$(size_to_bytes "$size_human")

    # Skip if essentially empty (less than 1KB)
    if [[ "${size_bytes%.*}" -lt 1024 ]] 2>/dev/null; then
      continue
    fi

    SCAN_RESULTS+=("${id}|${path}|${tier}|${desc}|${size_human}|${size_bytes}")
    SCAN_TOTAL_BYTES=$((SCAN_TOTAL_BYTES + ${size_bytes%.*}))

    # Progress indicator
    printf "\r  [%d/%d] Found: %-6s  %s" "$count" "$total" "$size_human" "$desc"
  done

  printf "\r%-80s\r" " "

  # Scan node_modules in project directories (skip for ai-only mode and tests)
  if [[ "$mode" != "ai" && "${DEVPURGE_SKIP_NODE_MODULES:-}" != "1" ]]; then
    _scan_node_modules
    printf "\r%-80s\r" " "
    _scan_next_cache
    printf "\r%-80s\r" " "
  fi

  # Scan remaining ~/Library/Caches entries not covered by static targets
  if [[ "$mode" != "ai" && "${DEVPURGE_SKIP_MISC_CACHES:-}" != "1" && -d "${HOME}/Library/Caches" ]]; then
    # Collect already-targeted cache paths
    local _covered_caches=()
    for entry in "${DEVPURGE_PATHS[@]}"; do
      local _cp
      IFS='|' read -r _ _cp _ _ <<< "$entry"
      case "$_cp" in
        "${HOME}/Library/Caches/"*) _covered_caches+=("$_cp") ;;
      esac
    done

    local misc_count=0
    for cache_dir in "${HOME}/Library/Caches"/*/; do
      [[ -d "$cache_dir" ]] || continue
      cache_dir="${cache_dir%/}"

      # Skip if already covered by a static target (either exact match or parent/child)
      local _is_covered=0
      for _cc in "${_covered_caches[@]+"${_covered_caches[@]}"}"; do
        [[ -z "$_cc" ]] && continue
        if [[ "$cache_dir" == "$_cc" || "$cache_dir" == "$_cc"/* || "$_cc" == "$cache_dir"/* ]]; then
          _is_covered=1
          break
        fi
      done
      [[ "$_is_covered" -eq 1 ]] && continue

      # Skip excluded
      if devpurge_is_excluded "$cache_dir"; then
        continue
      fi

      local size_human
      size_human=$(du -sh "$cache_dir" 2>/dev/null | cut -f1 | xargs) || true
      [[ -z "$size_human" || "$size_human" == "0B" || "$size_human" == "0" ]] && continue

      local size_bytes
      size_bytes=$(size_to_bytes "$size_human")

      # Skip if less than 10MB (only show meaningful cache dirs)
      if [[ "${size_bytes%.*}" -lt 10485760 ]] 2>/dev/null; then
        continue
      fi

      misc_count=$((misc_count + 1))
      local misc_id
      misc_id=$(printf "M%02d" "$misc_count")

      local cache_name
      cache_name=$(basename "$cache_dir")

      SCAN_RESULTS+=("${misc_id}|${cache_dir}|dev|Cache: ${cache_name}|${size_human}|${size_bytes}")
      SCAN_TOTAL_BYTES=$((SCAN_TOTAL_BYTES + ${size_bytes%.*}))
    done
  fi

  # Scan system-level paths (root only)
  if [[ "${DEVPURGE_IS_ROOT:-0}" == "1" ]]; then
    local sys_count=0
    local sys_total=${#DEVPURGE_SYSTEM_PATHS[@]}

    for entry in "${DEVPURGE_SYSTEM_PATHS[@]}"; do
      local id path tier desc
      IFS='|' read -r id path tier desc <<< "$entry"

      sys_count=$((sys_count + 1))

      # Skip excluded paths
      if devpurge_is_excluded "$path"; then
        continue
      fi

      # Check if path exists (file or directory)
      if [[ ! -e "$path" ]]; then
        continue
      fi

      # Get size
      local size_human
      size_human=$(du -sh "$path" 2>/dev/null | cut -f1 | xargs)

      if [[ -z "$size_human" || "$size_human" == "0B" || "$size_human" == "0" ]]; then
        continue
      fi

      local size_bytes
      size_bytes=$(size_to_bytes "$size_human")

      # Skip if less than 1MB
      if [[ "${size_bytes%.*}" -lt 1048576 ]] 2>/dev/null; then
        continue
      fi

      SCAN_RESULTS+=("${id}|${path}|${tier}|${desc}|${size_human}|${size_bytes}")
      SCAN_TOTAL_BYTES=$((SCAN_TOTAL_BYTES + ${size_bytes%.*}))

      printf "\r  [S%d/%d] Found: %-6s  %s" "$sys_count" "$sys_total" "$size_human" "$desc"
    done
    printf "\r%-80s\r" " "
  fi

  # Sort results by size (descending)
  if [[ ${#SCAN_RESULTS[@]} -gt 0 ]]; then
    local sorted=()
    while IFS= read -r line; do
      sorted+=("$line")
    done < <(printf '%s\n' "${SCAN_RESULTS[@]}" | sort -t'|' -k6 -rn)
    SCAN_RESULTS=("${sorted[@]}")
  fi
}
