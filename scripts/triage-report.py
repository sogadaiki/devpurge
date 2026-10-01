#!/usr/bin/env python3
"""Render a read-only weekly summary when AI analysis is unavailable."""
import json
import re
import sys
import time
from pathlib import Path


def render(work_dir, now=None):
    now = time.time() if now is None else now
    root = Path(work_dir)
    items = json.loads((root / "scan.json").read_text())["items"]
    removed = []
    for line in (root / "removed-worktrees.tsv").read_text().splitlines():
        fields = line.split("\t")
        if len(fields) == 6 and fields[5] in ("removed", "trashed"):
            if now - 7 * 86400 <= int(fields[0]) <= now:
                removed.append(fields)

    def short(path):
        value = str(path).replace(str(Path.home()) + "/", "~/")
        value = re.sub(r"[\x00-\x1f`*]", "", value).replace("@", "＠")
        return value if len(value) <= 76 else "…" + value[-75:]

    def size(rows):
        return f'{sum(row["bytes"] for row in rows) / 1024**3:.1f} GiB'

    def top(rows):
        return [f'- {row["bytes"] / 1024**3:.1f} GiB `{short(row["path"])}`'
                for row in sorted(rows, key=lambda x: x["bytes"], reverse=True)[:3]]

    deletable = [x for x in items if x.get("deletable") is True]
    copies = [x for x in items if x.get("tier") == "review" and
              x.get("description", "").startswith(("identical copy of:", "older version"))]
    review = [x for x in items if x.get("tier") == "review" and
              (x.get("description", "").startswith("worktree:") or
               "backup" in x.get("description", "").lower())]
    lines = ["AI分析が利用できないため、スキャン結果を定型集計しています。",
             f"**worktree整理の結果** 直近7日の確認済み成功 {len(removed)}件"]
    lines += [f'- `{short(row[2])}`' for row in removed[:3]]
    if removed:
        lines += ["復元: `git -C <repo> worktree add <path> <branch>`（詳細は復元ログ）"]
    lines += [f"**自動整理候補** {len(deletable)}件・{size(deletable)}"] + top(deletable)
    lines += [f"**重複・旧バージョン** 表示候補 {len(copies)}件・{size(copies)}"] + top(copies)
    lines += ["検出上限あり。同一ファイルが両欄に出る場合もあり、合計は実際の解放容量ではありません。"]
    lines += [f"**AI判定待ち** worktree・バックアップ {len(review)}件"] + top(review)

    quarantine = re.sub(r"\x1b\[[0-9;]*m", "", (root / "quarantine.txt").read_text())
    expiry = re.search(r"expires after (\d+) days", quarantine)
    urgent = []
    for line in quarantine.splitlines():
        match = re.match(r"\s*(Q\d+)\s+\S+\s+(\d+)d\s+(held|EXPIRED)\b", line)
        if match and (match[3] == "EXPIRED" or (expiry and int(expiry[1]) - int(match[2]) <= 7)):
            urgent.append(match[1])
    if urgent:
        deadline = "期限切れ・7日以内: " + ", ".join(urgent[:10])
    elif "Quarantine is empty." in quarantine:
        deadline = "隔離なし"
    elif "stored copy missing" in quarantine or not expiry:
        deadline = "状態の確認が必要（quarantine.txt参照）"
    else:
        deadline = "期限切れ・7日以内の項目なし"
    lines += ["**隔離の期限** " + deadline,
              "**推奨** /devpurge-triage で候補を確認。一般ファイルの隔離は承認後のみ。",
              "このレポート処理は削除・隔離を実行しません。"]
    return "\n".join(lines)[:1800]


if __name__ == "__main__":
    print(render(sys.argv[1]))
