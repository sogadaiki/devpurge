#!/usr/bin/env python3
"""Report on the selected projects' Git worktrees, branches and working folders."""

import argparse
from datetime import datetime
import html
import json
import os
from pathlib import Path
import sys
import tempfile

from workspace_folders import discover
from workspace_git import inventory


def project_path(value):
    path = Path(value).expanduser()
    if not path.is_absolute() and len(path.parts) == 1 and not path.exists():
        path = Path.home() / 'Desktop/development' / path
    return path.absolute()


def tracked_projects():
    rc = Path.home() / '.devpurgerc'
    if rc.is_symlink():
        raise ValueError('設定ファイルがリンクのため、登録案件を読み込めません。')
    try:
        lines = rc.read_text().splitlines()
    except FileNotFoundError:
        return []
    paths = []
    for line in lines:
        if line.startswith('workspace_project='):
            path = Path(line.partition('=')[2]).expanduser()
            if not path.is_absolute():
                raise ValueError('workspace_project には本体リポジトリの絶対パスを指定してください。')
            if path not in paths:
                paths.append(path)
    return paths


def branch_group(row):
    if row['checked_out']:
        return 'チェックアウト中'
    if row['protected']:
        return '主要・復元用などの保護対象'
    if row['merged'] is True:
        return '統合済み・未チェックアウトの整理候補'
    if row['merged'] is False:
        return '統合を確認できていないブランチ'
    return '判定できなかったブランチ'


def collect(paths):
    projects, errors = [], []
    for path in dict.fromkeys(paths):
        try:
            project = inventory(path)
            by_name = {b['name']: b for b in project['branches']}
            base_name = (project['base'] or '').removeprefix('refs/heads/')
            for row in project['worktrees']:
                branch = by_name.get(row['branch'])
                path = Path(row['path'])
                quarantine = Path.home() / 'Library/Application Support/devpurge/quarantine'
                if quarantine in path.parents:
                    row['location'] = 'quarantine'
                elif Path.home() / '.Trash' in path.parents:
                    row['location'] = 'trash'
                else:
                    row['location'] = 'workspace'
                row['review_for_retirement'] = bool(
                    not row['primary'] and row['present'] and not row['locked'] and not row['prunable']
                    and row['location'] == 'workspace'
                    and row['status'] == 'clean' and branch and branch['merged'] is True
                    and row['branch'] not in (base_name, 'main', 'master', 'develop'))
            projects.append(project)
        except (ValueError, OSError) as error:
            errors.append(f'{path} — {error}')
    registered = {Path(row['path']) for project in projects for row in project['worktrees']}
    locations = discover([Path(project['repo']) for project in projects], registered) if projects else {'folders': [], 'warnings': []}
    return {'time': datetime.now().astimezone().isoformat(timespec='seconds'),
            'projects': projects, 'folders': locations['folders'],
            'warnings': errors + locations['warnings'], 'failed_projects': len(errors)}


def worktree_lines(project):
    labels = {'clean': '変更なし', 'dirty': '変更あり', 'unknown': '要確認',
              'missing': '所在を確認できず', 'locked': 'ロック中'}
    for row in project['worktrees']:
        state = labels.get(row['status'], row['status'])
        tags = [state]
        if row['primary']:
            tags.append('本体')
        if row['location'] == 'quarantine':
            tags.append('隔離済み')
        elif row['location'] == 'trash':
            tags.append('ゴミ箱内')
        if row['locked'] and state != 'ロック中':
            tags.append('ロック中')
        if row['prunable']:
            tags.append('Gitの登録整理候補')
        if row['review_for_retirement']:
            tags.append('統合済み・使用状況の確認候補')
        yield f"{'・'.join(tags)}  {row['branch'] or '(detached HEAD)'}  {row['path']}"


def groups(report):
    for project in report['projects']:
        branches = project['branches']
        folders = [row for row in report['folders'] if row['project'] == project['repo']]
        extra = sum(not row['primary'] for row in project['worktrees'])
        candidates = [b for b in branches if branch_group(b) == '統合済み・未チェックアウトの整理候補']
        folder_summary = '登録外フォルダは調査対象外' if project.get('metadata_only') else f'発見した登録外フォルダ {len(folders)} 件'
        summary = (f"追加作業コピー {extra} 件 ／ ローカルブランチ {len(branches)} 本"
                   f" ／ 統合済みブランチ候補 {len(candidates)} 本 ／ {folder_summary}")
        sections = [('登録作業コピー（本体を含む）', list(worktree_lines(project)))]
        pending = [r['path'] for r in project['worktrees'] if r['review_for_retirement']]
        if pending:
            sections.insert(0, ('作業完了・使用状況を確認するコピー', pending))
        by_group = {}
        for branch in branches:
            label = branch_group(branch)
            value = branch['name']
            if label == '統合済み・未チェックアウトの整理候補':
                value += '  ' + branch['head']
            by_group.setdefault(label, []).append(value)
        for label in ('統合済み・未チェックアウトの整理候補', '統合を確認できていないブランチ',
                      '主要・復元用などの保護対象', 'チェックアウト中', '判定できなかったブランチ'):
            if label in by_group:
                sections.append((label, by_group[label]))
        if folders:
            sections.append(('登録外フォルダの所在', folder_lines(folders)))
        if project['warnings']:
            sections.append(('確認範囲に関する注意', project['warnings']))
        yield project['repo'], summary, sections


def folder_lines(rows):
    return [f"{r['path']}  [{r['kind']}]  {r['reason']}" for r in rows]


def visible(value):
    return ''.join(c if c.isprintable() else ascii(c)[1:-1] for c in str(value))


def present(report, as_html=False, details=False):
    title = '案件別の作業コピーとブランチ'
    guide = ('作業コピーはディスク上のフォルダ、ブランチはコミットへの参照です。'
             'ブランチ数から解放容量は算出できません。「変更なし」でも、作業中のプロセスや無視ファイルがあり得ます。'
             '統合判定には手元に記録されたGit履歴を使います。')
    parts = []
    def add(tag, text):
        text = visible(text)
        parts.append(f'<{tag}>{html.escape(text)}</{tag}>' if as_html else text)

    def section(label, lines):
        if as_html:
            parts.append('<details><summary>' + html.escape(f'{label}（{len(lines)}）') + '</summary><ul>')
            for line in lines:
                add('li', line)
            parts.append('</ul></details>')
        elif details:
            add('h3', f'  {label}（{len(lines)}）')
            for line in lines:
                add('li', '    ' + line)

    if as_html:
        parts.append('''<!doctype html><html lang="ja"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>案件別の作業コピーとブランチ</title>
<style>
:root{color-scheme:light dark;font:16px/1.6 system-ui,sans-serif}
body{max-width:64rem;margin:2rem auto;padding:0 1.25rem}
h1{font-size:1.6rem} h2{margin:2rem 0 .3rem;font-size:1.2rem}
p{margin:.45rem 0} summary{cursor:pointer;padding:.4rem 0}
li,h2,p{overflow-wrap:anywhere} ul{padding-left:1.4rem} li{margin:.3rem 0}
</style><body><main>''')
    add('h1', title)
    add('p', report['time'])
    add('p', guide)
    for repo, summary, sections in groups(report):
        add('h2', repo)
        add('p', summary)
        for name, lines in sections:
            if name == '確認範囲に関する注意' and not as_html and not details:
                add('p', f'  状態を確定できない項目があります（注意 {len(lines)} 件、詳細は --details）。')
            else:
                section(name, lines)
    other = [r for r in report['folders'] if r['project'] is None]
    if other:
        add('h2', '共有の作業場所・所属案件未確認')
        folder_labels = {'other-worktree': '別案件・別形式のGit参照', 'independent-repo': '独立したリポジトリ',
                         'rollback': '退避名のフォルダ', 'copy': 'コピー名のフォルダ', 'folder': '通常のフォルダ',
                         'unknown': '判定保留', 'unlisted-worktree': '登録を確認できない作業コピー'}
        for kind in sorted({row['kind'] for row in other}):
            items = [r for r in other if r['kind'] == kind]
            title = folder_labels.get(kind, kind)
            if not as_html and not details:
                add('p', f'  {title} {len(items)} 件')
            section(title, folder_lines(items))
    for warning in report['warnings']:
        add('p', f'確認範囲に関する注意  {warning}')
    if not as_html and not details:
        add('p', '個別のパスとブランチ名は --details で表示できます。')
    if as_html:
        parts.append('</main></body></html>')
    return '\n'.join(parts)


def save_report(folder, report):
    # The weekly job replaces just one private file, leaving the last complete report on failure.
    folder = Path(folder).resolve(strict=True)
    if not folder.is_dir() or folder.stat().st_uid != os.getuid():
        raise ValueError('本人が所有するレポート保存フォルダを指定してください。')
    output = folder / 'workspaces.html'
    html_text = present(report, as_html=True)
    fd, temp_name = tempfile.mkstemp(dir=folder, prefix='.workspaces-')
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(html_text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, output)
    finally:
        temp.unlink(missing_ok=True)
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('projects', nargs='*', metavar='REPO', help='primary checkout path or project in ~/Desktop/development (default: configured projects, otherwise current directory)')
    fmt = parser.add_mutually_exclusive_group()
    fmt.add_argument('--json', action='store_true', help='print the full inventory as JSON')
    fmt.add_argument('--html', action='store_true', help='print a self-contained local HTML report')
    fmt.add_argument('--details', action='store_true', help='include individual paths and branches in text')
    fmt.add_argument('--refresh-report', type=Path, metavar='DIR', help='refresh a private workspaces.html in DIR (with no REPO, use workspace_project entries)')
    action = parser.add_mutually_exclusive_group()
    action.add_argument('--retire', type=Path, metavar='WORKTREE', help='retire one eligible, completed linked worktree and retain its branch')
    action.add_argument('--check-worktree', type=Path, metavar='WORKTREE',
                        help='check one linked worktree for retirement without changing it')
    action.add_argument('--retire-branch', nargs=2, metavar=('BRANCH', 'EXPECTED_SHA'),
                        help='retire one integrated local branch at the reviewed commit')
    action.add_argument('--compare', nargs=2, type=Path, metavar=('COPY', 'KEEPER'),
                        help='compare file contents at matching paths; read-only')
    args = parser.parse_args(argv)
    if args.compare:
        if args.projects or args.html or args.details or args.refresh_report:
            parser.error('--compare accepts two paths and optionally --json')
        from workspace_compare import compare
        result = compare(*(p.expanduser().absolute() for p in args.compare))
        if args.json:
            print(json.dumps(result, ensure_ascii=True, indent=2))
        else:
            print(visible(result['status']), f"内容一致 {result['matched_files']} ファイル、{result['matched_bytes']} バイト")
            for row in result['differences'] + result['warnings']:
                print(visible(row))
        return {'match': 0, 'different': 1, 'incomplete': 2}[result['status']]
    paths = [project_path(arg) for arg in args.projects]
    if args.retire is not None or args.check_worktree is not None or args.retire_branch:
        if len(paths) != 1 or args.details or args.html or args.refresh_report:
            parser.error('retirement requires one project and supports text or --json')
        try:
            if args.retire_branch:
                from workspace_branch import retire_branch
                result = retire_branch(paths[0], *args.retire_branch)
            else:
                from workspace_retire import retire
                target = args.check_worktree or args.retire
                result = retire(paths[0], target.expanduser().absolute(), check_only=args.check_worktree is not None)
        except (ValueError, OSError) as error:
            result = {'status': 'held', 'reason': str(error)}
        if args.json:
            print(json.dumps(result, ensure_ascii=True))
        else:
            print(visible(result['status']), visible(result['reason']))
            if result.get('restore_command'):
                print(visible(result['restore_command']))
        return 0 if result['status'] in ('retired', 'eligible') else 1
    if not paths:
        try:
            paths = tracked_projects()
        except (OSError, ValueError) as error:
            parser.error(str(error))
        if not paths and args.refresh_report:
            return 0
    result = collect(paths or [Path.cwd()])
    if args.refresh_report:
        if result['failed_projects']:
            print('\n'.join(visible(w) for w in result['warnings']), file=sys.stderr)
            return 1
        try:
            print(visible(save_report(args.refresh_report, result)))
        except (OSError, ValueError) as error:
            parser.error(str(error))
        return 0
    print(json.dumps(result, ensure_ascii=True, indent=2) if args.json
          else present(result, as_html=args.html, details=args.details))
    return 1 if result['failed_projects'] else 0


if __name__ == '__main__':
    sys.exit(main())
