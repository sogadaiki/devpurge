# devpurge

> このファイルは Gemini CLI 用のプロジェクトルールです。
> Claude Code 版は CLAUDE.md を参照してください。

## Gemini CLI 固有ルール
- ワークスペース外ファイル（`~/.claude/`, `~/.mai/` 等）は `run_shell_command` + `cat` で読む
- gitignore対象ファイルも同様
- シークレットは `security find-generic-password -s "KEY_NAME" -a "claude-ops" -w` で取得
- `.env` ファイルは絶対に読まない

---

## プロジェクト概要
macOS向けキャッシュ削除CLIツール。

## 作業開始時の提案

セッション開始時、ユーザーに以下を提案する:

1. **通常パージ** (`devpurge -n`) — ユーザーキャッシュのスキャン
2. **システムパージ** (`sudo devpurge -n`) — 上記 + sleepimage, diagnostics, Adobe等
3. **開発作業** — Issue対応やコード改善

## アーキテクチャ

- `bin/devpurge` — エントリポイント
- `lib/paths.sh` — キャッシュターゲット定義 (tier: ai, dev, caution, system)
- `lib/scan.sh` — スキャンロジック
- `lib/cleanup.sh` — 削除ロジック
- `lib/report.sh` — レポート表示
- `lib/config.sh` — `~/.devpurgerc` 読み込み
- `lib/utils.sh` — ユーティリティ関数
- `test/run_tests.sh` — テストスイート

## 主要な設計

- `sudo devpurge` 時のみシステム関連の削除が有効になる (`DEVPURGE_IS_ROOT` フラグ)
- root実行時は `SUDO_USER` のHOMEを解決してからライブラリを読み込む
- ホワイトリスト方式で削除対象を制限
- sleepimage削除前に `pmset -a hibernatemode 0` を自動実行
