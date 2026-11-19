# 作業コピーが増えたとき

作業中は、フォルダをもう一つ作る前に対象案件の一覧を開きます。作業の終了時は、使った作業コピー・残すブランチ・一時的に作ったファイルをこの一覧と照らし合わせます。

```sh
devpurge workspaces project-a project-b
devpurge workspaces project-a --details
devpurge workspaces project-a project-b --html > ~/workspace-report.html
devpurge workspaces project-a --json
```

案件には本体リポジトリのパスを指定できます。短い名前は現在のディレクトリ、次に `~/Desktop/development` の下で探します。案件を省略すると登録案件を、登録がなければ現在のディレクトリを照合します。HTMLは単一のローカルファイルで、外部通信はありません。表示時点のスナップショットで、同じコマンドを再実行すると更新できます。ブランチ名やローカルパスが含まれます。

繰り返し確認する案件は、`~/.devpurgerc` に1案件1行で `workspace_project=/absolute/path/to/primary-checkout` を登録します。既存の週次triageが動く環境では、`~/Library/Application Support/devpurge/logs/workspaces.html` を更新します。ファイル・ブランチの削除は実行しません。手元ですぐ更新するには `devpurge workspaces --refresh-report "$HOME/Library/Application Support/devpurge/logs"` を使います。

| 一覧 | 見るところ |
| --- | --- |
| 登録作業コピー | 本体を含むパス、ブランチ、変更、ロック、所在。件数の「追加」は本体を除きます。使用中の案件もここに含まれます。 |
| ブランチ | チェックアウト、主要・復元用の保護、既定ブランチへの統合状況。祖先関係で確認し、squashや別の実装で採用した変更は別途判断します。照会時のネットワークアクセスはありません。 |
| 登録外フォルダ | 案件の `.worktrees`・`.claude/worktrees`、本体直下のコピー・退避名、共有の作業場所の直下とタスク用サブフォルダを調べます。独立リポジトリ、別案件へのGit参照、普通のフォルダ、退避を区別します。共有場所で所有案件を特定できないものは別枠に出ます。 |

### コピーしたファイルを確かめる

```sh
devpurge workspaces --compare "/path/to/作業コピー" "/path/to/保持する原本"
```

ファイル2個、またはフォルダ2個を指定します。コピー側から同じ相対パスの保持先を探して内容を比較します。保持先だけに追加されたファイルは許容します。一致・差分・確認できなかった範囲を区別します。内容の一致だけでは、作業中の参照や納品上の役割は判断できません。

### 終わった作業を1件ずつ整理する

作業担当者や引き継ぎ記録で完了を確認し、対象のパスまたはブランチを選びます。どちらの操作も既存の定期清掃とは独立しています。

```sh
devpurge workspaces /path/to/repo --check-worktree /path/to/linked-worktree
devpurge workspaces /path/to/repo --retire /path/to/linked-worktree
devpurge workspaces /path/to/repo --retire-branch branch-name FULL_COMMIT_SHA
```

`--check-worktree` で対象を1件検証すると、作業完了後に畳めるか、保持する根拠があるかを確認できます。作業コピーを閉じる操作は、統合済みの通常ブランチを保持し、作業ツリー・利用状況を再検証してからGitでフォルダを外します。変更、固有のファイル、利用中・最近の作業、保護対象などは保持し、理由を返します。ブランチ整理は一覧に出たフルSHAを指定します。チェックアウト中、復元に必要、SHAが変わった場合などは保持します。結果の復元コマンドと、既存形式のローカル復元記録から戻せます。Git登録外のフォルダは確認対象です。これらの整理コマンドには渡しません。

ブランチを外す際は、Gitが参照をロックしている時点でも指定したコミットを再確認します。この検証用フックの追加に対応していないGitは操作を保留します。復元用の参照は `refs/devpurge/retired-branches/` に残ります。

ブランチはコミットへの参照で、1本ずつプロジェクト全体をコピーするものではありません。フォルダの内容が一致していても、ハードリンクやAPFSの共有領域があるため、表示したファイルサイズを回収可能量に合算できません。
