#!/usr/bin/env bash
# devpurge - Report / table output

# Minimal JSON string escaping (backslash, quote, tab, newline)
_dp_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Machine-readable scan output for scripting (--json)
devpurge_report_json() {
  printf '{\n  "version": "%s",\n  "total_reclaimable_bytes": %s,\n  "review_bytes": %s,\n  "items": [\n' \
    "$DEVPURGE_VERSION" "$SCAN_TOTAL_BYTES" "$SCAN_REVIEW_BYTES"

  local first=1
  local entry
  for entry in "${SCAN_RESULTS[@]+"${SCAN_RESULTS[@]}"}"; do
    [[ -z "$entry" ]] && continue
    local id path tier desc size_human size_bytes meta
    IFS='|' read -r id path tier desc size_human size_bytes meta <<< "$entry"

    if [[ "$first" -eq 0 ]]; then
      printf ',\n'
    fi
    first=0
    local deletable="true"
    [[ "$tier" == "review" ]] && deletable="false"
    printf '    {"id": "%s", "tier": "%s", "deletable": %s, "bytes": %s, "size": "%s", "path": "%s", "description": "%s", "meta": "%s"}' \
      "$(_dp_json_escape "$id")" "$(_dp_json_escape "$tier")" "$deletable" "${size_bytes%.*}" \
      "$(_dp_json_escape "$size_human")" "$(_dp_json_escape "$path")" "$(_dp_json_escape "$desc")" \
      "$(_dp_json_escape "$meta")"
  done

  printf '\n  ]\n}\n'
}

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

  local ai_bytes=0
  local dev_bytes=0
  local caution_bytes=0
  local project_bytes=0
  local system_bytes=0
  local worktree_bytes=0
  local review_entries=()

  local entry
  for entry in "${SCAN_RESULTS[@]+"${SCAN_RESULTS[@]}"}"; do
    [[ -z "$entry" ]] && continue
    local id path tier desc size_human size_bytes meta
    IFS='|' read -r id path tier desc size_human size_bytes meta <<< "$entry"

    # Review items are listed in their own section below
    if [[ "$tier" == "review" ]]; then
      review_entries+=("$entry")
      continue
    fi

    # Accumulate per-tier totals
    case "$tier" in
      ai)       ai_bytes=$((ai_bytes + ${size_bytes%.*})) ;;
      dev)      dev_bytes=$((dev_bytes + ${size_bytes%.*})) ;;
      caution)  caution_bytes=$((caution_bytes + ${size_bytes%.*})) ;;
      project)  project_bytes=$((project_bytes + ${size_bytes%.*})) ;;
      system)   system_bytes=$((system_bytes + ${size_bytes%.*})) ;;
      worktree) worktree_bytes=$((worktree_bytes + ${size_bytes%.*})) ;;
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
  if [[ $project_bytes -gt 0 ]]; then
    printf "  $(tier_label project) : ${CLR_BOLD}%s${CLR_RESET}\n" "$(bytes_to_human $project_bytes)"
  fi
  if [[ $worktree_bytes -gt 0 ]]; then
    printf "  $(tier_label worktree): ${CLR_BOLD}%s${CLR_RESET}\n" "$(bytes_to_human $worktree_bytes)"
  fi
  if [[ $system_bytes -gt 0 ]]; then
    printf "  $(tier_label system)  : ${CLR_BOLD}%s${CLR_RESET}\n" "$(bytes_to_human $system_bytes)"
  fi

  printf "\n"
  dp_bold "  Total reclaimable: $(bytes_to_human $SCAN_TOTAL_BYTES)"
  printf "\n"

  # ── Review section: reported, never deleted ────────────────────────────────
  if [[ ${#review_entries[@]} -gt 0 ]]; then
    dp_dim "  ─────────────────────────────────────────────────────────────────"
    dp_bold "  Review — large data devpurge will NOT delete (your call)"
    printf "\n"
    for entry in "${review_entries[@]}"; do
      local id path tier desc size_human size_bytes meta
      IFS='|' read -r id path tier desc size_human size_bytes meta <<< "$entry"
      printf "  %-4s  ${CLR_BOLD}%-8s${CLR_RESET}  %s\n" "$id" "$size_human" "$desc"
      dp_dim "        ${path}"
    done
    printf "\n"
    if [[ $SCAN_REVIEW_BYTES -gt 0 ]]; then
      printf "  ${CLR_DIM}Reviewable total: %s (delete manually if truly unneeded)${CLR_RESET}\n" \
        "$(bytes_to_human $SCAN_REVIEW_BYTES)"
      printf "\n"
    fi
  fi

  return 0
}
