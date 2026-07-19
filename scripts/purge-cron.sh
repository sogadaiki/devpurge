#!/bin/bash
# devpurge - 定期無人パージ (launchd: com.sadame.devpurge-purge, 月・木09:00)
# 旧crontab (0 9 */3 * *) はTCCで実行不能だったため launchd + FDA付きpython3
# wrapper 経由に移行 (2026-07-19)。
# worktree削除は worktree_auto 未設定なので常にスキップされる(安全設計)。
set -uo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
LOG="${HOME}/Library/Logs/devpurge-cron.log"

echo "=== $(date '+%Y-%m-%d %H:%M') devpurge unattended run ===" >> "$LOG"
/usr/local/bin/devpurge -y --no-color >> "$LOG" 2>&1
rc=$?
echo "=== exit=$rc ===" >> "$LOG"
exit "$rc"
