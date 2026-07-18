# devpurge

macOS向けキャッシュ削除CLIツール。

## Session Start

セッション開始時、ユーザーに以下を提案する:

1. **通常パージ** (`devpurge -n`) — ユーザーキャッシュのスキャン
2. **システムパージ** (`sudo devpurge -n`) — 上記 + sleepimage, diagnostics, Adobe等
3. **開発作業** — Issue対応やコード改善

ユーザーが選択したらそのまま実行する。

## Architecture

- `bin/devpurge` — エントリポイント（フラグ解析、フェーズ制御）
- `lib/paths.sh` — ターゲット定義（tier: ai / dev / caution / system + review + ホワイトリスト）
- `lib/scan.sh` — スキャン（静的 + node_modules/.next動的 + misc/Electron/Containerキャッシュ自動検出 + review）
- `lib/worktree.sh` — stale git worktree検出（merged/squash-merged+clean+idle→削除可、それ以外→review報告のみ。squashはgit cherryのpatch同値で判定）
- `lib/branches.sh` — マージ済みブランチ削除（git branch -dのみ、SHA復元ログをApp Support/devpurge/logs/へ）
- `lib/quarantine.sh` — 隔離（mv+manifest、30日猶予、restore可）+ 保護パターン（証拠/裁判/訴訟等は絶対不可侵。rc protect=で追加）
- `lib/dupes.sh` — 同名同サイズ複製検出（NFC正規化・worktree同一ファイル除外）+ Spotlight未使用日レポート
- `lib/cleanup.sh` — 削除（ホワイトリスト + rm guard + review拒否 + worktreeはgit経由 + --trash対応）
- `lib/report.sh` — レポート表示 + `--json` 出力
- `lib/discover.sh` — `--discover`（$HOME大物一覧、読み取り専用）
- `lib/config.sh` — ~/.devpurgerc（exclude= プレフィックス除外、worktree_age_days=）
- `lib/utils.sh` — ユーティリティ（色、サイズ変換、バージョン、PATH正規化）
- `test/run_tests.sh` — テストスイート（実ディスクスキャンはDEVPURGE_SKIP_*で全て無効化）

## Key Design Decisions

- **スキャン結果は7フィールド**: `ID|PATH|TIER|DESC|SIZE_HUMAN|SIZE_BYTES|META`（METAはworktreeの `remove:<repo>` / `prune:<repo>`）
- **review tierは構造的に削除不可**（cleanup冒頭でtier判定して拒否。Downloads・セッション履歴・未マージworktree等）
- **worktreeはrm -rf禁止**。`git worktree remove`（--force無し）のみ。dirty/lockedはgitが拒否する
- **無人実行(-y)ではworktree削除をスキップ**（gitignoreされた.env等はclean判定に出ないため）。rc `worktree_auto=1` か env `DEVPURGE_WORKTREE_AUTO=1` でopt-in。`.env*`を含むworktreeは常にreview行き
- **削除前に物理パス再検証**（`devpurge_resolve_physical`）。親ディレクトリのシンボリックリンク経由でホワイトリスト外へ抜ける攻撃を遮断
- **サイズ計測は `du -sk`**（`du -sh`の丸め→bc変換は廃止）。`_dp_size_kb` は `|| true` 必須（set -e + pipefail下でduの部分的permission errorが即死を招く）
- `sudo devpurge` 時のみ system tier が有効化される（`DEVPURGE_IS_ROOT` フラグ）
- root実行時は `SUDO_USER` のHOMEを解決してからライブラリを読み込む（パス展開順序が重要）
- ホワイトリスト方式で削除対象を制限。system tier用の別ホワイトリストあり
- sleepimage削除前に `pmset -a hibernatemode 0` を自動実行
- **crontabで3日毎に `devpurge -y` が自動実行される前提** → defaultモードのターゲットは無人実行で絶対安全であること。自動再DLされる項目（ChromeオンデバイスAIモデル、壁紙動画、AIモデル類）はcaution tierに置く（チャーン防止）
- bash 3.2互換必須（macOS標準）。連想配列・mapfile禁止。空配列は `"${arr[@]+"${arr[@]}"}"` で展開
