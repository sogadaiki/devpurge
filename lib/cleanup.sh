#!/usr/bin/env bash
# devpurge - Cleanup / deletion logic

CLEANUP_FREED_BYTES=0
CLEANUP_DELETED=0
CLEANUP_SKIPPED=0
CLEANUP_ERRORS=0
CLEANUP_LOG=()

# Delete selected cache directories
# Args: $1 = "all" to delete everything in SCAN_RESULTS,
#        or comma-separated IDs like "A01,A04,D02"
devpurge_cleanup() {
  local selection="$1"
  CLEANUP_FREED_BYTES=0
  CLEANUP_DELETED=0
  CLEANUP_SKIPPED=0
  CLEANUP_ERRORS=0
  CLEANUP_LOG=()

  printf "\n"
  dp_info "Cleaning up..."
  printf "\n"

  for entry in "${SCAN_RESULTS[@]}"; do
    local id path tier desc size_human size_bytes
    IFS='|' read -r id path tier desc size_human size_bytes <<< "$entry"

    # Check if this ID is selected
    if [[ "$selection" != "all" ]]; then
      if ! echo ",$selection," | grep -q ",$id,"; then
        CLEANUP_LOG+=("${id}|SKIP|0|${desc}|Not selected")
        CLEANUP_SKIPPED=$((CLEANUP_SKIPPED + 1))
        continue
      fi
    fi

    # Whitelist verification
    if ! devpurge_path_allowed "$path"; then
      dp_error "  BLOCKED: $path is not on the whitelist"
      CLEANUP_LOG+=("${id}|BLOCKED|0|${desc}|Path not whitelisted")
      CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
      continue
    fi

    # Safety: verify path is absolute and under $HOME
    case "$path" in
      "$HOME"/*)
        ;;
      *)
        dp_error "  BLOCKED: $path is not under \$HOME"
        CLEANUP_LOG+=("${id}|BLOCKED|0|${desc}|Not under HOME")
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        continue
        ;;
    esac

    # Delete
    printf "  Deleting %-6s %s..." "$size_human" "$desc"

    if rm -rf "$path" 2>/dev/null; then
      printf " ${CLR_GREEN}done${CLR_RESET}\n"
      CLEANUP_LOG+=("${id}|OK|${size_bytes}|${desc}|Deleted")
      CLEANUP_FREED_BYTES=$((CLEANUP_FREED_BYTES + ${size_bytes%.*}))
      CLEANUP_DELETED=$((CLEANUP_DELETED + 1))
    else
      printf " ${CLR_RED}failed${CLR_RESET}\n"
      CLEANUP_LOG+=("${id}|FAIL|0|${desc}|Permission denied or locked")
      CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    fi
  done
}

# Print cleanup summary
devpurge_cleanup_summary() {
  printf "\n"
  dp_dim "  ─────────────────────────────────────────────────────────────────"
  dp_bold "  Cleanup complete"
  printf "\n"
  dp_success "  Freed:   $(bytes_to_human $CLEANUP_FREED_BYTES)"
  printf "  Deleted: %d items\n" "$CLEANUP_DELETED"

  if [[ $CLEANUP_SKIPPED -gt 0 ]]; then
    printf "  Skipped: %d items\n" "$CLEANUP_SKIPPED"
  fi

  if [[ $CLEANUP_ERRORS -gt 0 ]]; then
    dp_warn "  Errors:  $CLEANUP_ERRORS items (permission denied or blocked)"
  fi

  printf "\n"
}
