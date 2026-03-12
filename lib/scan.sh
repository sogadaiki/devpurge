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
