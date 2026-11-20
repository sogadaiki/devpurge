#!/usr/bin/env python3
"""Maintain the project's portable data index. Only an explicit record writes metadata."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys
import time
import unicodedata

from studio import Studio
from workspace_compare import _blocked, compare
from workspace_folders import _READ, _directory, _placeholder, _stat


MANIFEST = '.devpurge-index.json'
RETAINED = Path('build/retained-worktrees')
KEEP = {'source': '原本として保持します。', 'deliverable': '納品・公開用として保持します。',
        'recovery': '復元・再編集に使う控えとして保持します。'}
ROLES = (*KEEP, 'temporary', 'copy', 'unknown')
FIELDS = {'path', 'role', 'owner', 'reason', 'keeper', 'rebuild', 'until'}
MAX_BYTES = 1024 * 1024
MAX_RECORDS = 1500
SCAN_LIMIT = 1000
# Names visible in a metadata-only index. The content verifier applies the stricter
# original rules to every component before it can open any file.
GENERATED = {'.next', '.open-next', '.godot', '.venv', '.render-bundle', '.render-tmp'}


def folded(path):
    return unicodedata.normalize('NFC', str(path)).casefold()


def portable(path):
    # A policy written on a case-sensitive disk must remain safe on an APFS default volume.
    return Path(folded(path))


def require(ok, message):
    if not ok:
        raise ValueError(message)


def clean_text(value, limit, optional=False):
    if value is None and optional:
        return None
    require(isinstance(value, str) and value.strip() and len(value) <= limit
            and not any(unicodedata.category(c) in ('Cc', 'Cs') for c in value),
            '入力は長さの上限内の1行で指定してください。')
    return value.strip()


def relative(value):
    require(clean_text(value, 2048) == value, '前後に空白のあるパスは指定できません。')
    parts = value.split('/')
    require(not any(p in ('', '.', '..') for p in parts) and len(parts) <= 64
            and not any(p.casefold().startswith(MANIFEST) for p in parts),
            '案件内の対象を相対パスで指定してください。')
    return Path(value)


def policy_for(root):
    home = Path.home()
    rc = home / '.devpurgerc'
    try:
        status = rc.lstat()
        require(stat.S_ISREG(status.st_mode) and not _placeholder(status) and os.access(rc, os.R_OK),
                '除外設定を読み取れません。')
    except FileNotFoundError:
        pass
    policy = Studio()
    require(root.is_absolute() and '..' not in root.parts and len(root.parts) > 2
            and root not in (home, home / 'Desktop', home / 'Documents', Path('/private/tmp'))
            and allowed(root, policy), 'この場所は索引の対象外です。個別の案件フォルダを指定してください。')
    # macOS's Data-volume mirror can spell the same project outside its configured
    # home-prefix exclusion. System directories are never development project roots.
    first = root.parts[1].casefold()
    require(first not in ('system', 'library', 'applications', 'usr', 'etc', 'bin', 'sbin', 'cores', 'dev')
            and not (first == 'private' and root.parts[2:3] != ('tmp',) and
                     root.parts[2:4] != ('var', 'folders')), 'システムの管理領域は索引の対象外です。')
    return policy


def allowed(path, policy):
    # Also honor policy aliases on the default case-insensitive macOS filesystem.
    value = folded(path)
    if any(value == folded(p) or value.startswith(folded(p).rstrip('/') + '/') for p in policy.excluded):
        return False
    if policy.blocked(path) or any(folded(term) in value for term in policy.protected):
        return False
    plain = Path(*(part.lstrip('.') if part in GENERATED else part for part in path.parts))
    return not _blocked(policy, plain)


def valid_entry(row):
    require(isinstance(row, dict) and set(row) <= FIELDS
            and {'path', 'role', 'owner', 'reason'} <= set(row), '索引の項目形式を確認できません。')
    path = relative(row['path'])
    require(row['role'] in ROLES, '索引の用途を確認できません。')
    for key in ('owner', 'reason', 'until', 'rebuild'):
        clean_text(row.get(key), 160 if key == 'owner' else 1024, optional=key in ('until', 'rebuild'))
    keeper = row.get('keeper')
    if keeper is not None:
        kept = portable(relative(keeper))
        src = portable(path)
        require(row['role'] == 'copy' and src != kept and src not in kept.parents and kept not in src.parents,
                'コピーと保存先には重ならない別々の場所を指定してください。')
    return {key: row.get(key) for key in sorted(FIELDS)}


def unique_keys(pairs):
    result = dict(pairs)
    require(len(result) == len(pairs), '索引に重複したキーがあります。')
    return result


def read_manifest(fd):
    info = _stat(fd, MANIFEST)
    if info is None:
        return {}, None
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and not _placeholder(info)
            and info.st_size <= MAX_BYTES, '索引がリンク・特殊形式・サイズ上限超過のため読み込めません。')
    with os.fdopen(os.open(MANIFEST, _READ, dir_fd=fd), 'rb') as stream:
        current = os.fstat(stream.fileno())
        require(os.path.samestat(info, current) and current.st_nlink == 1 and not _placeholder(current),
                '読み込み中に索引が変わりました。')
        data = stream.read(MAX_BYTES + 1)
        require(len(data) <= MAX_BYTES and len(data) == info.st_size and
                os.fstat(stream.fileno()).st_ctime_ns == info.st_ctime_ns, '読み込み中に索引が変わりました。')
    doc = json.loads(data.decode('utf-8'), object_pairs_hook=unique_keys)
    require(isinstance(doc, dict) and set(doc) == {'version', 'entries'} and type(doc['version']) is int
            and doc['version'] == 1 and isinstance(doc['entries'], list) and len(doc['entries']) <= MAX_RECORDS,
            'この索引の形式・バージョンまたは件数には対応していません。')
    entries = {}
    names = set()
    for item in doc['entries']:
        row = valid_entry(item)
        require(folded(row['path']) not in names, '索引に同じパスまたは別表記のパスが複数あります。')
        names.add(folded(row['path']))
        entries[row['path']] = row
    return entries, info


def revision(row):
    if row is None:
        return 'new'
    return hashlib.sha256(json.dumps(row, sort_keys=True, ensure_ascii=True).encode()).hexdigest()


def location(root, rel, policy):
    path = root / rel
    require(allowed(path, policy), '保護対象または除外された項目です。')
    with _directory(path.parent) as parent:
        info = _stat(parent, path.name)
        require(info is not None and not _placeholder(info) and
                (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)), '所在、権限または項目の種類を確認できません。')
        if stat.S_ISDIR(info.st_mode):
            with _directory(path):
                pass
    return path


def discover(root, fd, policy, registered, warnings):
    paths = set()
    registered_names = {folded(path) for path in registered}
    def scan(folder, handle):
        with os.scandir(handle) as children:
            for index, item in enumerate(children):
                if index >= SCAN_LIMIT:
                    warnings.append('直下の項目数が上限に達したため、一部の項目を省略しました。')
                    break
                rel = folder / item.name
                if folded(rel) in registered_names or (item.name.startswith('.') and item.name not in GENERATED):
                    continue
                try:
                    relative(str(rel))
                    location(root, rel, policy)
                    paths.add(str(rel))
                except (OSError, ValueError):
                    continue
    scan(Path('.'), fd)
    if allowed(root / RETAINED, policy):
        try:
            with _directory(root / RETAINED) as retained:
                scan(RETAINED, retained)
        except FileNotFoundError:
            pass
        except OSError:
            warnings.append('保管フォルダの一部は確認できません。')
    return paths


def protected_scopes(root, records, policy):
    kept = {portable(row['path']) for row in records.values() if row['role'] in KEEP}
    try:
        location(root, RETAINED, policy)
        kept.add(RETAINED)
    except (OSError, ValueError):
        pass
    containers = {parent for path in kept for parent in path.parents}
    return kept, containers


def overlaps_kept(path, scopes):
    kept, containers = scopes
    path = portable(path)
    return path in kept or path in containers or any(parent in kept for parent in path.parents)


def backup_inclusions(paths):
    """Current Time Machine policy for each item itself, never a backup receipt."""
    statuses = {}
    if sys.platform != 'darwin':
        return statuses
    # tmutil's text form distinguishes UNKNOWN from Included. Its -X form can
    # return IsExcluded=0 even when it cannot establish the item's status.
    paths = [p for p in paths if '\n' not in str(p) and '\r' not in str(p)]
    deadline = time.monotonic() + 5
    for start in range(0, len(paths), 64):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        batch = {os.fsencode(p): p for p in paths[start:start + 64]}
        try:
            response = subprocess.run(['/usr/bin/tmutil', 'isexcluded', *batch],
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                      timeout=remaining, check=False,
                                      env={**os.environ, 'LC_ALL': 'C'})
        except (OSError, subprocess.TimeoutExpired):
            break
        if response.returncode != 0:
            continue
        for line in response.stdout.split(b'\n'):
            tag, _, name = line.partition(b']')
            path = batch.get(name.lstrip(b' \t'))
            if path is not None and tag in (b'[Included', b'[Excluded'):
                statuses[path] = 'included' if tag == b'[Included' else 'excluded'
    return statuses


def report(root, fd, policy, records):
    warnings = []
    discovered = discover(root, fd, policy, records, warnings)
    protected = protected_scopes(root, records, policy)
    rows = []
    present = []
    for path in sorted(records.keys() | discovered):
        row = records.get(path)
        # Respect newly added exclusions even when a previous record contains notes.
        if not allowed(root / path, policy) or (row and row.get('keeper') and not allowed(root / row['keeper'], policy)):
            warnings.append('現在の保護・除外設定に該当する登録項目を非表示にしました。')
            continue
        decision, detail = 'review', '用途と作業後の扱いを記録してください。'
        if row:
            role = row['role']
            if role in KEEP:
                decision, detail = 'keep', KEEP[role]
            elif role == 'copy':
                decision, detail = 'review', '保存先と現在の内容を照合してください。'
            elif role == 'temporary':
                decision, detail = 'review', '再生成の手順・入力と利用終了を確認してください。'
        if overlaps_kept(path, protected) and decision != 'keep':
            decision, detail = 'keep', '原本・納品物・復元用データ・保管場所の保持範囲に重なるため保持します。'
        if row:
            try:
                present.append(location(root, Path(path), policy))
            except (OSError, ValueError):
                detail = '登録時の場所に実物を確認できません。移動・権限・リンクを確認してください。'
        else:
            present.append(root / path)  # discover() checked this entry's location.
        values = row or dict(path=path, role='unknown', owner='', reason='', keeper=None, until=None, rebuild=None)
        rows.append(dict(values, recorded=row is not None, revision=revision(row), decision=decision, detail=detail))
    return {'root': str(root), 'entries': rows, 'warnings': list(dict.fromkeys(warnings))}, present


def store(root, fd, records, old):
    require(len(records) <= MAX_RECORDS, '登録件数が上限に達しました。')
    blob = json.dumps({'version': 1, 'entries': [records[k] for k in sorted(records)]},
                      ensure_ascii=False, indent=2).encode('utf-8') + b'\n'
    require(len(blob) <= MAX_BYTES, '索引のサイズが上限に達しました。')
    tmp = MANIFEST + '.' + secrets.token_hex(12) + '.tmp'
    handle = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        with os.fdopen(handle, 'wb') as stream:
            stream.write(blob)
            stream.flush()
            os.fsync(stream.fileno())
        with _directory(root) as current:
            require(os.path.samestat(os.fstat(fd), os.fstat(current)), '保存中に案件の場所が変わりました。')
        latest = _stat(fd, MANIFEST)
        if old is None:
            require(latest is None, '保存中に索引が追加されました。')
        else:
            require(latest is not None and os.path.samestat(old, latest) and old.st_ctime_ns == latest.st_ctime_ns,
                    '保存中に索引が更新されました。再読込してください。')
        # The project's exclusive directory lock serializes creates and updates.
        # A single rename publishes a complete, readable index, even on interruption.
        os.replace(tmp, MANIFEST, src_dir_fd=fd, dst_dir_fd=fd)
    finally:
        if _stat(fd, tmp) is not None:
            os.unlink(tmp, dir_fd=fd)


def verification(root, records, row, policy):
    require(row and row['role'] == 'copy' and row['keeper'], '保存先を記録したコピーを指定してください。')
    copy = location(root, relative(row['path']), policy)
    keeper = location(root, relative(row['keeper']), policy)
    if overlaps_kept(row['path'], protected_scopes(root, records, policy)):
        return {'decision': 'keep', 'detail': '対象は原本・納品物・復元用データ・保管場所の保持範囲と重なるため保持します。'}
    result = compare(copy, keeper)
    if result['status'] != 'match':
        return {'decision': 'review', 'detail': '内容に差分があります。' if result['status'] == 'different'
                else '保護対象・アクセス・上限などのため照合を完了できませんでした。'}
    explanation = f"保存先と内容一致 {result['matched_files']} ファイル。"
    if result['matched_files'] == 0:
        return {'decision': 'review', 'detail': '両方の配置を照合しましたが、内容一致を確認したファイルは0件です。'}
    if row['until']:
        return {'decision': 'review', 'detail': explanation + '記録した見直し条件の成立を確認してください。'}
    def overlaps(a, b):
        return a == b or a in b.parents or b in a.parents
    for other in records.values():
        if other['role'] in ('temporary', 'copy') and overlaps(portable(row['keeper']), portable(other['path'])):
            return {'decision': 'review', 'detail': explanation + '保存先にも一時生成物・コピーの指定があります。'}
    return {'decision': 'candidate', 'detail': explanation + '作業完了、利用中の参照、保存先の保持を確認してから整理を判断してください。'}


def execute(args):
    if args.action == 'projects':
        from workspaces import tracked_projects
        return {'projects': [str(path) for path in tracked_projects()]}
    root = Path(args.root).expanduser().absolute()
    policy = policy_for(root)
    with _directory(root) as fd:
        # Readers and writers share the project-directory inode; no lockfile is left in Git.
        fcntl.flock(fd, fcntl.LOCK_EX if args.action == 'record' else fcntl.LOCK_SH)
        records, old = read_manifest(fd)
        if args.action == 'verify':
            key = str(relative(args.path))
            row = records.get(key)
            require(args.expected is None or args.expected == revision(row),
                    'この項目が更新されました。一覧を再読込してください。')
            result = verification(root, records, row, policy)
            current, _ = read_manifest(fd)
            require(current == records, '照合中に索引が変わりました。一覧を再読込してください。')
            return result
        if args.action == 'record':
            values = valid_entry({key: getattr(args, key) for key in FIELDS})
            path = values['path']
            require(not any(folded(key) == folded(path) and key != path for key in records),
                    '同一とみなす別表記の項目があります。一覧に表示されたパスを使用してください。')
            location(root, relative(path), policy)
            if values['keeper']:
                location(root, relative(values['keeper']), policy)
            require(args.expected == revision(records.get(path)), 'この項目は更新されています。一覧を再読込して確認してください。')
            records[path] = values
        result, present = report(root, fd, policy, records)
        if args.action == 'record':
            store(root, fd, records, old)
    # No network or OS service lookup while holding the project's metadata lock.
    inclusions = backup_inclusions(present)
    for row in result['entries']:
        row['backup_inclusion'] = inclusions.get(root / row['path'], 'unknown')
    return result


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError('引数を確認してください。各操作で --help を使えます。')


def main(argv=None):
    parser = Arguments(description='案件データの用途・担当・保持条件を記録します。')
    actions = parser.add_subparsers(dest='action', required=True)
    actions.add_parser('projects').add_argument('--json', action='store_true')
    for name in ('list', 'record', 'verify'):
        sub = actions.add_parser(name)
        sub.add_argument('root')
        sub.add_argument('--json', action='store_true')
        if name != 'list':
            sub.add_argument('--path', required=True)
            sub.add_argument('--expected', default='new' if name == 'record' else None)
        if name == 'record':
            sub.add_argument('--role', choices=ROLES, required=True)
            sub.add_argument('--owner', required=True)
            sub.add_argument('--reason', required=True)
            sub.add_argument('--keeper')
            sub.add_argument('--rebuild')
            sub.add_argument('--until')
    argv = sys.argv[1:] if argv is None else argv
    try:
        args = parser.parse_args(argv)
        result = execute(args)
    except (ValueError, OSError, RecursionError) as exc:
        message = str(exc) if isinstance(exc, ValueError) else '所在・権限・保護設定または索引の形式を確認してください。'
        print(json.dumps({'error': message}) if '--json' in argv else message)
        return 1
    if args.json:
        print(json.dumps(result))
    elif args.action == 'verify':
        print(result['detail'])
    elif args.action == 'projects':
        print('\n'.join(result['projects']))
    else:
        for row in result['entries']:
            print(row['path'], row['role'], row['decision'], row['reason'] or row['detail'], sep='\t')
        for warning in result['warnings']:
            print(warning)
    return 0


if __name__ == '__main__':
    sys.exit(main())
