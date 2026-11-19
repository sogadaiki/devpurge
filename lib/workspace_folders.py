"""Read-only inventory of physical working folders outside supplied Git registrations.

Inspect the immediate children of a project's .worktrees and .claude/worktrees,
its parent's .worktrees, ~/.worktrees and ~/.codex/worktrees. A shared task
container can have one extra level of checkouts. At a project root only explicit
backup/copy names are candidates. This is not a whole-disk or content scan.
No Git command is run against a discovered folder. A gitfile is a pointer,
not evidence of disposability, registration in another repo, or a backup.
"""
import contextlib
import errno
import os
from pathlib import Path
import re
import stat
import time

from studio import Studio


_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
_READ = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
_DATALESS = 0x40000000  # Darwin SF_DATALESS; do not materialize placeholders.
_MAX_ENTRIES = 15000
_SCOPE_LIMIT = 2000
_SECONDS = 10
_BACKUP = re.compile(r'(?:^|[-_. (])(?:state-before|rollback|backup|バックアップ|退避)(?:$|[-_. )0-9])', re.I)
_COPY = re.compile(r'(?:^|[-_. (])(?:copy|コピー)(?:$|[-_. )0-9])', re.I)
_CLOUD = ('dropbox', 'onedrive', 'googledrive', 'google drive', 'icloud drive')


def _placeholder(s):
    return bool(getattr(s, 'st_flags', 0) & _DATALESS)


@contextlib.contextmanager
def _directory(path):
    """Pin each ancestor; a renamed/symlinked component cannot redirect a read."""
    fd = os.open('/', _DIR)
    try:
        for component in path.parts[1:]:
            new = os.open(component, _DIR, dir_fd=fd)
            os.close(fd)
            fd = new
            if _placeholder(os.fstat(fd)):
                raise OSError(errno.EACCES, 'cloud placeholder')
            if _stat(fd, '.devpurge-keep') is not None:
                raise OSError(errno.EACCES, 'retained directory')
        yield fd
    finally:
        os.close(fd)


def _stat(fd, name):
    try:
        return os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _pointer(fd, name):
    """Read only a small regular Git metadata file, without links or general file contents."""
    s = _stat(fd, name)
    if not s or not stat.S_ISREG(s.st_mode) or not 0 < s.st_size <= 4096 or s.st_nlink != 1 or _placeholder(s):
        return None
    handle = os.open(name, _READ, dir_fd=fd)
    try:
        before = os.fstat(handle)
        if not os.path.samestat(s, before) or before.st_size != s.st_size or before.st_nlink != 1 or _placeholder(before):
            return None
        data = os.read(handle, 4097)
        after = os.fstat(handle)
        if len(data) != before.st_size or after.st_ctime_ns != before.st_ctime_ns:
            return None
        line = data.rstrip(b'\r\n')
        if not line or any(c < 32 or c == 127 for c in line):
            return None
        return os.fsdecode(line)
    finally:
        os.close(handle)


def _classify(path, owner, admins, fd):
    """Return kind, project and evidence; never dereference an external gitfile target."""
    marker = _stat(fd, '.git')
    if marker is None:
        if _BACKUP.search(path.name):
            return 'rollback', owner, '退避を示す名前です。復元元や用途は未照合です。'
        if _COPY.search(path.name):
            return 'copy', owner, 'コピーを示す名前です。保持元と内容は未照合です。'
        return 'folder', owner, '作業領域にある通常フォルダです。由来・利用状況は未確認です。'
    if stat.S_ISDIR(marker.st_mode) and not _placeholder(marker):
        git = os.open('.git', _DIR, dir_fd=fd)
        try:
            head, objects = _stat(git, 'HEAD'), _stat(git, 'objects')
            if head and stat.S_ISREG(head.st_mode) and objects and stat.S_ISDIR(objects.st_mode):
                return 'independent-repo', None, '自身の .git/HEAD と objects を持ちます。他の案件との同一性は未確認です。'
        finally:
            os.close(git)
        return 'unknown', None, '.git ディレクトリの状態を判定できません。'
    value = _pointer(fd, '.git')
    if not value or not value.startswith('gitdir: ') or not value[8:].strip():
        return 'unknown', None, 'Gitの管理ファイルを安全に確認できません。'
    target = Path(os.path.normpath(path / value[8:]))
    repo = admins.get(target.parent)
    if repo is None:
        return 'other-worktree', None, '対象案件以外または別形式のGit参照です。登録状況は未照合です。'
    if target.name.startswith('.') or target.name.casefold() in ('secrets', 'credentials', 'keychains', 'private keys'):
        return 'unknown', None, 'Gitの参照先が保護対象のため確認していません。'
    try:
        with _directory(target) as admin:
            ref = _pointer(admin, 'gitdir')
    except FileNotFoundError:
        return 'unlisted-worktree', repo, '対象案件へのGit参照があり、対応する管理ディレクトリが見つかりません。'
    if not ref:
        return 'unknown', repo, '対象案件へのGit参照があります。管理側の参照を確認できません。'
    if Path(os.path.normpath(target / ref)) != path / '.git':
        return 'unlisted-worktree', repo, '管理側が指す場所が異なります。移動・複製の可能性があります。'
    return 'unlisted-worktree', repo, '管理側と相互参照があります。今回の登録一覧には含まれていません。'


def discover(repos: list[Path], registered: set[Path], registrations_by_repo=None) -> dict:
    """Inventory only the specified repositories and known worktree containers."""
    policy = Studio()
    home = policy.home
    rows = {}
    warnings = set()
    seen = 0
    deadline = time.monotonic() + _SECONDS

    def blocked(path):
        return (not path.is_absolute() or '..' in path.parts or policy.blocked(path) or
                path.parts[1:2] in (('Volumes',), ('Network',), ('net',)) or
                any(part.casefold() in ('cloudstorage', 'mobile documents', 'backups.backupdb',
                                        'keychains', 'credentials', 'secrets', 'private keys', 'sadame') or
                    part.casefold().startswith(_CLOUD) for part in path.parts))

    if registrations_by_repo is None:
        registrations_by_repo = {Path(repos[0]): registered} if len(repos) == 1 else {}
    repos = sorted({Path(p) for p in repos if not blocked(Path(p))})
    if not repos:
        return {'folders': [], 'warnings': ['参照可能な案件がありません。']}
    admins = {repo / '.git/worktrees': repo for repo in repos}
    registered = {Path(p) for p in registered} | set(repos)

    def visit(parent, callback, *, copies_only=False):
        nonlocal seen
        try:
            if blocked(parent):
                return
            with _directory(parent) as fd:
                if _stat(fd, '.devpurge-keep') is not None:
                    return
                with os.scandir(fd) as items:
                    for i, entry in enumerate(items):
                        if i >= _SCOPE_LIMIT or seen >= _MAX_ENTRIES or time.monotonic() >= deadline:
                            warnings.add('時間・件数の上限に達したため一部のみ確認しました。')
                            break
                        seen += 1
                        if entry.name.startswith('.') or (copies_only and not (_BACKUP.search(entry.name) or _COPY.search(entry.name))):
                            continue
                        path = parent / entry.name
                        if path in registered or blocked(path):
                            continue
                        try:
                            st = entry.stat(follow_symlinks=False)
                            if not stat.S_ISDIR(st.st_mode) or _placeholder(st):
                                continue
                            child = os.open(entry.name, _DIR, dir_fd=fd)
                            try:
                                if os.path.samestat(st, os.fstat(child)) and _stat(child, '.devpurge-keep') is None:
                                    callback(path, child)
                            finally:
                                os.close(child)
                        except OSError:
                            warnings.add(f'読み取り不能または状態変化のため一部未確認: {parent}')
        except FileNotFoundError:
            return
        except OSError:
            warnings.add(f'読み取り不能またはリンクのため一部未確認: {parent}')

    def record(path, fd, owner):
        try:
            kind, project, reason = _classify(path, owner, admins, fd)
        except OSError:
            kind, project, reason = 'unknown', None, 'Git情報・アクセス状況を確認できません。'
            warnings.add(f'一部未確認: {path}')
        rows[path] = {'path': str(path), 'project': str(project) if project else None,
                      'kind': kind, 'reason': reason}

    def retained(path, repo):
        rows[path] = {'path': str(path), 'project': str(repo), 'kind': 'retained',
                      'reason': '案件の保持用フォルダ内に保管されています。用途と保持元は個別に確認してください。'}

    # Only attribute sibling lane containers if their role is evidenced by a registration.
    attributed_scopes = set()
    for repo in repos:
        registered_parents = {p.parent for p in registrations_by_repo.get(repo, ()) if p != repo}
        for scope in (repo / '.worktrees', repo / '.claude/worktrees', repo):
            visit(scope, lambda p, f: record(p, f, repo), copies_only=scope == repo)
        visit(repo / 'build/retained-worktrees', lambda p, f: retained(p, repo))
        for scope in (repo.parent / (repo.name + '-lanes'), repo.parent / '.worktrees' / repo.name):
            if scope in registered_parents:
                attributed_scopes.add(scope)
                visit(scope, lambda p, f: record(p, f, repo))

    shared = {repo.parent / '.worktrees' for repo in repos} | {home / '.worktrees', home / '.codex/worktrees'}
    def shared_entry(path, fd):
        if path in rows or path in attributed_scopes:
            return
        if _stat(fd, '.git') is not None or _BACKUP.search(path.name) or _COPY.search(path.name):
            record(path, fd, None)
            return
        # A lane may be a container for real registered or separate repositories.
        has_children = any(p.parent == path for p in registered)
        def lane_entry(p, f):
            nonlocal has_children
            if path.parent == home / '.codex/worktrees' or _stat(f, '.git') is not None or _BACKUP.search(p.name) or _COPY.search(p.name):
                has_children = True
                record(p, f, None)
        visit(path, lane_entry)
        if not has_children:
            record(path, fd, None)

    for scope in sorted(shared):
        visit(scope, shared_entry)
    return {'folders': [rows[p] for p in sorted(rows)], 'warnings': sorted(warnings)}
