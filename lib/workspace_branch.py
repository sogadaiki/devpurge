"""Retire one expected local branch using Git's merged-branch deletion checks."""
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import time
import uuid

from workspace_git import InventoryError, _blocked, _git, _retained, _value, _worktrees, inventory
from workspace_folders import _directory
from studio import Studio


def require(condition, reason):
    if not condition:
        raise InventoryError(reason)


def _snapshot(repo, name, sha, base):
    require(not _blocked(repo, Studio()), '現在の保護・除外設定で保持します。')
    with _directory(repo) as fd:
        require(os.fstat(fd).st_uid == os.getuid() and _value(repo, 'rev-parse', '--absolute-git-dir') == str(repo / '.git'),
                '指定した主作業コピーの所在が変わりました。')
    full = 'refs/heads/' + name
    require(_value(repo, 'rev-parse', '--verify', full) == sha, '指定後にブランチの先端が変わりました。')
    require(_git(repo, 'symbolic-ref', '--quiet', full, allow=(0, 1)).returncode == 1,
            '別の参照を指すブランチは保持します。')
    require(not any(row['branch'] == name for row in _worktrees(repo)), '使用中の作業コピーがあります。')
    held = _retained(repo, [])
    require(held is not None and name not in held, '作業コピーの復元記録があるか、記録を照合できません。')
    remote = _git(repo, 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD', allow=(0, 1))
    origin = os.fsdecode(remote.stdout.removesuffix(b'\n')) if remote.returncode == 0 else ''
    require(not origin or origin.startswith('refs/remotes/origin/'), '既定のリモート参照を確認できません。')
    require(full != base and (not origin or origin.removeprefix('refs/remotes/origin/') != name)
            and name not in ('main', 'master', 'develop'), '主要ブランチは保持します。')
    upstream = _value(repo, 'for-each-ref', '--format=%(upstream)', full)
    if not upstream:
        for field in ('remote', 'merge'):
            require(_git(repo, 'config', '--get', f'branch.{name}.{field}', allow=(0, 1)).returncode == 1,
                    '設定された追跡先を照合できません。')
    refs = {ref for ref in (base, origin, upstream) if ref}
    heads = {}
    for ref in refs:
        target = _value(repo, 'rev-parse', '--verify', ref + '^{commit}')
        require(_git(repo, 'merge-base', '--is-ancestor', sha, target, allow=(0, 1)).returncode == 0,
                '既定ブランチまたは追跡先への統合を確認できません。')
        heads[ref] = target
    return heads


def _guard(repo, name, sha, base, pin, targets, phase):
    if phase != 'prepared':
        return
    # branch -d supplies zero as its old-value. Its transaction now holds the ref
    # lock; checking its still-visible old value here is different from preflight.
    updates = sys.stdin.buffer.read().splitlines()
    require(len(updates) == 1, '想定外の参照トランザクション')
    old, new, ref = updates[0].split(b' ', 2)
    require(ref == os.fsencode('refs/heads/' + name) and new == b'0' * len(sha)
            and old in (os.fsencode(sha), b'0' * len(sha)), '対象参照が変化しました。')
    require(_value(repo, 'rev-parse', '--verify', pin) == sha, '復元参照が変化しました。')
    require(_snapshot(repo, name, sha, base) == targets, '照合後に統合先が変化しました。')


def retire_branch(repo: Path, name: str, expected_sha: str) -> dict:
    restore = None
    attempted = False
    native_succeeded = False
    try:
        repo = Path(repo)
        require(repo.is_absolute() and not _blocked(repo, Studio()), '保護・除外対象は保持します。')
        with _directory(repo) as fd:
            require(os.fstat(fd).st_uid == os.getuid(), '本人が所有するリポジトリを指定してください。')
        require(not any(ord(c) < 32 or c == '\x7f' for c in str(repo)), 'ログで復元できるパスを指定してください。')
        require(bool(re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', expected_sha)), '完全なコミットIDを指定してください。')
        result = inventory(repo)
        require(not result['metadata_only'] and name and not name.startswith('-')
                and _value(repo, 'check-ref-format', '--branch', name) == name, '整理対象の正確なブランチ名を指定してください。')
        row = next((r for r in result['branches'] if r['name'] == name), None)
        pin = 'refs/devpurge/retired-branches/' + expected_sha
        # Pin name is stable so restoring after a later force-move of main does not rely on reflog expiry.
        restore = shlex.join(['git', '-C', str(repo), 'branch', name, expected_sha])
        if row is None:
            require(_git(repo, 'show-ref', '--verify', '--quiet', pin, allow=(0, 1)).returncode == 0
                    and _value(repo, 'rev-parse', '--verify', pin) == expected_sha,
                    'ブランチが存在せず、この操作の復元先を確認できません。')
            return {'status': 'held', 'reason': 'ブランチは既に存在しません。復元用コミットを確認しました。', 'restore_command': restore}
        require(row['head'] == expected_sha and not row['protected'] and not row['checked_out'] and row['merged'] is True,
                '先端の相違・保護・使用中・統合未確認のいずれかにより保持します。')
        base = result['base']
        targets = _snapshot(repo, name, expected_sha, base)
        hook_name = 'devpurge-branch-' + uuid.uuid4().hex
        command = shlex.join([sys.executable, '-B', str(Path(__file__).resolve()), '--guard', str(repo),
                              name, expected_sha, base, pin, json.dumps(targets)])
        hook = ('-c', f'hook.{hook_name}.event=reference-transaction', '-c', f'hook.{hook_name}.command={command}')
        enabled = _git(repo, *hook, 'hook', 'list', '-z', 'reference-transaction').stdout.split(b'\0')
        require(os.fsencode(hook_name) in enabled, 'この Git で参照ロック中の先端照合を有効にできません。')
        logdir = Path(os.environ.get('DEVPURGE_LOG_DIR', Path.home() / 'Library/Application Support/devpurge/logs'))
        require(logdir.is_absolute() and logdir.resolve() == logdir, '復元ログの保存先を確認できません。')
        logdir.mkdir(mode=0o700, parents=True, exist_ok=True)
        with _directory(logdir) as directory:
            day = datetime.date.today().strftime('%Y%m%d')
            log_fd = os.open(f'deleted-branches-{day}.tsv', os.O_NOFOLLOW | os.O_CLOEXEC | os.O_RDWR | os.O_CREAT | os.O_APPEND,
                             0o600, dir_fd=directory)
            with os.fdopen(log_fd, 'a+b') as log:
                s = os.fstat(log.fileno())
                require(stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and s.st_uid == os.getuid(), '復元ログの実体を照合できません。')
                fcntl.flock(log.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                if _git(repo, 'show-ref', '--verify', '--quiet', pin, allow=(0, 1)).returncode:
                    _git(repo, 'update-ref', pin, expected_sha, '0' * len(expected_sha))
                require(_value(repo, 'rev-parse', '--verify', pin) == expected_sha, '復元用コミットを固定できません。')
                fields = [os.fsencode(repo), os.fsencode(name), os.fsencode(expected_sha)]
                log.seek(0)
                if not any(line.rstrip(b'\n').split(b'\t')[1:] == fields for line in log):
                    log.write(b'\t'.join([str(int(time.time())).encode(), *fields]) + b'\n')
                    log.flush()
                    os.fsync(log.fileno())
                require(_snapshot(repo, name, expected_sha, base) == targets, '直前の照合中に参照が変わりました。')
                attempted = True
                _git(repo, *hook, 'branch', '-d', '--', name)
                native_succeeded = True
        require(_git(repo, 'show-ref', '--verify', '--quiet', 'refs/heads/' + name, allow=(0, 1)).returncode == 1,
                '操作後に同名のブランチがあるため状態を再確認してください。')
        return {'status': 'retired', 'reason': 'ローカルブランチの削除と復元用コミットを確認しました。', 'restore_command': restore}
    except (InventoryError, OSError, ValueError) as error:
        if attempted:
            try:
                present = _git(repo, 'show-ref', '--verify', '--quiet', 'refs/heads/' + name, allow=(0, 1)).returncode == 0
            except (InventoryError, OSError, ValueError):
                present = None
            if native_succeeded or present is not True:
                return {'status': 'unverified', 'reason': '実行後の結果を確定できません。復元記録と現在の参照を照合してください。',
                        'restore_command': restore}
        return {'status': 'held', 'reason': str(error), 'restore_command': restore}


if __name__ == '__main__':
    if len(sys.argv) != 9 or sys.argv[1] != '--guard':
        sys.exit(2)
    try:
        _guard(Path(sys.argv[2]), *sys.argv[3:7], json.loads(sys.argv[7]), sys.argv[8])
    except (OSError, ValueError):
        sys.exit(1)
