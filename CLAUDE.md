# devpurge

macOS向けキャッシュ削除CLIツール。

## Session Start

セッション開始時、ユーザーに以下を提案する:

1. **通常パージ** (`devpurge -n`) — ユーザーキャッシュのスキャン
2. **システムパージ** (`sudo devpurge -n`) — 上記 + sleepimage, diagnostics, Adobe等
3. **開発作業** — Issue対応やコード改善

ユーザーが選択したらそのまま実行する。

## Architecture

- `bin/devpurge` — エントリポイント
- `lib/paths.sh` — キャッシュターゲット定義（4 tier: ai, dev, caution, system）
- `lib/scan.sh` — スキャンロジック（静的ターゲット + node_modules動的検出 + misc cache検出）
- `lib/cleanup.sh` — 削除ロジック（ホワイトリスト検証 + system tier安全チェック）
- `lib/report.sh` — レポート表示
- `lib/config.sh` — ~/.devpurgerc 読み込み
- `lib/utils.sh` — ユーティリティ（色、サイズ変換、バージョン）
- `test/run_tests.sh` — テストスイート

## Key Design Decisions

- `sudo devpurge` 時のみ system tier が有効化される（`DEVPURGE_IS_ROOT` フラグ）
- root実行時は `SUDO_USER` のHOMEを解決してからライブラリを読み込む（パス展開順序が重要）
- ホワイトリスト方式で削除対象を制限。system tier用の別ホワイトリストあり
- sleepimage削除前に `pmset -a hibernatemode 0` を自動実行
