#!/usr/bin/env bash
# devpurge - Config file and exclusion logic

# Paths excluded from scanning (populated by CLI --exclude and ~/.devpurgerc)
DEVPURGE_EXCLUDES=()

# Load config from ~/.devpurgerc
# Supported keys (one per line, ~ expanded to $HOME):
#   exclude=PATH             skip PATH (and everything under it)
#   worktree_age_days=N      idle days before a merged worktree is deletable
#   worktree_auto=1          allow worktree removal in unattended (-y) runs
#   protect=SUBSTRING        never delete/quarantine paths containing SUBSTRING
#   quarantine_days=N        days quarantined items are held before expiry
devpurge_load_rc() {
  local rc_file="${HOME}/.devpurgerc"
  [[ -f "$rc_file" ]] || return 0

  local line
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
      worktree_age_days=*)
        local days="${line#worktree_age_days=}"
        case "$days" in
          ''|*[!0-9]*) ;;
          *) DEVPURGE_WORKTREE_AGE_DAYS="$days" ;;
        esac
        ;;
      worktree_auto=*)
        [[ "${line#worktree_auto=}" == "1" ]] && DEVPURGE_WORKTREE_AUTO=1
        ;;
      protect=*)
        local pat="${line#protect=}"
        [[ -n "$pat" ]] && DEVPURGE_PROTECT_PATTERNS+=("$pat")
        ;;
      quarantine_days=*)
        local qdays="${line#quarantine_days=}"
        case "$qdays" in
          ''|*[!0-9]*) ;;
          *) DEVPURGE_QUARANTINE_DAYS="$qdays" ;;
        esac
        ;;
      stale_days=*)
        local sdays="${line#stale_days=}"
        case "$sdays" in
          ''|*[!0-9]*) ;;
          *) DEVPURGE_STALE_DAYS="$sdays" ;;
        esac
        ;;
    esac
  done < "$rc_file"
}

# Check if a path should be excluded (exact match or anything under it)
# Returns 0 if excluded (should skip), 1 if not excluded
devpurge_is_excluded() {
  local target="$1"
  [[ ${#DEVPURGE_EXCLUDES[@]} -eq 0 ]] && return 1
  local excluded
  for excluded in "${DEVPURGE_EXCLUDES[@]}"; do
    if [[ "$target" == "$excluded" || "$target" == "$excluded"/* ]]; then
      return 0
    fi
  done
  return 1
}
