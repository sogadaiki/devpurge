#!/usr/bin/env bash
# devpurge - Stale git worktree detection
#
# Finds git worktrees under common project directories and classifies them:
#   - merged + clean + idle  -> deletable via `git worktree remove` (never rm -rf)
#   - prunable records       -> `git worktree prune` on the main repo
#   - unmerged/dirty/locked  -> review tier (reported, never deleted)
#
# Result entries use the extended 7-field format:
#   ID|PATH|TIER|DESC|SIZE_HUMAN|SIZE_BYTES|META
# where META is "remove:<main_repo>" or "prune:<main_repo>".

# Minimum idle age (days since last commit on the worktree HEAD) before a
# merged+clean worktree is considered safe to remove. Overridable via
# ~/.devpurgerc (worktree_age_days=N).
DEVPURGE_WORKTREE_AGE_DAYS="${DEVPURGE_WORKTREE_AGE_DAYS:-7}"

# Resolve the default branch of a repo (main/master, remote HEAD preferred).
# origin/HEAD is a local cache that `git fetch` never updates - trust it only
# if its target still exists as a remote-tracking ref; refresh with
# `git remote set-head origin -a` when a repo migrates its default branch.
_dp_default_branch() {
  local repo="$1" ref
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [[ -n "$ref" ]]; then
    local ref_branch="${ref#origin/}"
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/${ref}" \
       && git -C "$repo" show-ref --verify --quiet "refs/heads/${ref_branch}"; then
      printf '%s' "$ref"
      return 0
    fi
  fi
  if git -C "$repo" show-ref --verify --quiet refs/heads/main; then
    printf 'main'
  elif git -C "$repo" show-ref --verify --quiet refs/heads/master; then
    printf 'master'
  else
    return 1
  fi
}

# Scan one main repo's worktrees. Appends to SCAN_RESULTS.
# Args: $1 = main repo path
_dp_scan_repo_worktrees() {
  local repo="$1"
  local default_branch
  default_branch=$(_dp_default_branch "$repo") || return 0

  local now_epoch
  now_epoch=$(date +%s)
  local max_age_sec=$((DEVPURGE_WORKTREE_AGE_DAYS * 86400))

  local wt_path="" wt_locked=0 wt_prunable=0 has_prunable=0
  local line

  # Parse `git worktree list --porcelain` blocks (blank line separated)
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *) wt_path="${line#worktree }" ;;
      locked*)     wt_locked=1 ;;
      prunable*)   wt_prunable=1 ;;
      "")
        _dp_classify_worktree "$repo" "$default_branch" "$wt_path" "$wt_locked" "$wt_prunable" \
          "$now_epoch" "$max_age_sec" || has_prunable=1
        wt_path="" wt_locked=0 wt_prunable=0
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null; printf '\n')

  # One prune entry per repo covers all stale records
  if [[ "$has_prunable" -eq 1 ]]; then
    WT_COUNT=$((WT_COUNT + 1))
    local id
    id=$(printf "W%02d" "$WT_COUNT")
    SCAN_RESULTS+=("${id}|${repo}|worktree|worktree records: stale entries ($(basename "$repo"))|-|0|prune:${repo}")
  fi
  return 0
}

# Classify a single worktree. Returns 1 (only) when the entry is prunable,
# so the caller can emit a repo-level prune entry.
_dp_classify_worktree() {
  local repo="$1" default_branch="$2" wt="$3" locked="$4" prunable="$5"
  local now_epoch="$6" max_age_sec="$7"

  [[ -z "$wt" ]] && return 0
  # Skip the main repo itself
  [[ "$wt" == "$repo" ]] && return 0

  if [[ "$prunable" -eq 1 ]]; then
    return 1
  fi

  # Only consider worktrees under $HOME (never touch stuff elsewhere)
  case "$wt" in
    "$HOME"/*) ;;
    *) return 0 ;;
  esac

  if devpurge_is_excluded "$wt"; then
    return 0
  fi

  [[ -d "$wt" ]] || return 0

  local size_kb
  size_kb=$(_dp_size_kb "$wt")
  [[ -z "$size_kb" || "$size_kb" -lt 1024 ]] && return 0
  local size_bytes=$((size_kb * 1024))
  local size_human
  size_human=$(bytes_to_human "$size_bytes")
  local wt_name
  wt_name=$(basename "$wt")

  # Classification
  local state="" tier="" meta=""

  if [[ "$locked" -eq 1 ]]; then
    state="locked"
  elif ! git -C "$wt" status --porcelain >/dev/null 2>&1; then
    # fail closed: an unreadable worktree is never "clean"
    state="unreadable (git status failed)"
  elif [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ]]; then
    state="dirty (uncommitted changes)"
  elif [[ -n "$(find "$wt" -maxdepth 3 -name ".env*" -print 2>/dev/null | head -1)" ]]; then
    # git-clean is blind to ignored files; .env* may hold unrecoverable secrets
    state="contains .env files"
  else
    local wt_head
    wt_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [[ -z "$wt_head" ]]; then
      state="unreadable"
    else
      local merge_kind=""
      if git -C "$repo" merge-base --is-ancestor "$wt_head" "$default_branch" 2>/dev/null; then
        merge_kind="merged"
      else
        # Squash-merge detection: `git cherry` marks commits whose patch
        # already exists upstream with "-". All "-" = effectively merged.
        # patch-id can collide (identical change made twice), so a
        # squash-merged worktree is only deletable when its branch is ALSO
        # backed up on origin - then removal can lose nothing either way.
        local cherry
        cherry=$(git -C "$repo" cherry "$default_branch" "$wt_head" 2>/dev/null || true)
        if [[ -n "$cherry" ]] && ! printf '%s\n' "$cherry" | grep -q '^+'; then
          local wt_branch remote_head
          wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
          remote_head=""
          if [[ -n "$wt_branch" && "$wt_branch" != "HEAD" ]]; then
            remote_head=$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/${wt_branch}" 2>/dev/null || true)
          fi
          if [[ -n "$remote_head" && "$remote_head" == "$wt_head" ]]; then
            merge_kind="squash-merged"
          else
            state="squash-merged (branch not pushed - review)"
          fi
        fi
      fi

      if [[ -n "$merge_kind" ]]; then
        # Merged + clean. Check idle age before calling it safe.
        local head_epoch
        head_epoch=$(git -C "$wt" log -1 --format=%ct 2>/dev/null)
        if [[ -n "$head_epoch" && $((now_epoch - head_epoch)) -ge "$max_age_sec" ]]; then
          tier="worktree"
          meta="remove:${repo}"
          state="${merge_kind}, clean, idle ${DEVPURGE_WORKTREE_AGE_DAYS}d+"
        else
          state="${merge_kind} but recently active"
        fi
      elif [[ -z "$state" ]]; then
        state="unmerged branch"
      fi
    fi
  fi

  if [[ -n "$tier" ]]; then
    WT_COUNT=$((WT_COUNT + 1))
    local id
    id=$(printf "W%02d" "$WT_COUNT")
    SCAN_RESULTS+=("${id}|${wt}|worktree|worktree: ${wt_name} (${state})|${size_human}|${size_bytes}|${meta}")
    SCAN_TOTAL_BYTES=$((SCAN_TOTAL_BYTES + size_bytes))
    DEVPURGE_WT_ROOTS+=("$wt")
  else
    RV_COUNT=$((RV_COUNT + 1))
    local id
    id=$(printf "R%02d" "$RV_COUNT")
    SCAN_RESULTS+=("${id}|${wt}|review|worktree: ${wt_name} (${state})|${size_human}|${size_bytes}|")
    SCAN_REVIEW_BYTES=$((SCAN_REVIEW_BYTES + size_bytes))
  fi

  printf "\r  Scanning worktrees: %-6s  %s" "$size_human" "$wt_name"
  return 0
}

# Entry point: scan all main repos under the standard search dirs
devpurge_scan_worktrees() {
  local search_dirs=(Desktop Documents Projects Developer src repos code dev workspace work)
  local seen_repos=""

  for dir_name in "${search_dirs[@]}"; do
    local search_path="${HOME}/${dir_name}"
    [[ -d "$search_path" ]] || continue

    while IFS= read -r gitdir; do
      [[ -z "$gitdir" ]] && continue
      # Only main repos (.git is a directory; worktrees have a .git file)
      [[ -d "$gitdir" ]] || continue
      local repo
      repo=$(dirname "$gitdir")

      case "$seen_repos" in
        *"|${repo}|"*) continue ;;
      esac
      seen_repos="${seen_repos}|${repo}|"

      _dp_scan_repo_worktrees "$repo"
      if [[ "${DEVPURGE_SKIP_BRANCHES:-}" != "1" ]]; then
        _dp_scan_repo_branches "$repo"
      fi
    done < <(find "$search_path" -maxdepth 3 -name .git 2>/dev/null)
  done
  return 0
}
