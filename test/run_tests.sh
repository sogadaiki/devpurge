#!/usr/bin/env bash
# devpurge - Test runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

# ── Test helpers ──────────────────────────────────────────────────────────────
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    printf "  PASS: %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  FAIL: %s\n" "$desc"
    printf "    expected: %s\n" "$expected"
    printf "    actual:   %s\n" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$actual" | grep -q "$expected"; then
    printf "  PASS: %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  FAIL: %s\n" "$desc"
    printf "    expected to contain: %s\n" "$expected"
    printf "    actual: %s\n" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local actual
  "$@" >/dev/null 2>&1 && actual=0 || actual=$?
  if [[ "$expected" == "$actual" ]]; then
    printf "  PASS: %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  FAIL: %s\n" "$desc"
    printf "    expected exit code: %s\n" "$expected"
    printf "    actual exit code:   %s\n" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# ── Source libraries ──────────────────────────────────────────────────────────
export DEVPURGE_NO_COLOR=1
export DEVPURGE_SKIP_NODE_MODULES=1
export DEVPURGE_SKIP_MISC_CACHES=1
export DEVPURGE_SKIP_WORKTREES=1
export DEVPURGE_SKIP_REVIEW=1
export DEVPURGE_SKIP_BRANCHES=1
export DEVPURGE_SKIP_DUPES=1
source "${PROJECT_DIR}/lib/utils.sh"
source "${PROJECT_DIR}/lib/config.sh"
source "${PROJECT_DIR}/lib/paths.sh"
source "${PROJECT_DIR}/lib/worktree.sh"
source "${PROJECT_DIR}/lib/branches.sh"
# Never contaminate the real weekly removal report with fixture deletions.
DEVPURGE_LOG_DIR="${TMPDIR:-/tmp}/devpurge-test-logs-$$"
source "${PROJECT_DIR}/lib/dupes.sh"
source "${PROJECT_DIR}/lib/scan.sh"
source "${PROJECT_DIR}/lib/report.sh"
source "${PROJECT_DIR}/lib/cleanup.sh"
source "${PROJECT_DIR}/lib/quarantine.sh"
source "${PROJECT_DIR}/lib/share.sh"

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_utils ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

# size_to_bytes
assert_eq "size_to_bytes 1G" "1073741824" "$(size_to_bytes '1G')"
assert_eq "size_to_bytes 500M" "524288000" "$(size_to_bytes '500M')"
assert_eq "size_to_bytes 12K" "12288" "$(size_to_bytes '12K')"

# bytes_to_human
assert_eq "bytes_to_human 1073741824" "1.0G" "$(bytes_to_human 1073741824)"
assert_eq "bytes_to_human 524288000" "500M" "$(bytes_to_human 524288000)"
assert_eq "bytes_to_human 12288" "12K" "$(bytes_to_human 12288)"

# urlencode
assert_eq "urlencode simple" "hello%20world" "$(urlencode 'hello world')"
assert_eq "urlencode special" "hello%23world" "$(urlencode 'hello#world')"

# tier_label_plain
assert_eq "tier_label_plain ai" "AI-Era" "$(tier_label_plain ai)"
assert_eq "tier_label_plain dev" "DevTool" "$(tier_label_plain dev)"
assert_eq "tier_label_plain caution" "Caution" "$(tier_label_plain caution)"
assert_eq "tier_label_plain project" "Project" "$(tier_label_plain project)"
assert_eq "tier_label_plain system" "System" "$(tier_label_plain system)"

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_paths ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

# DEVPURGE_PATHS should have entries
TOTAL=$((TOTAL + 1))
if [[ ${#DEVPURGE_PATHS[@]} -gt 0 ]]; then
  printf "  PASS: DEVPURGE_PATHS is non-empty (%d entries)\n" "${#DEVPURGE_PATHS[@]}"
  PASS=$((PASS + 1))
else
  printf "  FAIL: DEVPURGE_PATHS is empty\n"
  FAIL=$((FAIL + 1))
fi

# Whitelist allows known paths
assert_exit_code "whitelist allows Library/Caches" 0 devpurge_path_allowed "${HOME}/Library/Caches/test"
assert_exit_code "whitelist allows .cache" 0 devpurge_path_allowed "${HOME}/.cache/test"
assert_exit_code "whitelist allows .npm" 0 devpurge_path_allowed "${HOME}/.npm/test"

# Whitelist allows node_modules under $HOME
assert_exit_code "whitelist allows node_modules" 0 devpurge_path_allowed "${HOME}/Desktop/myproject/node_modules"
assert_exit_code "whitelist allows nested node_modules" 0 devpurge_path_allowed "${HOME}/Documents/work/app/node_modules"

# Whitelist blocks unknown paths
assert_exit_code "whitelist blocks Desktop" 1 devpurge_path_allowed "${HOME}/Desktop/test"
assert_exit_code "whitelist blocks Documents" 1 devpurge_path_allowed "${HOME}/Documents/test"
assert_exit_code "whitelist blocks root" 1 devpurge_path_allowed "/tmp/test"

# System whitelist blocked when not root
DEVPURGE_IS_ROOT=0
assert_exit_code "system paths blocked when not root" 1 devpurge_path_allowed "/private/var/vm/sleepimage"
assert_exit_code "system /Library blocked when not root" 1 devpurge_path_allowed "/Library/Updates"

# System whitelist allowed when root
DEVPURGE_IS_ROOT=1
assert_exit_code "system paths allowed when root" 0 devpurge_path_allowed "/private/var/vm/sleepimage"
assert_exit_code "system /Library allowed when root" 0 devpurge_path_allowed "/Library/Updates"
assert_exit_code "system diagnostics allowed when root" 0 devpurge_path_allowed "/private/var/db/diagnostics"
DEVPURGE_IS_ROOT=0

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_scan ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

# Create temp directories to scan (must be under $HOME for whitelist/cleanup checks)
TMPDIR_TEST="${HOME}/.devpurge-test-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "${TMPDIR_TEST}/cache1"
dd if=/dev/zero of="${TMPDIR_TEST}/cache1/file1" bs=1024 count=100 2>/dev/null

# Override paths for testing
DEVPURGE_PATHS_BACKUP=("${DEVPURGE_PATHS[@]}")
DEVPURGE_PATHS=(
  "T01|${TMPDIR_TEST}/cache1|ai|Test cache 1"
  "T02|${TMPDIR_TEST}/nonexistent|dev|Test nonexistent"
)

# Also temporarily allow the temp dir in whitelist
DEVPURGE_WHITELIST_BACKUP=("${DEVPURGE_WHITELIST[@]}")
DEVPURGE_WHITELIST=("${TMPDIR_TEST}/")

devpurge_scan "all" 2>/dev/null

# Should find cache1 but not nonexistent
TOTAL=$((TOTAL + 1))
if [[ ${#SCAN_RESULTS[@]} -eq 1 ]]; then
  printf "  PASS: scan found 1 result (skipped nonexistent)\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: scan found %d results (expected 1)\n" "${#SCAN_RESULTS[@]}"
  FAIL=$((FAIL + 1))
fi

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_cleanup ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

# Test cleanup deletes the directory
devpurge_cleanup "all" 2>/dev/null

TOTAL=$((TOTAL + 1))
if [[ ! -d "${TMPDIR_TEST}/cache1" ]]; then
  printf "  PASS: cleanup deleted test cache\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: cleanup did not delete test cache\n"
  FAIL=$((FAIL + 1))
fi

assert_eq "cleanup deleted count" "1" "$CLEANUP_DELETED"

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_share ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

# Mock cleanup log for share test
CLEANUP_LOG=("T01|OK|102400|Test cache 1|Deleted")
CLEANUP_FREED_BYTES=102400

# Capture share output (non-interactive)
share_output=$(devpurge_share </dev/null 2>/dev/null || true)
assert_contains "share text has devpurge" "devpurge" "$share_output"
assert_contains "share text has repo URL" "github.com/sogadaiki/devpurge" "$share_output"

# Restore original paths
DEVPURGE_PATHS=("${DEVPURGE_PATHS_BACKUP[@]}")
DEVPURGE_WHITELIST=("${DEVPURGE_WHITELIST_BACKUP[@]}")

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_exclude ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

# Test devpurge_is_excluded
DEVPURGE_EXCLUDES=("${HOME}/test/node_modules" "${HOME}/other/cache")

assert_exit_code "is_excluded matches exact path" 0 devpurge_is_excluded "${HOME}/test/node_modules"
assert_exit_code "is_excluded matches second entry" 0 devpurge_is_excluded "${HOME}/other/cache"
assert_exit_code "is_excluded rejects non-excluded" 1 devpurge_is_excluded "${HOME}/different/path"

# Test exclude filters scan results
TMPDIR_EXCL="${HOME}/.devpurge-test-excl-$$"
mkdir -p "${TMPDIR_EXCL}/keep" "${TMPDIR_EXCL}/skip"
dd if=/dev/zero of="${TMPDIR_EXCL}/keep/file1" bs=1024 count=100 2>/dev/null
dd if=/dev/zero of="${TMPDIR_EXCL}/skip/file1" bs=1024 count=100 2>/dev/null

DEVPURGE_PATHS_BACKUP2=("${DEVPURGE_PATHS[@]}")
DEVPURGE_WHITELIST_BACKUP2=("${DEVPURGE_WHITELIST[@]}")
DEVPURGE_PATHS=(
  "T01|${TMPDIR_EXCL}/keep|ai|Test keep"
  "T02|${TMPDIR_EXCL}/skip|dev|Test skip"
)
DEVPURGE_WHITELIST=("${TMPDIR_EXCL}/")
DEVPURGE_EXCLUDES=("${TMPDIR_EXCL}/skip")

devpurge_scan "all" 2>/dev/null

TOTAL=$((TOTAL + 1))
if [[ ${#SCAN_RESULTS[@]} -eq 1 ]]; then
  printf "  PASS: exclude filtered out 1 path from scan\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: scan found %d results (expected 1 after exclude)\n" "${#SCAN_RESULTS[@]}"
  FAIL=$((FAIL + 1))
fi

# Test rc file loading
RC_TEST_FILE="${TMPDIR_EXCL}/testrc"
printf "# comment line\nexclude=~/test/path1\nexclude=/absolute/path2\n\nexclude=~/trail/\n" > "$RC_TEST_FILE"

DEVPURGE_EXCLUDES=()
# Override HOME temporarily for rc test
_orig_home="$HOME"
HOME="$TMPDIR_EXCL"
ln -sf "$RC_TEST_FILE" "${TMPDIR_EXCL}/.devpurgerc"
devpurge_load_rc
HOME="$_orig_home"

assert_eq "rc loads 3 entries" "3" "${#DEVPURGE_EXCLUDES[@]}"
assert_eq "rc expands tilde" "${TMPDIR_EXCL}/test/path1" "${DEVPURGE_EXCLUDES[0]}"
assert_eq "rc keeps absolute" "/absolute/path2" "${DEVPURGE_EXCLUDES[1]}"
assert_eq "rc strips trailing slash" "${TMPDIR_EXCL}/trail" "${DEVPURGE_EXCLUDES[2]}"

# Cleanup
rm -rf "$TMPDIR_EXCL"
DEVPURGE_EXCLUDES=()
DEVPURGE_PATHS=("${DEVPURGE_PATHS_BACKUP2[@]}")
DEVPURGE_WHITELIST=("${DEVPURGE_WHITELIST_BACKUP2[@]}")

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_exclude_prefix ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

DEVPURGE_EXCLUDES=("${HOME}/test/node_modules")
assert_exit_code "exclude matches child path" 0 devpurge_is_excluded "${HOME}/test/node_modules/react"
assert_exit_code "exclude rejects sibling prefix" 1 devpurge_is_excluded "${HOME}/test/node_modules-other"
DEVPURGE_EXCLUDES=()

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_rm_guard ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

assert_exit_code "guard blocks empty path" 1 devpurge_rm_guard ""
assert_exit_code "guard blocks root" 1 devpurge_rm_guard "/"
assert_exit_code "guard blocks HOME itself" 1 devpurge_rm_guard "$HOME"
assert_exit_code "guard blocks relative path" 1 devpurge_rm_guard "Library/Caches"
assert_exit_code "guard blocks traversal" 1 devpurge_rm_guard "${HOME}/Library/../.ssh"
assert_exit_code "guard allows normal path" 0 devpurge_rm_guard "${HOME}/Library/Caches/foo"

GUARD_LINK="${HOME}/.devpurge-test-link-$$"
ln -s /tmp "$GUARD_LINK"
assert_exit_code "guard blocks symlink target" 1 devpurge_rm_guard "$GUARD_LINK"
rm -f "$GUARD_LINK"

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_review_protection ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

REVIEW_TMP="${HOME}/.devpurge-test-review-$$"
mkdir -p "$REVIEW_TMP/userdata"
dd if=/dev/zero of="${REVIEW_TMP}/userdata/file1" bs=1024 count=100 2>/dev/null

DEVPURGE_WHITELIST_BACKUP3=("${DEVPURGE_WHITELIST[@]}")
DEVPURGE_WHITELIST=("${REVIEW_TMP}/")
SCAN_RESULTS=("V99|${REVIEW_TMP}/userdata|review|Test review data|100K|102400|")
devpurge_cleanup "all" >/dev/null 2>&1

TOTAL=$((TOTAL + 1))
if [[ -d "${REVIEW_TMP}/userdata" ]]; then
  printf "  PASS: review tier survives cleanup all\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: review tier was deleted\n"
  FAIL=$((FAIL + 1))
fi
assert_eq "review cleanup deleted count" "0" "$CLEANUP_DELETED"

rm -rf "$REVIEW_TMP"
DEVPURGE_WHITELIST=("${DEVPURGE_WHITELIST_BACKUP3[@]}")

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_worktree ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

WT_TMP="${HOME}/.devpurge-test-wt-$$"
mkdir -p "${WT_TMP}/repo"
git -C "${WT_TMP}/repo" init -q -b main
git -C "${WT_TMP}/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
dd if=/dev/zero of="${WT_TMP}/repo/blob" bs=1024 count=2048 2>/dev/null
git -C "${WT_TMP}/repo" add blob
git -C "${WT_TMP}/repo" -c user.name=t -c user.email=t@t commit -q -m blob

git -C "${WT_TMP}/repo" worktree add -q "${WT_TMP}/wt-merged" -b feat-merged
git -C "${WT_TMP}/repo" worktree add -q "${WT_TMP}/wt-dirty" -b feat-dirty
echo "x" > "${WT_TMP}/wt-dirty/untracked.txt"

# Merged+clean with age 0 -> deletable; dirty -> review
SCAN_RESULTS=()
SCAN_TOTAL_BYTES=0
SCAN_REVIEW_BYTES=0
WT_COUNT=0
RV_COUNT=0
DEVPURGE_WT_ROOTS=()
DEVPURGE_WORKTREE_AGE_DAYS=0
_dp_scan_repo_worktrees "${WT_TMP}/repo" >/dev/null

wt_entries=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "|worktree|" || true)
rv_entries=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "|review|" || true)
assert_eq "merged+clean worktree is deletable" "1" "$wt_entries"
assert_eq "dirty worktree is review-only" "1" "$rv_entries"

# Cleanup removes the merged worktree via git, leaves the dirty one
devpurge_cleanup "all" >/dev/null 2>&1

TOTAL=$((TOTAL + 1))
if [[ ! -d "${WT_TMP}/wt-merged" ]]; then
  printf "  PASS: cleanup removed merged worktree via git\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: merged worktree still exists\n"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if [[ -d "${WT_TMP}/wt-dirty" ]]; then
  printf "  PASS: dirty worktree untouched\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: dirty worktree was deleted\n"
  FAIL=$((FAIL + 1))
fi

git -C "${WT_TMP}/repo" worktree remove --force "${WT_TMP}/wt-dirty" >/dev/null 2>&1 || true
rm -rf "$WT_TMP"
DEVPURGE_WORKTREE_AGE_DAYS=7

# ── Unattended gating: -y must NOT remove worktrees without opt-in ──────────
WT_TMP2="${HOME}/.devpurge-test-wt2-$$"
mkdir -p "${WT_TMP2}/repo"
git -C "${WT_TMP2}/repo" init -q -b main
git -C "${WT_TMP2}/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
dd if=/dev/zero of="${WT_TMP2}/repo/blob" bs=1024 count=2048 2>/dev/null
git -C "${WT_TMP2}/repo" add blob
git -C "${WT_TMP2}/repo" -c user.name=t -c user.email=t@t commit -q -m blob
git -C "${WT_TMP2}/repo" worktree add -q "${WT_TMP2}/wt-auto" -b feat-auto

SCAN_RESULTS=("W01|${WT_TMP2}/wt-auto|worktree|worktree: wt-auto (merged, clean)|2M|2097152|remove:${WT_TMP2}/repo")
DEVPURGE_WORKTREE_AGE_DAYS=0
OPT_YES=1
DEVPURGE_WORKTREE_AUTO=0
devpurge_cleanup "all" >/dev/null 2>&1

TOTAL=$((TOTAL + 1))
if [[ -d "${WT_TMP2}/wt-auto" ]]; then
  printf "  PASS: unattended run skips worktree removal\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: unattended run removed worktree without opt-in\n"
  FAIL=$((FAIL + 1))
fi

DEVPURGE_WORKTREE_AUTO=1
devpurge_cleanup "all" >/dev/null 2>&1

TOTAL=$((TOTAL + 1))
if [[ ! -d "${WT_TMP2}/wt-auto" ]]; then
  printf "  PASS: worktree_auto=1 enables unattended removal\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: worktree_auto=1 did not remove worktree\n"
  FAIL=$((FAIL + 1))
fi

OPT_YES=0
DEVPURGE_WORKTREE_AUTO=0
rm -rf "$WT_TMP2"
DEVPURGE_WORKTREE_AGE_DAYS=7

# ── .env guard: worktree containing .env files is review-only ───────────────
WT_TMP3="${HOME}/.devpurge-test-wt3-$$"
mkdir -p "${WT_TMP3}/repo"
git -C "${WT_TMP3}/repo" init -q -b main
git -C "${WT_TMP3}/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
dd if=/dev/zero of="${WT_TMP3}/repo/blob" bs=1024 count=2048 2>/dev/null
printf "blob\n.env.local\n" > "${WT_TMP3}/repo/.gitignore"
git -C "${WT_TMP3}/repo" add .gitignore
git -C "${WT_TMP3}/repo" -c user.name=t -c user.email=t@t commit -q -m gitignore
git -C "${WT_TMP3}/repo" worktree add -q "${WT_TMP3}/wt-env" -b feat-env
dd if=/dev/zero of="${WT_TMP3}/wt-env/blob" bs=1024 count=2048 2>/dev/null
echo "SECRET=x" > "${WT_TMP3}/wt-env/.env.local"

SCAN_RESULTS=()
WT_COUNT=0
RV_COUNT=0
DEVPURGE_WT_ROOTS=()
DEVPURGE_WORKTREE_AGE_DAYS=0
_dp_scan_repo_worktrees "${WT_TMP3}/repo" >/dev/null

env_review=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "contains .env files" || true)
assert_eq "worktree with .env is review-only" "1" "$env_review"

git -C "${WT_TMP3}/repo" worktree remove --force "${WT_TMP3}/wt-env" >/dev/null 2>&1 || true
rm -rf "$WT_TMP3"
DEVPURGE_WORKTREE_AGE_DAYS=7

# ── Symlinked parent must not escape the whitelist ──────────────────────────
SYM_TMP="${HOME}/.devpurge-test-sym-$$"
SYM_OUTSIDE="${TMPDIR:-/tmp}/devpurge-sym-target-$$"
mkdir -p "$SYM_OUTSIDE/payload"
ln -s "$SYM_OUTSIDE" "$SYM_TMP"

DEVPURGE_WHITELIST_BACKUP4=("${DEVPURGE_WHITELIST[@]}")
DEVPURGE_WHITELIST=("${SYM_TMP}/")
SCAN_RESULTS=("Z01|${SYM_TMP}/payload|dev|Symlink escape test|1K|1024|")
devpurge_cleanup "all" >/dev/null 2>&1

TOTAL=$((TOTAL + 1))
if [[ -d "$SYM_OUTSIDE/payload" ]]; then
  printf "  PASS: symlinked parent blocked from deletion\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: deletion escaped through symlinked parent\n"
  FAIL=$((FAIL + 1))
fi

rm -f "$SYM_TMP"
rm -rf "$SYM_OUTSIDE"
DEVPURGE_WHITELIST=("${DEVPURGE_WHITELIST_BACKUP4[@]}")

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_protected ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

assert_exit_code "protected: 証拠 path" 0 devpurge_is_protected "${HOME}/Desktop/案件/証拠保全/video.mp4"
assert_exit_code "protected: 準備書面" 0 devpurge_is_protected "${HOME}/Documents/準備書面_v3.docx"
assert_exit_code "protected: 原本" 0 devpurge_is_protected "${HOME}/Movies/動画原本_20260613.mp4"
assert_exit_code "not protected: cache path" 1 devpurge_is_protected "${HOME}/Library/Caches/npm"
assert_exit_code "not protected: legalchecker repo" 1 devpurge_is_protected "${HOME}/Desktop/development/new-legalchecker/frontend/node_modules"

# rc protect= extension
DEVPURGE_PROTECT_PATTERNS+=("my-precious")
assert_exit_code "protected: custom pattern" 0 devpurge_is_protected "${HOME}/Desktop/my-precious-data"

# Cleanup refuses protected entries even when whitelisted and selected
PROT_TMP="${HOME}/.devpurge-test-prot-$$"
mkdir -p "${PROT_TMP}/証拠データ"
dd if=/dev/zero of="${PROT_TMP}/証拠データ/file1" bs=1024 count=10 2>/dev/null
DEVPURGE_WHITELIST_BACKUP5=("${DEVPURGE_WHITELIST[@]}")
DEVPURGE_WHITELIST=("${PROT_TMP}/")
SCAN_RESULTS=("P01|${PROT_TMP}/証拠データ|dev|Protected test|10K|10240|")
devpurge_cleanup "all" >/dev/null 2>&1

TOTAL=$((TOTAL + 1))
if [[ -d "${PROT_TMP}/証拠データ" ]]; then
  printf "  PASS: cleanup refuses protected path\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: protected path was deleted\n"
  FAIL=$((FAIL + 1))
fi
rm -rf "$PROT_TMP"
DEVPURGE_WHITELIST=("${DEVPURGE_WHITELIST_BACKUP5[@]}")

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_quarantine ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

Q_TMP="${HOME}/.devpurge-test-q-$$"
mkdir -p "${Q_TMP}/target"
dd if=/dev/zero of="${Q_TMP}/target/file1" bs=1024 count=100 2>/dev/null
DEVPURGE_QUARANTINE_DIR="${Q_TMP}/quarantine"
DEVPURGE_QUARANTINE_DAYS=30

# add
devpurge_quarantine_add "${Q_TMP}/target" "test reason" >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if [[ ! -d "${Q_TMP}/target" && -d "${DEVPURGE_QUARANTINE_DIR}/Q001-target" ]]; then
  printf "  PASS: quarantine add moves target\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: quarantine add did not move target\n"
  FAIL=$((FAIL + 1))
fi

# list shows entry
q_list=$(devpurge_quarantine_list 2>/dev/null)
assert_contains "quarantine list shows ID" "Q001" "$q_list"
assert_contains "quarantine list shows reason" "test reason" "$q_list"

# protected path refused
mkdir -p "${Q_TMP}/裁判資料"
assert_exit_code "quarantine refuses protected path" 1 devpurge_quarantine_add "${Q_TMP}/裁判資料" "should fail"
rm -rf "${Q_TMP}/裁判資料"

# restore
devpurge_quarantine_restore "Q001" >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if [[ -d "${Q_TMP}/target" && -f "${Q_TMP}/target/file1" ]]; then
  printf "  PASS: quarantine restore returns target\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: quarantine restore failed\n"
  FAIL=$((FAIL + 1))
fi

# restore drops the manifest row
TOTAL=$((TOTAL + 1))
if ! grep -q "^Q001	" "${DEVPURGE_QUARANTINE_DIR}/manifest.tsv" 2>/dev/null; then
  printf "  PASS: restore removes manifest row\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: restored row still in manifest\n"
  FAIL=$((FAIL + 1))
fi

# control characters in path are refused
mkdir -p "${Q_TMP}/evil"$'\t'"tab" 2>/dev/null
assert_exit_code "quarantine refuses tab in path" 1 devpurge_quarantine_add "${Q_TMP}/evil"$'\t'"tab" "x"
rm -rf "${Q_TMP}/evil"$'\t'"tab" 2>/dev/null

# expire: re-add, backdate the manifest, expire
devpurge_quarantine_add "${Q_TMP}/target" "expire test" >/dev/null 2>&1
q_last_id=$(cut -f1 "${DEVPURGE_QUARANTINE_DIR}/manifest.tsv" | tail -1)
old_epoch=$(( $(date +%s) - 40 * 86400 ))
sed -i '' "s/^${q_last_id}	[0-9]*	/${q_last_id}	${old_epoch}	/" "${DEVPURGE_QUARANTINE_DIR}/manifest.tsv"
devpurge_quarantine_expire >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if [[ ! -e "${DEVPURGE_QUARANTINE_DIR}/${q_last_id}-target" ]]; then
  printf "  PASS: quarantine expire deletes old entries\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: expired entry still present\n"
  FAIL=$((FAIL + 1))
fi

# expired row is dropped from the manifest (no future ID collision)
TOTAL=$((TOTAL + 1))
if ! grep -q "^${q_last_id}	" "${DEVPURGE_QUARANTINE_DIR}/manifest.tsv" 2>/dev/null; then
  printf "  PASS: expire removes manifest row\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: expired row still in manifest\n"
  FAIL=$((FAIL + 1))
fi

rm -rf "$Q_TMP"
unset DEVPURGE_QUARANTINE_DIR

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_branches ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

BR_TMP="${HOME}/.devpurge-test-br-$$"
mkdir -p "${BR_TMP}/repo"
git -C "${BR_TMP}/repo" init -q -b main
git -C "${BR_TMP}/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "${BR_TMP}/repo" branch merged-branch
git -C "${BR_TMP}/repo" checkout -q -b unmerged-branch
git -C "${BR_TMP}/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m extra
git -C "${BR_TMP}/repo" checkout -q main

DEVPURGE_LOG_DIR="${BR_TMP}/logs"
devpurge_delete_merged_branches "${BR_TMP}/repo" "main"
assert_eq "merged branch deleted count" "1" "$DELETED_BRANCH_COUNT"

TOTAL=$((TOTAL + 1))
if git -C "${BR_TMP}/repo" show-ref --verify --quiet refs/heads/unmerged-branch; then
  printf "  PASS: unmerged branch survives\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: unmerged branch was deleted\n"
  FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -q "merged-branch" "${DEVPURGE_LOG_DIR}"/deleted-branches-*.tsv 2>/dev/null; then
  printf "  PASS: deleted branch SHA logged for restore\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: no restore log written\n"
  FAIL=$((FAIL + 1))
fi
rm -rf "$BR_TMP"

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_squash_merge ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

SQ_TMP="${HOME}/.devpurge-test-sq-$$"
mkdir -p "${SQ_TMP}/repo"
git init --bare -q "${SQ_TMP}/origin.git"
git -C "${SQ_TMP}/repo" init -q -b main
git -C "${SQ_TMP}/repo" remote add origin "${SQ_TMP}/origin.git"
git -C "${SQ_TMP}/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "${SQ_TMP}/repo" worktree add -q "${SQ_TMP}/wt-squash" -b feat-squash
dd if=/dev/zero of="${SQ_TMP}/wt-squash/blob" bs=1024 count=2048 2>/dev/null
git -C "${SQ_TMP}/wt-squash" add blob
git -C "${SQ_TMP}/wt-squash" -c user.name=t -c user.email=t@t commit -q -m "add blob"
# Squash-merge into main (no merge commit, so is-ancestor is false)
git -C "${SQ_TMP}/repo" merge --squash feat-squash >/dev/null 2>&1
git -C "${SQ_TMP}/repo" -c user.name=t -c user.email=t@t commit -q -m "squashed: add blob"

# NOT pushed yet -> patch-id collision guard must demote to review
SCAN_RESULTS=()
WT_COUNT=0
RV_COUNT=0
DEVPURGE_WT_ROOTS=()
DEVPURGE_WORKTREE_AGE_DAYS=0
_dp_scan_repo_worktrees "${SQ_TMP}/repo" >/dev/null
sq_unpushed=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "branch not pushed" || true)
assert_eq "unpushed squash-merge is review-only" "1" "$sq_unpushed"

# Pushed to origin -> deletable
git -C "${SQ_TMP}/wt-squash" push -q origin feat-squash
SCAN_RESULTS=()
WT_COUNT=0
RV_COUNT=0
DEVPURGE_WT_ROOTS=()
_dp_scan_repo_worktrees "${SQ_TMP}/repo" >/dev/null
sq_deletable=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "squash-merged, clean" || true)
assert_eq "pushed squash-merged worktree is deletable" "1" "$sq_deletable"

git -C "${SQ_TMP}/repo" worktree remove --force "${SQ_TMP}/wt-squash" >/dev/null 2>&1 || true
rm -rf "$SQ_TMP"
DEVPURGE_WORKTREE_AGE_DAYS=7

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_ignored_unique ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

IG_TMP="${HOME}/.devpurge-test-ig-$$"
mkdir -p "${IG_TMP}/repo"
git -C "${IG_TMP}/repo" init -q -b main
printf "node_modules/\n*.sqlite\n" > "${IG_TMP}/repo/.gitignore"
git -C "${IG_TMP}/repo" add .gitignore
git -C "${IG_TMP}/repo" -c user.name=t -c user.email=t@t commit -q -m init
git -C "${IG_TMP}/repo" worktree add -q "${IG_TMP}/wt-ig" -b feat-ig
dd if=/dev/zero of="${IG_TMP}/wt-ig/blob" bs=1024 count=2048 2>/dev/null
git -C "${IG_TMP}/wt-ig" add blob
git -C "${IG_TMP}/wt-ig" -c user.name=t -c user.email=t@t commit -q -m blob
git -C "${IG_TMP}/repo" merge -q feat-ig >/dev/null 2>&1

# Regenerable ignored content only -> still deletable
mkdir -p "${IG_TMP}/wt-ig/node_modules/pkg"
echo "x" > "${IG_TMP}/wt-ig/node_modules/pkg/i.js"
SCAN_RESULTS=(); WT_COUNT=0; RV_COUNT=0; DEVPURGE_WT_ROOTS=()
DEVPURGE_WORKTREE_AGE_DAYS=0
_dp_scan_repo_worktrees "${IG_TMP}/repo" >/dev/null
ig_ok=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "merged, clean, idle" || true)
assert_eq "regenerable ignored content stays deletable" "1" "$ig_ok"

# One-of-a-kind ignored file -> demoted to review
echo "unique data" > "${IG_TMP}/wt-ig/localdata.sqlite"
SCAN_RESULTS=(); WT_COUNT=0; RV_COUNT=0; DEVPURGE_WT_ROOTS=()
_dp_scan_repo_worktrees "${IG_TMP}/repo" >/dev/null
ig_demoted=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "has ignored files" || true)
assert_eq "unique ignored file demotes to review" "1" "$ig_demoted"

# Build output (.open-next, *.tsbuildinfo, .godot) and .DS_Store under a
# non-ASCII folder are regenerable, not one-of-a-kind
rm -f "${IG_TMP}/wt-ig/localdata.sqlite"
printf ".open-next/\n*.tsbuildinfo\n.godot/\n.DS_Store\nnext-env.d.ts\n.refresh.lock\n" >> "$(git -C "${IG_TMP}/wt-ig" rev-parse --git-common-dir)/info/exclude"
mkdir -p "${IG_TMP}/wt-ig/apps/web/.open-next/.build" "${IG_TMP}/wt-ig/godot/.godot/editor" "${IG_TMP}/wt-ig/企画案"
echo x > "${IG_TMP}/wt-ig/apps/web/.open-next/.build/cache.cjs"
echo x > "${IG_TMP}/wt-ig/apps/web/tsconfig.tsbuildinfo"
echo x > "${IG_TMP}/wt-ig/godot/.godot/editor/a.cfg"
echo x > "${IG_TMP}/wt-ig/企画案/.DS_Store"
echo x > "${IG_TMP}/wt-ig/apps/web/next-env.d.ts"
echo x > "${IG_TMP}/wt-ig/企画案/.refresh.lock"
ig_unique=$(_dp_ignored_unique "${IG_TMP}/wt-ig")
assert_eq "build output and non-ASCII .DS_Store are regenerable" "" "$ig_unique"
echo "unique data" > "${IG_TMP}/wt-ig/localdata.sqlite"
assert_eq "generated files do not mask unique data" "localdata.sqlite" "$(_dp_ignored_unique "${IG_TMP}/wt-ig")"
rm -f "${IG_TMP}/wt-ig/localdata.sqlite"
# Empty fixture only: no real credentials are read or copied.
touch "${IG_TMP}/wt-ig/apps/web/.open-next/.build/.env.fixture"
assert_contains "deeply nested ignored env file remains protected" '.env.fixture' "$(_dp_ignored_unique "${IG_TMP}/wt-ig")"
assert_eq "failed ignored-file inspection stays in review" "ignored-file scan failed" "$(_dp_ignored_unique "${IG_TMP}/missing")"

git -C "${IG_TMP}/repo" worktree remove --force "${IG_TMP}/wt-ig" >/dev/null 2>&1 || true
rm -rf "$IG_TMP"
DEVPURGE_WORKTREE_AGE_DAYS=7

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_pushed_unmerged ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

PU_TMP="${HOME}/.devpurge-test-pu-$$"
mkdir -p "${PU_TMP}/repo"
git init --bare -q "${PU_TMP}/origin.git"
git -C "${PU_TMP}/repo" init -q -b main
git -C "${PU_TMP}/repo" remote add origin "${PU_TMP}/origin.git"
git -C "${PU_TMP}/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "${PU_TMP}/repo" worktree add -q "${PU_TMP}/wt-pu" -b feat-pu
dd if=/dev/zero of="${PU_TMP}/wt-pu/blob" bs=1024 count=2048 2>/dev/null
git -C "${PU_TMP}/wt-pu" add blob
git -C "${PU_TMP}/wt-pu" -c user.name=t -c user.email=t@t commit -q -m "unmerged work"
DEVPURGE_WORKTREE_AGE_DAYS=0

# Unmerged + not pushed -> review
SCAN_RESULTS=(); WT_COUNT=0; RV_COUNT=0; DEVPURGE_WT_ROOTS=()
_dp_scan_repo_worktrees "${PU_TMP}/repo" >/dev/null
pu_review=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "|review|.*unmerged branch (not pushed)" || true)
assert_eq "unpushed unmerged worktree is review-only" "1" "$pu_review"

# Unmerged + pushed + clean -> deletable (branch survives)
git -C "${PU_TMP}/wt-pu" push -q origin feat-pu
SCAN_RESULTS=(); WT_COUNT=0; RV_COUNT=0; DEVPURGE_WT_ROOTS=()
_dp_scan_repo_worktrees "${PU_TMP}/repo" >/dev/null
pu_ok=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "|worktree|.*unmerged, pushed, clean" || true)
assert_eq "pushed unmerged clean worktree is deletable" "1" "$pu_ok"

# Local commit on top of the pushed one -> back to review
git -C "${PU_TMP}/wt-pu" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "local only"
SCAN_RESULTS=(); WT_COUNT=0; RV_COUNT=0; DEVPURGE_WT_ROOTS=()
_dp_scan_repo_worktrees "${PU_TMP}/repo" >/dev/null
pu_ahead=$(printf '%s\n' "${SCAN_RESULTS[@]}" | grep -c "|review|.*not pushed" || true)
assert_eq "unpushed local commit demotes to review" "1" "$pu_ahead"
git -C "${PU_TMP}/wt-pu" push -q origin feat-pu

# Removal logs a restore record and keeps the branch
PU_LOG="${PU_TMP}/logs"
DEVPURGE_LOG_DIR="$PU_LOG"
pu_sha=$(git -C "${PU_TMP}/wt-pu" rev-parse HEAD)
git -C "${PU_TMP}/repo" worktree lock "${PU_TMP}/wt-pu"
assert_exit_code "locked removal is refused" 1 _dp_remove_worktree "${PU_TMP}/wt-pu" "${PU_TMP}/repo"
assert_contains "refused removal is logged as failed" "${pu_sha}.*failed" "$(cat "$PU_LOG"/worktree-removal-results-*.tsv)"
assert_exit_code "locked worktree is not eligible at deletion time" 1 _dp_worktree_removal_ready "${PU_TMP}/wt-pu" "${PU_TMP}/repo"
git -C "${PU_TMP}/repo" worktree unlock "${PU_TMP}/wt-pu"
SCAN_RESULTS=(); WT_COUNT=0; RV_COUNT=0; DEVPURGE_WT_ROOTS=()
_dp_scan_repo_worktrees "${PU_TMP}/repo" >/dev/null
printf '*.sqlite\n' >> "${PU_TMP}/repo/.git/info/exclude"
echo 'new unique data' > "${PU_TMP}/wt-pu/local.sqlite"
devpurge_cleanup "all" >/dev/null 2>&1
assert_eq "ignored data added after scan prevents removal" "1" "$CLEANUP_SKIPPED"
rm -f "${PU_TMP}/wt-pu/local.sqlite"
devpurge_cleanup "all" >/dev/null 2>&1
TOTAL=$((TOTAL + 1))
if [[ ! -d "${PU_TMP}/wt-pu" ]] && git -C "${PU_TMP}/repo" show-ref --verify --quiet refs/heads/feat-pu \
   && grep -q "feat-pu	${pu_sha}" "$PU_LOG"/removed-worktrees-*.tsv 2>/dev/null; then
  printf "  PASS: worktree removed, branch kept, restore record logged\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL: pushed worktree removal / restore log\n"
  FAIL=$((FAIL + 1))
fi
assert_contains "successful removal has separate confirmed result" "${pu_sha}.*removed" "$(cat "$PU_LOG"/worktree-removal-results-*.tsv)"
git -C "${PU_TMP}/repo" merge -q feat-pu
devpurge_delete_merged_branches "${PU_TMP}/repo" main
assert_exit_code "later merged-branch cleanup keeps recorded worktree branch" 0 git -C "${PU_TMP}/repo" show-ref --verify --quiet refs/heads/feat-pu
git -C "${PU_TMP}/repo" worktree add -q "${PU_TMP}/wt-restored" feat-pu
assert_eq "logged worktree can be restored from retained branch" "$pu_sha" "$(git -C "${PU_TMP}/wt-restored" rev-parse HEAD)"
DEVPURGE_LOG_DIR="${TMPDIR:-/tmp}/devpurge-test-logs-$$"
rm -rf "$PU_TMP"
DEVPURGE_WORKTREE_AGE_DAYS=7

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_duplicates_and_versions ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

DV_TMP="${HOME}/.devpurge-test-dv-$$"
mkdir -p "${DV_TMP}/a" "${DV_TMP}/b"
_mkrand() { head -c "$2" /dev/urandom > "$1"; }
_mkrand "${DV_TMP}/a/kate-video.mp4" 1500000
_mkrand "${DV_TMP}/a/kate-video-v2.mp4" 1500000
_mkrand "${DV_TMP}/a/kate-video-v3.mp4" 1500000
touch -t 202601010000 "${DV_TMP}/a/kate-video.mp4"
touch -t 202602010000 "${DV_TMP}/a/kate-video-v2.mp4"
_mkrand "${DV_TMP}/a/clip_1.mp4" 1500000
_mkrand "${DV_TMP}/a/clip_2.mp4" 1500000
_mkrand "${DV_TMP}/a/資料.pdf" 1500000
cp "${DV_TMP}/a/資料.pdf" "${DV_TMP}/a/資料のコピー.pdf"
touch -t 202601010000 "${DV_TMP}/a/資料.pdf"
_mkrand "${DV_TMP}/a/semifinal.mov" 1500000
_mkrand "${DV_TMP}/a/semi.mov" 1500000
_mkrand "${DV_TMP}/a/big.bin" 3000000
cp "${DV_TMP}/a/big.bin" "${DV_TMP}/b/big-renamed.bin"
touch -t 202601010000 "${DV_TMP}/a/big.bin"
_mkrand "${DV_TMP}/b/same-size.bin" 3000000

SCAN_RESULTS=(); RV_COUNT=0; SCAN_REVIEW_BYTES=0
DEVPURGE_DUPE_MIN_MB=1
_dp_scan_duplicates "$DV_TMP"
dv_out=$(printf '%s\n' "${SCAN_RESULTS[@]+"${SCAN_RESULTS[@]}"}")
assert_contains "renamed identical copy is detected" "b/big-renamed.bin|review|identical copy of: ${DV_TMP}/a/big.bin" "$dv_out"
assert_eq "same-size different content is not a duplicate" "0" "$(printf '%s\n' "$dv_out" | grep -c 'same-size.bin' || true)"

SCAN_RESULTS=(); RV_COUNT=0
_dp_scan_versions "$DV_TMP"
dv_ver=$(printf '%s\n' "${SCAN_RESULTS[@]+"${SCAN_RESULTS[@]}"}")
assert_eq "older v-suffixed versions reported (2 of 3)" "2" "$(printf '%s\n' "$dv_ver" | grep -c 'older version (newest: kate-video-v3.mp4)' || true)"
assert_contains "Japanese copy marker groups with original" "a/資料.pdf|review|older version (newest: 資料のコピー.pdf)" "$dv_ver"
assert_eq "bare _N parts are not versions" "0" "$(printf '%s\n' "$dv_ver" | grep -c 'clip_' || true)"
assert_eq "marker must follow a separator (semifinal)" "0" "$(printf '%s\n' "$dv_ver" | grep -c 'semi' || true)"

# Repeated worktree copies count once, while other repositories and changed
# bytes at the same relative path remain distinct review candidates.
git -C "${DV_TMP}/a" init -q -b main
git -C "${DV_TMP}/a" add .
git -C "${DV_TMP}/a" -c user.name=t -c user.email=t@t commit -q -m fixtures
git -C "${DV_TMP}/a" worktree add -q "${DV_TMP}/wt-copy" -b copy
git -C "${DV_TMP}/a" worktree add -q "${DV_TMP}/wt-changed" -b changed
mkdir -p "${DV_TMP}/other"
git -C "${DV_TMP}/other" init -q -b main
cp "${DV_TMP}/a/kate-video.mp4" "${DV_TMP}/other/kate-video.mp4"
cp "${DV_TMP}/a/kate-video-v3.mp4" "${DV_TMP}/other/kate-video-v3.mp4"
_mkrand "${DV_TMP}/wt-changed/kate-video.mp4" 1500000
for dv_dir in a wt-copy wt-changed other; do
  touch -t 202601010000 "${DV_TMP}/${dv_dir}/kate-video.mp4"
  touch -t 202602010000 "${DV_TMP}/${dv_dir}/kate-video-v3.mp4"
done
touch -t 202601020000 "${DV_TMP}/a/kate-video-v2.mp4" "${DV_TMP}/wt-copy/kate-video-v2.mp4" "${DV_TMP}/wt-changed/kate-video-v2.mp4"
assert_exit_code "same relative path in unrelated repos stays distinct" 1 _dp_same_repo_file "${DV_TMP}/a/kate-video.mp4" "${DV_TMP}/other/kate-video.mp4"
assert_exit_code "linked worktree shares repository identity" 0 _dp_same_repo_file "${DV_TMP}/a/kate-video.mp4" "${DV_TMP}/wt-copy/kate-video.mp4"
SCAN_RESULTS=(); RV_COUNT=0; SCAN_REVIEW_BYTES=0
_dp_scan_versions "$DV_TMP"
dv_ver=$(printf '%s\n' "${SCAN_RESULTS[@]+"${SCAN_RESULTS[@]}"}")
assert_eq "identical worktree versions collapse but distinct bytes and repos survive" "3" "$(printf '%s\n' "$dv_ver" | grep -c '/kate-video.mp4|review|' || true)"
assert_eq "repeated v2 is reported only once" "1" "$(printf '%s\n' "$dv_ver" | grep -c '/kate-video-v2.mp4|review|' || true)"
DEVPURGE_DUPE_MIN_MB=10
rm -rf "$DV_TMP"

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_json ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

SCAN_RESULTS=('T01|/tmp/x "y"|dev|Desc with "quote"|1K|1024|')
SCAN_TOTAL_BYTES=1024
SCAN_REVIEW_BYTES=0
json_output=$(devpurge_report_json)
assert_contains "json has version" "\"version\": \"${DEVPURGE_VERSION}\"" "$json_output"
assert_contains "json escapes quotes" 'Desc with \\\"quote\\\"' "$json_output"
TOTAL=$((TOTAL + 1))
if command -v python3 >/dev/null 2>&1; then
  if echo "$json_output" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    printf "  PASS: json parses cleanly\n"
    PASS=$((PASS + 1))
  else
    printf "  FAIL: json does not parse\n"
    FAIL=$((FAIL + 1))
  fi
else
  printf "  PASS: json parse check skipped (no python3)\n"
  PASS=$((PASS + 1))
fi

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== test_cli ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

# --version
version_output=$("${PROJECT_DIR}/bin/devpurge" --version 2>&1)
assert_contains "version output" "devpurge 0.6.0" "$version_output"

# --help
help_output=$("${PROJECT_DIR}/bin/devpurge" --help 2>&1)
assert_contains "help shows USAGE" "USAGE" "$help_output"
assert_contains "help shows OPTIONS" "OPTIONS" "$help_output"

# --exclude without arg
assert_exit_code "exclude without arg exits 1" 1 "${PROJECT_DIR}/bin/devpurge" --exclude

# --help shows exclude
help_exclude_output=$("${PROJECT_DIR}/bin/devpurge" --help 2>&1)
assert_contains "help shows --exclude" "exclude" "$help_exclude_output"

# Unknown option
assert_exit_code "unknown option exits 1" 1 "${PROJECT_DIR}/bin/devpurge" --bogus

# ══════════════════════════════════════════════════════════════════════════════
printf "\n=== Results ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

printf "  Total: %d  Pass: %d  Fail: %d\n\n" "$TOTAL" "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf "  FAILED\n\n"
  exit 1
else
  printf "  ALL TESTS PASSED\n\n"
  exit 0
fi
