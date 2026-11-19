"""Compare an explicit copy against a keeper using relative paths and regular-file contents.

Only enumerate the copy. Extra keeper entries are deliberately outside the comparison.
No Git command, link traversal, deletion, recovery decision or free-space estimate.
"""
import contextlib
import hashlib
import os
from pathlib import Path
import stat
import time

from studio import Studio
from workspace_folders import _CLOUD, _DIR, _READ, _directory, _placeholder, _stat


_BYTES = 16 << 30
_ENTRIES = 30000
_SECONDS = 60
_EXAMPLES = 50
_SCOPE = ('コピー側の相対配置と通常ファイルの内容（SHA-256）を確認します。'
          '保持先だけにある追加項目は対象外です。属性・利用中の参照・削除可否は判定しません。')


def _version(s):
    return (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def _blocked(policy, path):
    if policy.blocked(path) or '..' in path.parts or path.parts[1:2] in (('Volumes',), ('Network',), ('net',)):
        return True
    for i, part in enumerate(path.parts):
        name = part.casefold()
        if name.startswith('.'):
            if name in ('.worktrees', '.gitignore', '.gitattributes', '.editorconfig', '.ds_store'):
                continue
            if name in ('.codex', '.claude') and path.parts[i + 1:i + 2] == ('worktrees',):
                continue
            return True
        if (name.startswith(_CLOUD) or name in ('cloudstorage', 'mobile documents', 'backups.backupdb',
                'sadame', 'keychains', 'private keys', 'id_rsa', 'id_ed25519', 'id_dsa', 'id_ecdsa') or
                name.startswith('.env') or name.endswith(('.env', '.pem', '.key', '.p12', '.pfx', '.keychain-db',
                                                          '.mobileprovision', '.sqlite', '.sqlite3', '.db')) or
                any(w in name for w in ('credential', 'secret', 'password', 'api_key', 'api-key', 'token'))):
            return True
    return False


def _has_ancestor(parent_fd, ancestor):
    """Also reject nesting through case-insensitive or canonically equivalent spellings."""
    fd = os.dup(parent_fd)
    try:
        for _ in range(256):
            here = os.fstat(fd)
            if os.path.samestat(here, ancestor):
                return True
            prev = os.open('..', _DIR, dir_fd=fd)
            os.close(fd)
            fd = prev
            if os.path.samestat(here, os.fstat(fd)):
                return False
        return True
    finally:
        os.close(fd)


class _Comparison:
    def __init__(self, policy):
        self.policy = policy
        self.deadline = time.monotonic() + _SECONDS
        self.bytes_left = _BYTES
        self.count = 0
        self.matched = 0
        self.bytes = 0
        self.differences = []
        self.warnings = set()
        self.difference_count = 0
        self.devices = None
        self.observed = []

    def difference(self, relative, reason):
        self.difference_count += 1
        if len(self.differences) < _EXAMPLES:
            self.differences.append(f'{relative}: {reason}')

    def check_time(self):
        if time.monotonic() >= self.deadline:
            raise TimeoutError

    def digest(self, fd, s):
        h = hashlib.sha256()
        remaining = s.st_size
        while remaining:
            self.check_time()
            block = os.read(fd, min(remaining, 1 << 20))
            if not block:
                raise OSError('size changed')
            self.bytes_left -= len(block)
            remaining -= len(block)
            h.update(block)
        return h.digest()

    def pair(self, src, dst, sc, dc, rel, a, b, depth):
        self.check_time()
        self.count += 1
        if self.count > _ENTRIES:
            raise OverflowError
        if (_placeholder(a) or a.st_dev != self.devices[0] or not (stat.S_ISDIR(a.st_mode) or stat.S_ISREG(a.st_mode))
                or (b is not None and (_placeholder(b) or b.st_dev != self.devices[1] or
                    not (stat.S_ISDIR(b.st_mode) or stat.S_ISREG(b.st_mode))))):
            self.warnings.add('リンク・別ボリューム・クラウド項目は読み取っていません。')
            return
        if b is None:
            self.difference(rel, '保持先に同じ相対パスがありません')
            return
        if os.path.samestat(a, b):
            self.warnings.add('同じ実体への参照を検出しました。別の保持コピーには数えません。')
            return
        if stat.S_IFMT(a.st_mode) != stat.S_IFMT(b.st_mode):
            self.difference(rel, '種類が異なります')
            return
        if stat.S_ISREG(a.st_mode):
            if a.st_nlink != 1 or b.st_nlink != 1:
                self.warnings.add('複数のハードリンクを持つ項目は読み取っていません。')
                return
            if a.st_size != b.st_size:
                self.difference(rel, 'ファイルサイズが異なります')
                return
            if 2 * a.st_size > self.bytes_left:
                self.warnings.add('読み取りバイト数の上限で未照合の項目があります。')
                return
            flags = _READ
        elif stat.S_ISDIR(a.st_mode):
            if depth >= 48:
                self.warnings.add('階層の上限で未照合の項目があります。')
                return
            flags = _DIR
        else:
            self.warnings.add('特殊ファイルは読み取っていません。')
            return
        with contextlib.ExitStack() as stack:
            x = os.open(sc.name, flags, dir_fd=src)
            stack.callback(os.close, x)
            y = os.open(dc.name, flags, dir_fd=dst)
            stack.callback(os.close, y)
            if _version(os.fstat(x)) != _version(a) or _version(os.fstat(y)) != _version(b):
                raise OSError('changed while opening')
            if flags == _DIR:
                if _stat(x, '.devpurge-keep') or _stat(y, '.devpurge-keep'):
                    self.warnings.add('保持指定のフォルダは読み取っていません。')
                    return
                with os.scandir(x) as entries:
                    for entry in entries:
                        self.check_time()
                        name = entry.name
                        if _blocked(self.policy, sc / name) or _blocked(self.policy, dc / name):
                            self.count += 1
                            if self.count > _ENTRIES:
                                raise OverflowError
                            self.warnings.add('保護・除外対象は読み取っていません。')
                            continue
                        self.pair(x, y, sc / name, dc / name, rel / name,
                                  os.stat(name, dir_fd=x, follow_symlinks=False), _stat(y, name), depth + 1)
            else:
                same = self.digest(x, a) == self.digest(y, b)
            if (_version(os.fstat(x)) != _version(a) or _version(os.fstat(y)) != _version(b) or
                    _version(os.stat(sc.name, dir_fd=src, follow_symlinks=False)) != _version(a) or
                    _version(os.stat(dc.name, dir_fd=dst, follow_symlinks=False)) != _version(b)):
                raise OSError('changed during comparison')
            if flags != _DIR:
                if same:
                    self.observed.append((sc, dc, a, b))
                else:
                    self.difference(rel, 'SHA-256が異なります')
            else:
                self.observed.append((sc, dc, a, b))

    def confirm(self):
        # An earlier file's contents can change while later files are hashed without
        # changing its parent's mtime. A new file deep in a finished directory also
        # needn't change the root directory. Recheck both paths after the whole walk.
        for sc, dc, a, b in self.observed:
            self.check_time()
            for path, original in ((sc, a), (dc, b)):
                with _directory(path.parent) as current:
                    if _version(os.stat(path.name, dir_fd=current, follow_symlinks=False)) != _version(original):
                        raise OSError('observed entry changed')
            if stat.S_ISREG(a.st_mode):
                self.matched += 1
                self.bytes += a.st_size


def compare(copy: Path, keeper: Path) -> dict:
    """Subset comparison of two directory roots or two explicitly selected files."""
    copy, keeper = Path(copy), Path(keeper)
    check = _Comparison(Studio())
    try:
        if (not copy.is_absolute() or not keeper.is_absolute() or _blocked(check.policy, copy) or
                _blocked(check.policy, keeper) or copy == keeper or copy in keeper.parents or keeper in copy.parents):
            check.warnings.add('絶対パスで、保護対象外の独立した二つの場所を指定してください。')
        else:
            with _directory(copy.parent) as src, _directory(keeper.parent) as dst:
                a, b = _stat(src, copy.name), _stat(dst, keeper.name)
                if a is None or b is None:
                    check.warnings.add('指定したコピーまたは保持先の所在を確認できません。')
                elif ((stat.S_ISDIR(a.st_mode) and _has_ancestor(dst, a)) or
                      (stat.S_ISDIR(b.st_mode) and _has_ancestor(src, b))):
                    check.warnings.add('コピーと保持先が包含関係にあります。')
                else:
                    check.devices = (a.st_dev, b.st_dev)
                    check.pair(src, dst, copy, keeper, Path('.'), a, b, 0)
                    check.confirm()
    except (OverflowError, TimeoutError):
        check.warnings.add('時間・件数の上限に達しました。結果は途中までです。')
    except OSError:
        check.warnings.add('状態の変化・権限・リンクなどのため照合を完了できませんでした。')
    return {'status': 'incomplete' if check.warnings else 'different' if check.differences else 'match',
            'matched_files': check.matched, 'matched_bytes': check.bytes,
            'differences': check.differences, 'difference_count': check.difference_count,
            'warnings': sorted(check.warnings), 'scope': _SCOPE}
