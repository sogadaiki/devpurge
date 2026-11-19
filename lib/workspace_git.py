"""Inspect local Git registrations without changing refs, indexes, or working files."""
import os
from pathlib import Path
import re
import stat
import subprocess

from studio import Studio
from workspace_folders import _directory, _stat, _pointer


class InventoryError(ValueError):
    pass


def _git(path, *args, allow=(0,)):
    # An invocation from a hook must not redirect this inventory to its own index/repo.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_OPTIONAL_LOCKS='0', GIT_NO_LAZY_FETCH='1', GIT_TERMINAL_PROMPT='0', LC_ALL='C')
    command = ['git', '--no-replace-objects', '-c', 'core.fsmonitor=false', '-C', str(path), *args]
    try:
        result = subprocess.run(command, env=env, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InventoryError('Git の状態を取得できませんでした。') from exc
    if result.returncode not in allow:
        raise InventoryError(f'Git の {args[0]} を確認できませんでした。')
    return result


def _value(path, *args):
    return os.fsdecode(_git(path, *args).stdout.removesuffix(b'\n'))


def _worktrees(repo):
    raw = _git(repo, 'worktree', 'list', '--porcelain', '-z').stdout
    if not raw.endswith(b'\0\0'):
        raise InventoryError('作業コピーの登録一覧を読み取れませんでした。')
    rows = []
    for block in raw[:-2].split(b'\0\0'):
        values = {}
        for field in block.split(b'\0'):
            key, _, val = field.partition(b' ')
            if key in values:
                raise InventoryError('作業コピーの登録項目が重複しています。')
            values[key] = os.fsdecode(val)
        path = values.get(b'worktree', '')
        ref = values.get(b'branch')
        if (not os.path.isabs(path) or (ref is not None and not ref.startswith('refs/heads/'))
                or (ref is None and b'detached' not in values and b'bare' not in values)):
            raise InventoryError('作業コピーの登録形式を確認できません。')
        rows.append({'path': path, 'branch': ref.removeprefix('refs/heads/') if ref else None,
                     'head': values.get(b'HEAD'), 'primary': path == str(repo),
                     'present': False, 'locked': b'locked' in values, 'prunable': b'prunable' in values,
                     'status': 'unknown'})
    if len({row['path'] for row in rows}) != len(rows) or rows[0]['path'] != str(repo):
        raise InventoryError('登録された主作業コピーと指定先が一致しません。')
    return rows


# Read only Git's cached stat fields. git status may run clean filters and hash a
# tracked .env when its timestamp changes. Unknown index formats fail closed.
_INDEX = re.compile(rb'(\d{6}) [0-9a-f]+ ([0-3])\t([^\0]+)\0'
                    rb'  ctime: (\d+):(\d+)\n  mtime: (\d+):(\d+)\n'
                    rb'  dev: \d+\tino: (\d+)\n  uid: \d+\tgid: \d+\n'
                    rb'  size: (\d+)\tflags: ([0-9a-f]+)\n')


def _private(path):
    return (not path.is_absolute() or '..' in path.parts
            or path.parts[1:2] in (('Volumes',), ('Network',), ('net',))
            or any(part.casefold() in {'sadame', 'cloudstorage', 'mobile documents', 'backups.backupdb',
                                       'credentials', 'secrets', 'private keys', 'keychains', '.ssh', '.aws',
                                       '.git', '.netrc', '.npmrc', '.pypirc', 'auth.json', 'credentials.json'}
                   or part.casefold().startswith(('.env', 'onedrive', 'dropbox', 'googledrive', 'google drive', 'icloud drive'))
                   for part in path.parts))


def _blocked(path, policy):
    return _private(path) or policy.blocked(path)


def _working_state(path, head, policy):
    staged = _git(path, 'diff-index', '--cached', '--quiet', '--no-ext-diff',
                  '--no-textconv', '--ignore-submodules=none', head, '--', allow=(0, 1))
    if staged.returncode:
        return 'dirty'
    if _git(path, 'ls-files', '--others', '--exclude-standard', '--directory',
            '--no-empty-directory', '-z').stdout:
        return 'dirty'
    data = _git(path, 'ls-files', '--stage', '--debug', '-z').stdout
    offset = 0
    state = 'clean'
    while offset < len(data):
        match = _INDEX.match(data, offset)
        if not match:
            return 'unknown'
        mode, stage, name, cs, cn, ms, mn, inode, size, flags = match.groups()
        offset = match.end()
        if stage != b'0':
            return 'dirty'
        # Sparse/assume-unchanged entries and submodule working trees require a separate audit.
        if int(flags, 16) or mode not in (b'100644', b'100755', b'120000'):
            state = 'unknown'
            continue
        components = name.split(b'/')
        if any(part in (b'', b'.', b'..') for part in components):
            return 'unknown'
        file = path / os.fsdecode(name)
        if _blocked(file, policy):
            state = 'unknown'
            continue
        try:
            current = file.lstat()
        except (FileNotFoundError, NotADirectoryError):
            return 'dirty'
        expected_type = stat.S_IFLNK if mode == b'120000' else stat.S_IFREG
        if (stat.S_IFMT(current.st_mode) != expected_type
                or (current.st_size & 0xffffffff) != int(size)):
            return 'dirty'
        # A touch, same-size edit or inode replacement cannot be distinguished by
        # metadata. The inventory does not open file contents to settle that case.
        if (current.st_ctime_ns != int(cs) * 10**9 + int(cn)
                or current.st_mtime_ns != int(ms) * 10**9 + int(mn)
                or (current.st_ino & 0xffffffff) != int(inode)
                or (mode != b'120000' and bool(current.st_mode & stat.S_IXUSR) != (mode == b'100755'))):
            state = 'unknown'
    return state


def _inspect(row, common, policy):
    path = Path(row['path'])
    if _blocked(path, policy):
        row['present'] = None
        return
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        row['status'] = 'missing'
        return
    row['present'] = True
    if not stat.S_ISDIR(mode) or row['prunable'] or not row['head']:
        return
    with _directory(path) as fd:
        if not row['primary']:
            pointer = _pointer(fd, '.git')
            if not pointer or not pointer.startswith('gitdir: '):
                return
            admin = Path(os.path.normpath(path / pointer[8:]))
            if admin.parent != Path(common) / 'worktrees' or _blocked(path / admin.name, policy):
                return
            with _directory(admin) as handle:
                backlink = _pointer(handle, 'gitdir')
                if not backlink or Path(os.path.normpath(admin / backlink)) != path / '.git':
                    return
                commondir = _pointer(handle, 'commondir')
                if not commondir or Path(os.path.normpath(admin / commondir)) != Path(common):
                    return
    if (_value(path, 'rev-parse', '--show-toplevel') != str(path)
            or _value(path, 'rev-parse', '--path-format=absolute', '--git-common-dir') != common
            or _value(path, 'rev-parse', '--verify', 'HEAD') != row['head']):
        return
    branch = _git(path, 'symbolic-ref', '--quiet', 'HEAD', allow=(0, 1)).stdout.removesuffix(b'\n')
    if branch != (os.fsencode('refs/heads/' + row['branch']) if row['branch'] else b''):
        return
    row['status'] = 'locked' if row['locked'] else _working_state(path, row['head'], policy)


def _retained(repo, warnings):
    default = Path.home() / 'Library/Application Support/devpurge/logs'
    folders = {default, Path(os.environ.get('DEVPURGE_LOG_DIR', default))}
    retained = set()
    try:
        for folder in folders:
            if not folder.is_absolute() or folder != folder.resolve():
                raise ValueError
            try:
                paths = list(folder.iterdir())
            except FileNotFoundError:
                continue
            for path in paths:
                if not path.match('removed-worktrees-*.tsv'):
                    continue
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
                with os.fdopen(fd, 'rb') as log:
                    s = os.fstat(fd)
                    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
                        raise ValueError
                    for line in log:
                        fields = line.removesuffix(b'\n').split(b'\t')
                        if len(fields) != 5 or not fields[0].isdigit() or not re.fullmatch(b'[a-fA-F0-9]{40}|[a-fA-F0-9]{64}', fields[-1]):
                            raise ValueError
                        if fields[1] == os.fsencode(repo):
                            retained.add(os.fsdecode(fields[3]))
    except (OSError, ValueError):
        warnings.append('復元ログを照合できないため、全ブランチを保護しています。')
        return None
    return retained


def inventory(repo: Path) -> dict:
    repo = Path(repo)
    if not repo.is_absolute():
        raise InventoryError('主作業コピーの絶対パスを指定してください。')
    policy = Studio()
    if _private(repo):
        raise InventoryError('保護・除外対象のため、主作業コピーを調査していません。')
    metadata_only = policy.blocked(repo)
    try:
        with _directory(repo) as fd:
            marker = _stat(fd, '.git')
            if marker is None or not stat.S_ISDIR(marker.st_mode):
                raise InventoryError('通常の主作業コピーを指定してください。')
    except (OSError, RuntimeError) as exc:
        raise InventoryError('主作業コピーがリンク・保持対象・到達不能のため調査していません。') from exc
    common = _value(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if common != str(repo / '.git') or _value(repo, 'rev-parse', '--show-toplevel') != str(repo):
        raise InventoryError('主作業コピーのルートを指定してください。')
    worktrees = _worktrees(repo)
    warnings = []
    if metadata_only:
        warnings.append('清掃対象外の案件です。Git の登録と参照のみを表示し、作業内容を調査せず全ブランチを保護します。')
    for row in worktrees:
        if metadata_only:
            row['present'] = True if row['primary'] else None
            continue
        try:
            _inspect(row, common, policy)
        except (OSError, RuntimeError, InventoryError):
            row['status'] = 'unknown'
        if row['status'] == 'unknown':
            warnings.append('作業状態を確定できません: ' + row['path'])

    # Branch names cannot contain LF. Use full ref names even when a tag shadows a branch.
    refs = {}
    for line in _git(repo, 'for-each-ref', '--format=%(refname)%00%(objectname)', 'refs/heads/').stdout.splitlines():
        name, sep, head = line.partition(b'\0')
        if not sep or not name.startswith(b'refs/heads/') or not re.fullmatch(rb'[0-9a-f]{40,64}', head):
            raise InventoryError('ローカルブランチの一覧を照合できません。')
        refs[os.fsdecode(name)] = os.fsdecode(head)
    remote = _git(repo, 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD', allow=(0, 1))
    origin = os.fsdecode(remote.stdout.removesuffix(b'\n')) if remote.returncode == 0 else None
    default = origin.removeprefix('refs/remotes/origin/') if origin else None
    candidates = (['refs/heads/' + default] if default else []) + ['refs/heads/main', 'refs/heads/master']
    base = next((ref for ref in candidates if ref in refs), None)
    merged = None
    shallow = True
    if base:
        try:
            targets = [refs[base]]
            if origin:
                if not origin.startswith('refs/remotes/origin/'):
                    raise InventoryError('キャッシュされた既定ブランチの参照先が不明です。')
                targets.append(_value(repo, 'rev-parse', '--verify', origin + '^{commit}'))
            merged = set(refs.values())
            for target in set(targets):
                merged &= {os.fsdecode(oid) for oid in _git(repo, 'for-each-ref', '--merged=' + target,
                           '--format=%(objectname)', 'refs/heads/').stdout.splitlines()}
            shallow = _value(repo, 'rev-parse', '--is-shallow-repository') != 'false'
            if shallow:
                warnings.append('履歴が浅いため、祖先関係のないブランチの統合状態は未確認です。')
        except InventoryError:
            merged = None
    if merged is None:
        warnings.append('既定ブランチへの統合状態を確定できません。')
    checked_out = {row['branch'] for row in worktrees}
    retained = _retained(repo, warnings)
    branches = []
    for ref, head in refs.items():
        name = ref.removeprefix('refs/heads/')
        included = None if merged is None else (True if head in merged else (None if shallow else False))
        branches.append({'name': name, 'head': head, 'checked_out': name in checked_out, 'merged': included,
                         'protected': metadata_only or ref == base or name in ('main', 'master', 'develop', default)
                         or retained is None or name in retained})
    return {'repo': str(repo), 'base': base, 'metadata_only': metadata_only,
            'worktrees': worktrees, 'branches': branches, 'warnings': warnings}
