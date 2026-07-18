#!/usr/bin/env bash
# devpurge - Cleanup / deletion logic

CLEANUP_FREED_BYTES=0
CLEANUP_DELETED=0
CLEANUP_SKIPPED=0
CLEANUP_ERRORS=0
CLEANUP_LOG=()
CLEANUP_TRASH_DIR=""

# Dispose of a path: rm -rf by default, or move into ~/.Trash with --trash
# (recoverable until the Trash is emptied). Args: $1=path $2=id
_dp_dispose() {
  local path="$1" id="$2"
  if [[ "${OPT_TRASH:-0}" -eq 1 ]]; then
    if [[ -z "$CLEANUP_TRASH_DIR" ]]; then
      CLEANUP_TRASH_DIR="${HOME}/.Trash/devpurge-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$CLEANUP_TRASH_DIR" 2>/dev/null || return 1
    local dest="${CLEANUP_TRASH_DIR}/${id}-$(basename "$path")"
    if ! mv "$path" "$dest" 2>/dev/null; then
      # A cross-device mv can fail mid-copy; drop the partial destination so
      # the Trash never holds a half-copy masquerading as a backup
      rm -rf "$dest" 2>/dev/null
      return 1
    fi
  else
    rm -rf "$path" 2>/dev/null
  fi
}

# Resolve a path's parent to its physical location (symlinks expanded).
# Prevents a symlinked intermediate directory (e.g. ~/.cache -> /Volumes/x)
# from smuggling a deletion outside the whitelist.
devpurge_resolve_physical() {
  local target="$1" parent base
  parent=$(dirname "$target")
  base=$(basename "$target")
  parent=$(cd -P "$parent" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "${parent%/}" "$base"
}

# Last-resort guard before any destructive operation.
# Blocks empty/relative paths, /, $HOME itself, and traversal sequences.
devpurge_rm_guard() {
  local target="$1"
  [[ -z "$target" ]] && return 1
  [[ "$target" != /* ]] && return 1
  case "$target" in
    "/"|"/."|"$HOME"|"$HOME/") return 1 ;;
    *"/.."*|*"../"*|*"/../"*) return 1 ;;
  esac
  # Refuse to act on paths that are themselves symlinks (rm -rf would follow
  # the entry name; deleting through a link can escape the whitelist)
  if [[ -L "$target" ]]; then
    return 1
  fi
  return 0
}

# Remove a git worktree via git itself (never rm -rf).
# Args: $1=worktree path $2=main repo path
_dp_remove_worktree() {
  local wt="$1" repo="$2"
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || return 1
  # git refuses dirty/locked worktrees without --force; we never pass --force
  git -C "$repo" worktree remove "$wt" 2>/dev/null
}

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

  local entry
  for entry in "${SCAN_RESULTS[@]+"${SCAN_RESULTS[@]}"}"; do
    [[ -z "$entry" ]] && continue
    local id path tier desc size_human size_bytes meta
    IFS='|' read -r id path tier desc size_human size_bytes meta <<< "$entry"

    # Review tier is report-only: never deleted, regardless of selection
    if [[ "$tier" == "review" ]]; then
      CLEANUP_LOG+=("${id}|SKIP|0|${desc}|Review tier (never auto-deleted)")
      continue
    fi

    # Check if this ID is selected
    if [[ "$selection" != "all" ]]; then
      if ! echo ",$selection," | grep -q ",$id,"; then
        CLEANUP_LOG+=("${id}|SKIP|0|${desc}|Not selected")
        CLEANUP_SKIPPED=$((CLEANUP_SKIPPED + 1))
        continue
      fi
    fi

    # ── Protected patterns: legal material etc. is never deleted ─────────────
    if devpurge_is_protected "$path"; then
      dp_error "  BLOCKED: $path matches a protected pattern"
      CLEANUP_LOG+=("${id}|BLOCKED|0|${desc}|Protected pattern")
      CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
      continue
    fi

    # ── Branch entries: delete merged branches via git, log SHAs first ───────
    if [[ "$tier" == "branch" ]]; then
      local br_default="${meta#branches:}"
      printf "  Deleting merged branches (%s)..." "$(basename "$path")"
      if devpurge_delete_merged_branches "$path" "$br_default"; then
        printf " ${CLR_GREEN}%d deleted${CLR_RESET}\n" "$DELETED_BRANCH_COUNT"
        CLEANUP_LOG+=("${id}|OK|0|${desc}|${DELETED_BRANCH_COUNT} branches deleted (SHAs logged)")
        CLEANUP_DELETED=$((CLEANUP_DELETED + 1))
      else
        printf " ${CLR_RED}failed${CLR_RESET}\n"
        CLEANUP_LOG+=("${id}|FAIL|0|${desc}|Branch cleanup failed")
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
      fi
      continue
    fi

    # ── Worktree entries: handled by git, not rm ─────────────────────────────
    if [[ "$tier" == "worktree" ]]; then
      local action="${meta%%:*}"
      local repo="${meta#*:}"

      # Unattended runs (-y, e.g. cron) never remove worktrees unless opted in
      # via worktree_auto=1 in ~/.devpurgerc (or DEVPURGE_WORKTREE_AUTO=1).
      # Pruning stale records is metadata-only and always allowed.
      if [[ "$action" != "prune" && "${OPT_YES:-0}" -eq 1 && "${DEVPURGE_WORKTREE_AUTO:-0}" != "1" ]]; then
        dp_dim "  Skipping worktree (unattended run, set worktree_auto=1 to enable): $desc"
        CLEANUP_LOG+=("${id}|SKIP|0|${desc}|Worktree skipped in unattended mode")
        CLEANUP_SKIPPED=$((CLEANUP_SKIPPED + 1))
        continue
      fi

      case "$path" in
        "$HOME"/*) ;;
        *)
          dp_error "  BLOCKED: worktree $path is not under \$HOME"
          CLEANUP_LOG+=("${id}|BLOCKED|0|${desc}|Not under HOME")
          CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
          continue
          ;;
      esac

      if [[ "$action" == "prune" ]]; then
        printf "  Pruning stale worktree records (%s)..." "$(basename "$repo")"
        if git -C "$repo" worktree prune 2>/dev/null; then
          printf " ${CLR_GREEN}done${CLR_RESET}\n"
          CLEANUP_LOG+=("${id}|OK|0|${desc}|Pruned")
          CLEANUP_DELETED=$((CLEANUP_DELETED + 1))
        else
          printf " ${CLR_RED}failed${CLR_RESET}\n"
          CLEANUP_LOG+=("${id}|FAIL|0|${desc}|git worktree prune failed")
          CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        fi
        continue
      fi

      printf "  Removing %-6s %s..." "$size_human" "$desc"
      if [[ "${OPT_TRASH:-0}" -eq 1 ]]; then
        # Trash mode bypasses git's delete-time recheck; re-verify cleanliness
        # ourselves right before moving (state may have changed since scan)
        if ! git -C "$path" status --porcelain >/dev/null 2>&1 || \
           [[ -n "$(git -C "$path" status --porcelain 2>/dev/null | head -1)" ]]; then
          printf " ${CLR_RED}skipped (no longer clean)${CLR_RESET}\n"
          CLEANUP_LOG+=("${id}|SKIP|0|${desc}|Worktree changed since scan")
          CLEANUP_SKIPPED=$((CLEANUP_SKIPPED + 1))
          continue
        fi
        # Move the worktree away, then prune the stale record
        if _dp_dispose "$path" "$id" && git -C "$repo" worktree prune 2>/dev/null; then
          printf " ${CLR_GREEN}moved to Trash${CLR_RESET}\n"
          CLEANUP_LOG+=("${id}|OK|${size_bytes}|${desc}|Worktree moved to Trash")
          CLEANUP_FREED_BYTES=$((CLEANUP_FREED_BYTES + ${size_bytes%.*}))
          CLEANUP_DELETED=$((CLEANUP_DELETED + 1))
        else
          printf " ${CLR_RED}failed${CLR_RESET}\n"
          CLEANUP_LOG+=("${id}|FAIL|0|${desc}|Trash move failed")
          CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        fi
        continue
      fi
      if _dp_remove_worktree "$path" "$repo"; then
        printf " ${CLR_GREEN}done${CLR_RESET}\n"
        CLEANUP_LOG+=("${id}|OK|${size_bytes}|${desc}|Worktree removed")
        CLEANUP_FREED_BYTES=$((CLEANUP_FREED_BYTES + ${size_bytes%.*}))
        CLEANUP_DELETED=$((CLEANUP_DELETED + 1))
      else
        printf " ${CLR_RED}failed${CLR_RESET}\n"
        CLEANUP_LOG+=("${id}|FAIL|0|${desc}|git worktree remove refused (dirty/locked?)")
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
      fi
      continue
    fi

    # ── Regular entries: whitelist + guards, then rm -rf ─────────────────────
    if ! devpurge_path_allowed "$path"; then
      dp_error "  BLOCKED: $path is not on the whitelist"
      CLEANUP_LOG+=("${id}|BLOCKED|0|${desc}|Path not whitelisted")
      CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
      continue
    fi

    # Safety: verify path is absolute and under $HOME (system tier exempt)
    if [[ "$tier" != "system" ]]; then
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
    fi

    if ! devpurge_rm_guard "$path"; then
      dp_error "  BLOCKED: $path failed the safety guard"
      CLEANUP_LOG+=("${id}|BLOCKED|0|${desc}|Failed rm guard")
      CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
      continue
    fi

    # Re-verify the physical path (symlinked parent dirs must not escape)
    local phys_path
    if ! phys_path=$(devpurge_resolve_physical "$path"); then
      dp_error "  BLOCKED: $path could not be resolved"
      CLEANUP_LOG+=("${id}|BLOCKED|0|${desc}|Unresolvable path")
      CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
      continue
    fi
    if [[ "$phys_path" != "$path" ]]; then
      local phys_ok=1
      devpurge_path_allowed "$phys_path" || phys_ok=0
      if [[ "$tier" != "system" ]]; then
        case "$phys_path" in
          "$HOME"/*) ;;
          *) phys_ok=0 ;;
        esac
      fi
      if [[ "$phys_ok" -eq 0 ]]; then
        dp_error "  BLOCKED: $path resolves outside the whitelist ($phys_path)"
        CLEANUP_LOG+=("${id}|BLOCKED|0|${desc}|Symlinked parent escapes whitelist")
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        continue
      fi
    fi

    # Special handling for sleepimage: disable hibernation first
    if [[ "$id" == "S01" ]]; then
      pmset -a hibernatemode 0 2>/dev/null
    fi

    # Delete (or move to Trash with --trash; system tier always deletes)
    printf "  Deleting %-6s %s..." "$size_human" "$desc"

    local dispose_ok=0
    if [[ "$tier" == "system" ]]; then
      rm -rf "$path" 2>/dev/null && dispose_ok=1
    else
      _dp_dispose "$path" "$id" && dispose_ok=1
    fi

    if [[ "$dispose_ok" -eq 1 ]]; then
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
  if [[ "${OPT_TRASH:-0}" -eq 1 ]]; then
    dp_success "  Moved to Trash: $(bytes_to_human $CLEANUP_FREED_BYTES)"
    dp_dim "  (space is freed when you empty the Trash: ${CLEANUP_TRASH_DIR:-~/.Trash})"
  else
    dp_success "  Freed:   $(bytes_to_human $CLEANUP_FREED_BYTES)"
  fi
  printf "  Deleted: %d items\n" "$CLEANUP_DELETED"

  if [[ $CLEANUP_SKIPPED -gt 0 ]]; then
    printf "  Skipped: %d items\n" "$CLEANUP_SKIPPED"
  fi

  if [[ $CLEANUP_ERRORS -gt 0 ]]; then
    dp_warn "  Errors:  $CLEANUP_ERRORS items (permission denied or blocked)"
  fi

  # APFS local snapshots pin deleted blocks until they rotate (~24h);
  # df won't show the space immediately and that's expected
  if [[ $CLEANUP_FREED_BYTES -gt 1073741824 ]]; then
    dp_dim "  Note: freed space may appear in Finder/df over the next ~24h"
    dp_dim "  (APFS local snapshots release deleted blocks as they rotate)"
  fi

  printf "\n"
}
