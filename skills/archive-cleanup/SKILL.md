---
name: archive-cleanup
description: devpurgeでMacの指定アーカイブを10日未使用ルールに従って整理する。アーカイブの容量整理、finish時のアーカイブ移動後の登録、保管データの再利用前の期限延長に使う。任意のarchiveフォルダや作業中データの削除には広げない。
---

# Archive Cleanup

本体とルールの正本は `/Users/daiki12/Desktop/development/devpurge`。仕様は同リポジトリの `docs/archive-retention.md`。CodexとClaudeは同じスキルを参照する。

このMacではユーザーが2026-10-10に `/Users/daiki12/Desktop/アーカイブ` に移して10日触っていないファイルの削除を承認済み。`~/.devpurgerc` の `archive_root`、`archive_days=10`、`archive_auto=1` が一致する運用では、期限切れ対象ごとの再承認は不要。通常の30日quarantineとは別の、明示承認済みarchive tierとして扱う。

## 目的に応じた操作

- 状態確認: `devpurge archive --dry-run`。結果の対象ルート、日数、候補数、保持理由を読む。このコマンドは台帳も変更しない。
- 既に権限内でアーカイブへ移動した後: `devpurge archive --track`。古いmtimeを移動日として扱わない。未登録の既存ファイルは初回登録から数える。
- 再利用前: `devpurge archive --touch "/Users/daiki12/Desktop/アーカイブ/<対象>"`。OSが全ての閲覧を記録する保証はないため、エージェントは読む・編集する前に期限を延ばす。
- 整理を依頼されたとき: dry-runの確認後、`devpurge archive --expire` を実行して結果を読む。承認済みのroot・日数・opt-inを自動で広げない。

finish時は、そのタスクが既に移動を許可されたデータを登録する。`finish-session` は作業途中なので、セッション終了だけを根拠に再開に必要なデータをアーカイブへ移さない。素材を移す場合は参照・再開経路を確認して既存の引き継ぎへ移動先を記録する。

## 処理境界

削除判断と実行はdevpurgeに任せる。独自の `find -mtime ... -delete`、mtimeの書き換え、台帳の過去日付化、アーカイブルートへの `rm -rf` は使わない。10日間の観測保管と未使用の両方を満たす必要がある。

証拠・契約書等の保護、`.env*`、Git作業コピー、除外指定、`.devpurge-keep`、リンク、使用中、調査エラーの対象は残す。通常のキャッシュ・quarantine・Time Machine・スケジュール設定をこの整理のついでに変更しない。

報告は、登録または削除した件数、保持理由、台帳/結果の保存先、必要なら実測空き容量の差に絞る。`bytes` は候補の割当サイズであり、空き容量の実測とは区別する。期限は満了後の次回devpurge実行で処理され、10日ちょうどの削除時刻は約束しない。
