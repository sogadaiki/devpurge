#!/usr/bin/env bash
# devpurge - Scan logic

# Results array: "ID|PATH|TIER|DESC|SIZE_HUMAN|SIZE_BYTES"
SCAN_RESULTS=()
SCAN_TOTAL_BYTES=0

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

  # Sort results by size (descending)
  if [[ ${#SCAN_RESULTS[@]} -gt 0 ]]; then
    local sorted=()
    while IFS= read -r line; do
      sorted+=("$line")
    done < <(printf '%s\n' "${SCAN_RESULTS[@]}" | sort -t'|' -k6 -rn)
    SCAN_RESULTS=("${sorted[@]}")
  fi
}
