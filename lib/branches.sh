#!/usr/bin/env bash
# devpurge - Merged branch cleanup
#
# Deletes local branches that are fully merged into the default branch, via
# `git branch -d` only (git refuses anything unmerged). Every deleted branch
# is logged with its SHA so it can be restored with `git branch <name> <sha>`.

DEVPURGE_LOG_DIR="${DEVPURGE_LOG_DIR:-${HOME}/Library/Application Support/devpurge/logs}"

# List branches of a repo that are merged into the default branch and safe to
# delete (not the default itself, not protected names, not checked out anywhere).
# Output: one branch name per line.
_dp_merged_branches() {
  local repo="$1" default_branch="$2"

  # Branches checked out in the main repo or any worktree
  local checked_out
  checked_out=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^branch /{sub("refs/heads/",""); print $2}')

  local branch
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    case "$branch" in
      main|master|develop|"$default_branch") continue ;;
    esac
    local is_out=0
    local co
    while IFS= read -r co; do
      [[ "$branch" == "$co" ]] && { is_out=1; break; }
    done <<< "$checked_out"
    [[ "$is_out" -eq 1 ]] && continue
    printf '%s\n' "$branch"
  done < <(git -C "$repo" for-each-ref refs/heads --format='%(refname:short)' --merged "$default_branch" 2>/dev/null)
}

# Scan one repo for deletable merged branches; append a summary entry.
# Args: $1 = repo path
_dp_scan_repo_branches() {
  local repo="$1"
  local default_branch
  default_branch=$(_dp_default_branch "$repo") || return 0

  local count
  count=$(_dp_merged_branches "$repo" "$default_branch" | grep -c . || true)
  [[ -z "$count" || "$count" -eq 0 ]] && return 0

  BR_COUNT=$((BR_COUNT + 1))
  local id
  id=$(printf "G%02d" "$BR_COUNT")
  SCAN_RESULTS+=("${id}|${repo}|branch|merged branches: ${count} ($(basename "$repo")) - restorable via log|-|0|branches:${default_branch}")
  return 0
}

# Cleanup handler: delete all merged branches of a repo, logging SHAs first.
# Args: $1 = repo path, $2 = default branch
# Sets DELETED_BRANCH_COUNT.
devpurge_delete_merged_branches() {
  local repo="$1" default_branch="$2"
  DELETED_BRANCH_COUNT=0

  mkdir -p "$DEVPURGE_LOG_DIR" || return 1
  local log_file="${DEVPURGE_LOG_DIR}/deleted-branches-$(date +%Y%m%d).tsv"

  local branch
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    local sha
    sha=$(git -C "$repo" rev-parse "refs/heads/${branch}" 2>/dev/null)
    [[ -z "$sha" ]] && continue

    # Log BEFORE deleting so a mid-run failure never loses the restore info
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$repo" "$branch" "$sha" >> "$log_file"

    if git -C "$repo" branch -d "$branch" >/dev/null 2>&1; then
      DELETED_BRANCH_COUNT=$((DELETED_BRANCH_COUNT + 1))
    fi
  done < <(_dp_merged_branches "$repo" "$default_branch")

  return 0
}
