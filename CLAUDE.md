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
- `lib/worktree.sh` — stale git worktree検出（merged/squash-merged/未マージだがorigin退避済み + clean + idle + 一点物なし→削除可、それ以外→review報告のみ。squashはgit cherryのpatch同値で判定。削除前に復元用TSVをApp Support/devpurge/logs/へ）
- `lib/branches.sh` — マージ済みブランチ削除（git branch -dのみ、SHA復元ログをApp Support/devpurge/logs/へ）
- `lib/quarantine.sh` — 隔離（mv+manifest、30日猶予、restore可）+ 保護パターン（証拠/裁判/訴訟等は絶対不可侵。rc protect=で追加）
- `lib/dupes.sh` — 内容同一ファイル検出（SHA-256、名前不問、先頭末尾1MBの予備指紋で全ハッシュを最小化）+ 明示的バージョン違い検出（-v2/_final/(1)/ 2/のコピー。素の_1/_2は分割・連番なので対象外）+ Spotlight未使用日レポート
- `lib/cleanup.sh` — 削除（ホワイトリスト + rm guard + review拒否 + worktreeはgit経由 + --trash対応）
- `lib/report.sh` — レポート表示 + `--json` 出力
- `lib/discover.sh` — `--discover`（$HOME大物一覧、読み取り専用）
- `lib/config.sh` — ~/.devpurgerc（exclude= プレフィックス除外、worktree_age_days=）
- `lib/utils.sh` — ユーティリティ（色、サイズ変換、バージョン、PATH正規化）
- `scripts/triage-weekly.sh` / `triage-report.py` — 週次レポート。AI認証・上限・応答失敗時は明示した定型集計へfallback。DRY=1は通知を送らずreport.md保存まで
- `test/run_tests.sh` — テストスイート（実ディスクスキャンはDEVPURGE_SKIP_*で全て無効化）

## Key Design Decisions

- **スキャン結果は7フィールド**: `ID|PATH|TIER|DESC|SIZE_HUMAN|SIZE_BYTES|META`（METAはworktreeの `remove:<repo>` / `prune:<repo>`）
- **review tierは構造的に削除不可**（cleanup冒頭でtier判定して拒否。Downloads・セッション履歴・未push/dirty/一点物ありworktree等）
- **worktreeはrm -rf禁止**。`git worktree remove`（--force無し）のみ。dirty/lockedはgitが拒否する
- **無人実行(-y)ではworktree削除をスキップ**（gitignoreされた.env等はclean判定に出ないため）。rc `worktree_auto=1` か env `DEVPURGE_WORKTREE_AUTO=1` でopt-in。`.env*`を含むworktree、再生成不能なignoredファイルを持つworktree、未マージかつ未push/detachedのworktreeはreview行き。削除直前にも再判定する。7日はHEADコミット日時で判定し、origin退避判定はローカルremote-tracking refを使用
- **再生成可能物**: `.open-next`、`.godot`、`*.tsbuildinfo`、`next-env.d.ts`、`.refresh.lock` を含む。ignored一覧取得失敗はreview。worktree間の旧版重複は同じGit common-dir・相対パス・内容の場合だけ集約
- **worktreeログは試行と成功を区別**: 削除前の `removed-worktrees-*.tsv` は復元用、結果の `worktree-removal-results-*.tsv` は週次成功集計用
- **worktree復元ログに記録されたブランチはブランチ自動整理からも保護**（同じ実行内・次回以降とも保持）
- **定期ジョブのログは `~/Library/Application Support/devpurge/logs/`**。`~/Library/Logs` はD22で自分自身が消すため置かない
- **削除前に物理パス再検証**（`devpurge_resolve_physical`）。親ディレクトリのシンボリックリンク経由でホワイトリスト外へ抜ける攻撃を遮断
- **サイズ計測は `du -sk`**（`du -sh`の丸め→bc変換は廃止）。`_dp_size_kb` は `|| true` 必須（set -e + pipefail下でduの部分的permission errorが即死を招く）
- `sudo devpurge` 時のみ system tier が有効化される（`DEVPURGE_IS_ROOT` フラグ）
- root実行時は `SUDO_USER` のHOMEを解決してからライブラリを読み込む（パス展開順序が重要）
- ホワイトリスト方式で削除対象を制限。system tier用の別ホワイトリストあり
- sleepimage削除前に `pmset -a hibernatemode 0` を自動実行
- **このMacはlaunchdで月・木09:00に `devpurge -y` を実行**（旧crontabから移行済み、週次triageは日08:30）→ defaultモードのターゲットは無人実行で安全であること。自動再DLされる項目（ChromeオンデバイスAIモデル、壁紙動画、AIモデル類）はcaution tierに置く（チャーン防止）
- bash 3.2互換必須（macOS標準）。連想配列・mapfile禁止。空配列は `"${arr[@]+"${arr[@]}"}"` で展開
