#!/usr/bin/env bash
# devpurge - Config file and exclusion logic

# Paths excluded from scanning (populated by CLI --exclude and ~/.devpurgerc)
DEVPURGE_EXCLUDES=()

# Load exclusions from ~/.devpurgerc
# Format: exclude=PATH (one per line, ~ expanded to $HOME)
devpurge_load_rc() {
  local rc_file="${HOME}/.devpurgerc"
  [[ -f "$rc_file" ]] || return 0

  while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue

    case "$line" in
      exclude=*)
        local path="${line#exclude=}"
        # Expand ~ to $HOME
        path="${path/#\~/$HOME}"
        # Remove trailing slash
        path="${path%/}"
        [[ -n "$path" ]] && DEVPURGE_EXCLUDES+=("$path")
        ;;
    esac
  done < "$rc_file"
}

# Check if a path should be excluded
# Returns 0 if excluded (should skip), 1 if not excluded
devpurge_is_excluded() {
  local target="$1"
  [[ ${#DEVPURGE_EXCLUDES[@]} -eq 0 ]] && return 1
  for excluded in "${DEVPURGE_EXCLUDES[@]}"; do
    [[ "$target" == "$excluded" ]] && return 0
  done
  return 1
}
