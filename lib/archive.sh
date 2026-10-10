#!/usr/bin/env bash
# Explicitly opted-in archive expiry, separate from the cache whitelist/quarantine.
DEVPURGE_ARCHIVE_ROOT="${DEVPURGE_ARCHIVE_ROOT:-}"
DEVPURGE_ARCHIVE_DAYS="${DEVPURGE_ARCHIVE_DAYS:-10}"
DEVPURGE_ARCHIVE_AUTO="${DEVPURGE_ARCHIVE_AUTO:-0}"

_dp_archive_run() {
  [[ -n "$DEVPURGE_ARCHIVE_ROOT" ]] || { dp_error "archive_root is not configured" >&2; return 1; }
  [[ "${DEVPURGE_IS_ROOT:-0}" != "1" ]] || { dp_error "Archive retention must run without sudo" >&2; return 1; }
  local args=(--home "$HOME" --root "$DEVPURGE_ARCHIVE_ROOT"
    --state-dir "${DEVPURGE_ARCHIVE_STATE_DIR:-${HOME}/Library/Application Support/devpurge/archive}"
    --days "$DEVPURGE_ARCHIVE_DAYS")
  local item
  for item in "${DEVPURGE_PROTECT_PATTERNS[@]+"${DEVPURGE_PROTECT_PATTERNS[@]}"}"; do args+=(--protect "$item"); done
  for item in "${DEVPURGE_EXCLUDES[@]+"${DEVPURGE_EXCLUDES[@]}"}"; do args+=(--exclude "$item"); done
  python3 "${DEVPURGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/archive.py" "${args[@]}" "$@"
}

devpurge_archive_observe() {
  [[ "${DEVPURGE_SKIP_ARCHIVE:-0}" != "1" && "$DEVPURGE_ARCHIVE_AUTO" == "1" && -n "$DEVPURGE_ARCHIVE_ROOT" && "${DEVPURGE_IS_ROOT:-0}" != "1" ]] || return 0
  _dp_archive_run observe >/dev/null
}

devpurge_scan_archive() {
  [[ "${DEVPURGE_SKIP_ARCHIVE:-0}" != "1" && "$DEVPURGE_ARCHIVE_AUTO" == "1" && -n "$DEVPURGE_ARCHIVE_ROOT" && "${DEVPURGE_IS_ROOT:-0}" != "1" ]] || return 0
  local output entry id path tier desc human bytes meta
  if ! output=$(_dp_archive_run scan --rows); then
    dp_warn "Archive retained: scan could not verify eligibility" >&2
    return 0
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    IFS='|' read -r id path tier desc human bytes meta <<< "$entry"
    SCAN_RESULTS+=("$entry")
    SCAN_TOTAL_BYTES=$((SCAN_TOTAL_BYTES + bytes))
  done <<< "$output"
}

devpurge_archive_expire() {
  [[ "$DEVPURGE_ARCHIVE_AUTO" == "1" ]] || { dp_error "Archive expiry requires archive_auto=1" >&2; return 1; }
  _dp_archive_run expire --authorized "$@"
}
