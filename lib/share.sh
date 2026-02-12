#!/usr/bin/env bash
# devpurge - Viral share text generation

DEVPURGE_REPO="https://github.com/sogadaiki/devpurge"

devpurge_share() {
  local freed_human
  freed_human=$(bytes_to_human "$CLEANUP_FREED_BYTES")

  # Build item list (top 5 by size)
  local lines=()
  local shown=0
  local remaining=0

  for entry in "${CLEANUP_LOG[@]}"; do
    local id status size_bytes desc detail
    IFS='|' read -r id status size_bytes desc detail <<< "$entry"

    if [[ "$status" != "OK" ]]; then
      continue
    fi

    if [[ $shown -lt 5 ]]; then
      local item_human
      item_human=$(bytes_to_human "${size_bytes%.*}")
      lines+=("${desc}: ${item_human}")
      shown=$((shown + 1))
    else
      remaining=$((remaining + 1))
    fi
  done

  # Compose share text
  local share_text=""
  share_text+="I just purged ${freed_human} of hidden dev caches with devpurge"
  share_text+=$'\n\n'

  for line in "${lines[@]}"; do
    share_text+="${line}"
    share_text+=$'\n'
  done

  if [[ $remaining -gt 0 ]]; then
    share_text+="+ ${remaining} more"
    share_text+=$'\n'
  fi

  share_text+=$'\n'
  share_text+="Your Mac is hoarding AI-era bloat. Check yours:"
  share_text+=$'\n'
  share_text+="${DEVPURGE_REPO}"
  share_text+=$'\n'
  share_text+="#devpurge"

  # Display
  printf "\n"
  dp_dim "  ─────────────────────────────────────────────────────────────────"
  dp_bold "  Share your results"
  printf "\n"
  printf "%s\n" "$share_text"
  printf "\n"

  # Copy to clipboard
  if command -v pbcopy &>/dev/null; then
    printf '%s' "$share_text" | pbcopy
    dp_success "  Copied to clipboard!"
  fi

  # Offer to open Twitter
  printf "\n"
  if dp_confirm "  Open Twitter/X to share?"; then
    local encoded
    encoded=$(urlencode "$share_text")
    open "https://twitter.com/intent/tweet?text=${encoded}" 2>/dev/null
  fi
}

# Generate README badge markdown
devpurge_badge() {
  printf '[![Cleaned with devpurge](https://img.shields.io/badge/cleaned_with-devpurge-00cc88)](%s)\n' "$DEVPURGE_REPO"
}
