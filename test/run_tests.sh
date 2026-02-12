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
source "${PROJECT_DIR}/lib/utils.sh"
source "${PROJECT_DIR}/lib/paths.sh"
source "${PROJECT_DIR}/lib/scan.sh"
source "${PROJECT_DIR}/lib/report.sh"
source "${PROJECT_DIR}/lib/cleanup.sh"
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

# Whitelist blocks unknown paths
assert_exit_code "whitelist blocks Desktop" 1 devpurge_path_allowed "${HOME}/Desktop/test"
assert_exit_code "whitelist blocks Documents" 1 devpurge_path_allowed "${HOME}/Documents/test"
assert_exit_code "whitelist blocks root" 1 devpurge_path_allowed "/tmp/test"

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
printf "\n=== test_cli ===\n\n"
# ══════════════════════════════════════════════════════════════════════════════

# --version
version_output=$("${PROJECT_DIR}/bin/devpurge" --version 2>&1)
assert_contains "version output" "devpurge 0.1.0" "$version_output"

# --help
help_output=$("${PROJECT_DIR}/bin/devpurge" --help 2>&1)
assert_contains "help shows USAGE" "USAGE" "$help_output"
assert_contains "help shows OPTIONS" "OPTIONS" "$help_output"

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
