#!/usr/bin/env bash
# devpurge - Report / table output

devpurge_report() {
  if [[ ${#SCAN_RESULTS[@]} -eq 0 ]]; then
    dp_success "No significant caches found. Your system is clean!"
    return 1
  fi

  printf "\n"
  dp_bold "  devpurge scan results"
  dp_dim "  ─────────────────────────────────────────────────────────────────"
  printf "\n"

  # Header
  printf "  ${CLR_DIM}%-4s  %-8s  %-8s  %-35s${CLR_RESET}\n" "#" "Tier" "Size" "Description"
  printf "  ${CLR_DIM}%-4s  %-8s  %-8s  %-35s${CLR_RESET}\n" "──" "────────" "────────" "───────────────────────────────────"

  local idx=0
  local ai_bytes=0
  local dev_bytes=0
  local caution_bytes=0

  for entry in "${SCAN_RESULTS[@]}"; do
    local id path tier desc size_human size_bytes
    IFS='|' read -r id path tier desc size_human size_bytes <<< "$entry"
    idx=$((idx + 1))

    # Accumulate per-tier totals
    case "$tier" in
      ai)      ai_bytes=$((ai_bytes + ${size_bytes%.*})) ;;
      dev)     dev_bytes=$((dev_bytes + ${size_bytes%.*})) ;;
      caution) caution_bytes=$((caution_bytes + ${size_bytes%.*})) ;;
    esac

    local tier_display
    tier_display=$(tier_label "$tier")

    printf "  %-4s  %-18s  ${CLR_BOLD}%-8s${CLR_RESET}  %s\n" \
      "$id" "$tier_display" "$size_human" "$desc"
  done

  printf "\n"
  dp_dim "  ─────────────────────────────────────────────────────────────────"

  # Tier subtotals
  if [[ $ai_bytes -gt 0 ]]; then
    printf "  $(tier_label ai)    : ${CLR_BOLD}%s${CLR_RESET}\n" "$(bytes_to_human $ai_bytes)"
  fi
  if [[ $dev_bytes -gt 0 ]]; then
    printf "  $(tier_label dev) : ${CLR_BOLD}%s${CLR_RESET}\n" "$(bytes_to_human $dev_bytes)"
  fi
  if [[ $caution_bytes -gt 0 ]]; then
    printf "  $(tier_label caution) : ${CLR_BOLD}%s${CLR_RESET}\n" "$(bytes_to_human $caution_bytes)"
  fi

  printf "\n"
  dp_bold "  Total reclaimable: $(bytes_to_human $SCAN_TOTAL_BYTES)"
  printf "\n"

  return 0
}
