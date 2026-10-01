#!/bin/bash
# devpurge - 定期無人パージ (launchd: com.sadame.devpurge-purge, 月・木09:00)
# 旧crontab (0 9 */3 * *) はTCCで実行不能だったため launchd + FDA付きpython3
# wrapper 経由に移行 (2026-07-19)。
# worktree削除は ~/.devpurgerc の worktree_auto=1 でopt-in (2026-10-01有効化)。
# 対象はマージ済み or origin退避済み・clean・7日放置・一点物なしのみ。
# 削除したworktreeの復元情報は logs/removed-worktrees-*.tsv に残る。
set -uo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# ~/Library/Logs は devpurge 自身の掃除対象(D22)なので、ログはApp Support側に置く
LOG_DIR="${HOME}/Library/Application Support/devpurge/logs"
mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/purge-cron.log"

echo "=== $(date '+%Y-%m-%d %H:%M') devpurge unattended run ===" >> "$LOG"
/usr/local/bin/devpurge -y --no-color >> "$LOG" 2>&1
rc=$?
echo "=== exit=$rc ===" >> "$LOG"
exit "$rc"
