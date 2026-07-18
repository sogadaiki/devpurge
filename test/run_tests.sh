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
assert_contains "version output" "devpurge 0.5.1" "$version_output"

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
