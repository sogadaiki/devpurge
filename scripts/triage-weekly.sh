#!/bin/bash
# devpurge - 週次AI triageレポート (launchd: com.sadame.devpurge-triage)
#
# 層2の自走版。devpurge --json のスキャン結果を claude -p (sonnet) が読み、
# 「今週のデータ負債レポート」を Discord (mai-dm) に投稿する。
# ★report-only: このスクリプトは何も削除・quarantineしない。
#   実行は CEO が対話セッションで /devpurge-triage を呼んだ時のみ。
#
# 手動テスト: DEVPURGE_TRIAGE_DRY=1 bash scripts/triage-weekly.sh
set -uo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="${HOME:-/Users/daiki12}"

DEVPURGE_BIN="/usr/local/bin/devpurge"
CLAUDE_BIN="${HOME}/.local/bin/claude"
WORK_DIR="/tmp/devpurge-triage"
LOG_DIR="${HOME}/Library/Logs"
DISCORD_NOTIFY="${HOME}/.mai/scripts/discord-notify.mjs"
DRY="${DEVPURGE_TRIAGE_DRY:-0}"

mkdir -p "$WORK_DIR"

notify_error() {
  [ "$DRY" = "1" ] && { echo "[DRY] error: $1"; return 0; }
  node "$DISCORD_NOTIFY" send --channel mai-dm --persona mai --preset error \
    --title "devpurge週次triage失敗" --content "$1" 2>/dev/null || true
}

# ── 1. スキャン ───────────────────────────────────────────────────────────────
if ! "$DEVPURGE_BIN" --json > "${WORK_DIR}/scan.json" 2>"${WORK_DIR}/scan.err"; then
  notify_error "devpurge --json が失敗。ログ: ${WORK_DIR}/scan.err"
  exit 1
fi
if ! python3 -c "import json;json.load(open('${WORK_DIR}/scan.json'))" 2>/dev/null; then
  notify_error "devpurge --json の出力がJSONとして不正"
  exit 1
fi

# quarantineの状態も添える
"$DEVPURGE_BIN" quarantine --list > "${WORK_DIR}/quarantine.txt" 2>/dev/null || true

# ── 2. AI分析 (report-only) ──────────────────────────────────────────────────
PROMPT_FILE="${WORK_DIR}/prompt.txt"
cat > "$PROMPT_FILE" <<'PROMPT'
あなたはdevpurgeの週次triageレポート担当。以下の2ファイルだけを読んで、Discord向けの簡潔な日本語レポートを出力せよ。ファイル編集・削除・quarantine実行は一切禁止（レポート作成のみ）。

読むファイル:
- /tmp/devpurge-triage/scan.json (devpurgeスキャン結果)
- /tmp/devpurge-triage/quarantine.txt (隔離の現況)

レポート構成 (Discord 1800字以内、マークダウン):
1. **即削除可能** (deletable=trueの合計GBと上位3件)
2. **AI判定待ち** (tier=reviewのworktree/バックアップ系で判定価値のあるもの上位3件。Downloads/Movies等の恒常項目は省く)
3. **隔離の期限** (quarantine.txtでEXPIREDまたは残り7日以内のものがあれば警告)
4. **推奨アクション1行** (例:「対話セッションで /devpurge-triage 実行を推奨」or「今週は対応不要」)

数字はscan.jsonの実データのみ使用。推測でサイズを書くな。
PROMPT

CLAUDE_OUT="${WORK_DIR}/claude-out.json"
if ! "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" --model sonnet --output-format json > "$CLAUDE_OUT" 2>"${WORK_DIR}/claude.err"; then
  notify_error "claude -p 実行失敗。ログ: ${WORK_DIR}/claude.err"
  exit 1
fi

# 成功判定: is_error=false かつ result非空 (exit 0 ≠ 成功。refusal対策)
REPORT=$(python3 - "$CLAUDE_OUT" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if d.get("is_error") or not str(d.get("result", "")).strip():
    sys.exit(1)
print(str(d["result"])[:1800])
PY
) || { notify_error "claude -p が空応答/エラー応答 (refusalの可能性)。${CLAUDE_OUT} を確認"; exit 1; }

# ── 3. Discord投稿 ───────────────────────────────────────────────────────────
if [ "$DRY" = "1" ]; then
  echo "[DRY] 以下をmai-dmへ投稿する想定:"
  echo "----------------------------------------"
  echo "$REPORT"
  echo "----------------------------------------"
  exit 0
fi

if node "$DISCORD_NOTIFY" send --channel mai-dm --persona mai --preset analytics \
  --title "📦 devpurge 週次データ負債レポート" --content "$REPORT" 2>>"${LOG_DIR}/devpurge-triage.log"; then
  echo "$(date '+%Y-%m-%d %H:%M') triage report posted" >> "${LOG_DIR}/devpurge-triage.log"
else
  echo "$(date '+%Y-%m-%d %H:%M') discord post FAILED" >> "${LOG_DIR}/devpurge-triage.log"
  exit 1
fi
