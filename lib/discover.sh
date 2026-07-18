#!/usr/bin/env bash
# devpurge - Discover mode: find large directories devpurge does NOT cover.
# Read-only. Answers "where did my disk go?" beyond the whitelist.

devpurge_discover() {
  dp_info "Measuring top-level directories under \$HOME (read-only)..."
  printf "\n"

  local tmp_list
  tmp_list=$(mktemp "${TMPDIR:-/tmp}/devpurge-discover.XXXXXX")

  local entry
  for entry in "${HOME}"/* "${HOME}"/.[A-Za-z0-9]*; do
    [[ -d "$entry" || -f "$entry" ]] || continue
    case "$entry" in
      "${HOME}/..") continue ;;
    esac
    local size_kb
    size_kb=$(_dp_size_kb "$entry")
    [[ -z "$size_kb" ]] && continue
    # Only show 100MB+
    [[ "$size_kb" -lt 102400 ]] && continue
    printf "%s\t%s\n" "$size_kb" "$entry" >> "$tmp_list"
    printf "\r  Measured: %-50s" "$(basename "$entry")"
  done
  printf "\r%-70s\r" " "

  dp_bold "  Largest items under \$HOME (100MB+)"
  dp_dim "  ─────────────────────────────────────────────────────────────────"
  printf "\n"

  local size_kb path
  while IFS=$'\t' read -r size_kb path; do
    printf "  ${CLR_BOLD}%-8s${CLR_RESET}  %s\n" "$(bytes_to_human $((size_kb * 1024)))" "$path"
  done < <(sort -rn "$tmp_list" | head -20)

  rm -f "$tmp_list"

  printf "\n"
  dp_dim "  Tip: run 'devpurge -n' to see what is safely reclaimable,"
  dp_dim "       'du -sk <dir>/* | sort -rn | head' to drill into a directory."
  printf "\n"
}
