#!/usr/bin/env python3
"""Opt-in, file-level archive retention. Never infer arrival from an old mtime."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid

DAY = 86400
PROTECTED = ('証拠', '裁判', '訴訟', '別訴', '告訴', '準備書面', '判決', '弁護士', '法務', '原本', '契約書')


def beneath(path, parent):
    return path == parent or parent in path.parents


def identity(s):
    return [s.st_dev, s.st_ino]


def fingerprint(s):
    return [s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_atime_ns]


def physical(path):
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError('Nonphysical path: ' + str(path))


def opened_paths():
    r = subprocess.run(['lsof', '-nP', '-F', 'n0'], capture_output=True, timeout=30)
    if r.returncode not in (0, 1) or r.stderr.strip():
        raise RuntimeError('Cannot reliably inspect open files; retaining archive')
    return {Path(os.fsdecode(x.lstrip(b'\n')[1:])) for x in r.stdout.split(b'\0')
            if x.lstrip(b'\n').startswith(b'n/')}


def spotlight_usage(root, days):
    # Query metadata only, never file contents. Directory use protects descendants.
    query = 'kMDItemLastUsedDate >= $time.today(-%d)' % (days + 1)
    r = subprocess.run(['mdfind', '-0', '-onlyin', str(root), query], capture_output=True, timeout=30)
    if r.returncode:
        raise RuntimeError('Cannot inspect Spotlight usage; retaining archive')
    result = {}
    for raw in r.stdout.split(b'\0'):
        if not raw:
            continue
        path = Path(os.fsdecode(raw))
        if not beneath(path, root):
            continue
        found = subprocess.run(['mdls', '-raw', '-name', 'kMDItemLastUsedDate', str(path)],
                               capture_output=True, text=True, timeout=10)
        if found.returncode:
            raise RuntimeError('Cannot read last-use metadata: ' + str(path))
        value = found.stdout.strip()
        if value and value != '(null)':
            result[path] = dt.datetime.strptime(value, '%Y-%m-%d %H:%M:%S %z').timestamp()
    return result


class Archive:
    def __init__(self, home, root, state_dir, days=10, protect=(), exclude=(),
                 clock=time.time, opens=opened_paths, usage=spotlight_usage):
        self.home, self.root, self.state_dir = map(Path, (home, root, state_dir))
        self.days, self.clock, self.opens, self.usage = days, clock, opens, usage
        self.protect = tuple(PROTECTED) + tuple(protect)
        self.exclude = tuple(map(Path, exclude))
        if days < 1 or days > 3650:
            raise ValueError('archive_days must be between 1 and 3650')
        physical(self.home)
        physical(self.root)
        physical(self.state_dir)
        if (not beneath(self.root, self.home) or self.root in
                (self.home, self.home / 'Desktop', self.home / 'Documents', self.home / 'Downloads')
                or any(beneath(self.root, self.home / p) for p in ('Library', '.codex', '.claude'))
                or beneath(self.state_dir, self.root)):
            raise ValueError('Archive root must be a dedicated physical folder under HOME')
        self.state_path = self.state_dir / 'state.json'

    def blocked(self, path):
        value = unicodedata.normalize('NFC', str(path))
        return (any(p in value for p in self.protect) or
                any(beneath(path, p) for p in self.exclude) or
                any(p.startswith('.env') or p in ('.git', '.devpurge-keep') for p in path.parts))

    @contextlib.contextmanager
    def lock(self):
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        physical(self.state_dir)
        fd = os.open(self.state_dir / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode) or os.fstat(fd).st_uid != os.getuid() or os.fstat(fd).st_nlink != 1:
                raise ValueError('Unsafe archive lock')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    def load(self):
        if not os.path.lexists(self.state_path):
            return {'version': 1, 'root': str(self.root), 'entries': {}}
        physical(self.state_path)
        s = self.state_path.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_uid != os.getuid():
            raise ValueError('Unsafe archive state')
        data = json.loads(self.state_path.read_text())
        if data.get('version') != 1 or data.get('root') != str(self.root) or not isinstance(data.get('entries'), dict):
            raise ValueError('Archive state does not match the configured root')
        for key, record in data['entries'].items():
            if Path(key).is_absolute() or '..' in Path(key).parts:
                raise ValueError('Invalid path in archive state')
            if not (len(record['identity']) == 2 and len(record['fingerprint']) == 4 and
                    all(isinstance(record[k], (int, float)) and math.isfinite(record[k]) and record[k] >= 0 for k in ('seen', 'activity'))):
                raise ValueError('Invalid archive state record')
        return data

    def save(self, state):
        physical(self.state_dir)
        fd, name = tempfile.mkstemp(prefix='.state-', dir=self.state_dir)
        try:
            with os.fdopen(fd, 'w') as f:
                json.dump(state, f, ensure_ascii=False, separators=(',', ':'))
                f.write('\n'); f.flush(); os.fsync(f.fileno())
            os.replace(name, self.state_path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def scan(self):
        now = self.clock()
        state = self.load()
        report = dict(root=str(self.root), days=self.days, observed_at=now,
                      eligible=[], retained=0, protected=0, reasons={})
        if not self.root.exists():
            report['missing_root'] = True
            report['digest'] = hashlib.sha256(b'[]').hexdigest()
            return report, dict(state, entries={})
        root_stat = self.root.lstat()
        if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != os.getuid():
            raise ValueError('Archive root must be a directory owned by the current user')
        if state.get('root_identity') != identity(root_stat):
            state['entries'] = {}  # A replacement root cannot inherit an old timer.
        opened = {p for p in self.opens() if beneath(p, self.root)}
        used = self.usage(self.root, self.days)
        entries = {}

        def retain(reason):
            report['retained'] += 1
            report['reasons'][reason] = report['reasons'].get(reason, 0) + 1

        def walk_error(error):
            raise error  # Incomplete scans cannot authorize deletion.

        for folder, dirs, files in os.walk(self.root, followlinks=False, onerror=walk_error):
            parent = Path(folder)
            physical(parent)
            if (self.blocked(parent) or '.git' in dirs or '.git' in files or
                    '.devpurge-keep' in files or '.devpurge-keep' in dirs):
                report['protected'] += 1; dirs[:] = []; continue
            allowed_dirs = []
            for name in dirs:
                child = parent / name; s = child.lstat()
                if stat.S_ISLNK(s.st_mode) or s.st_dev != root_stat.st_dev or self.blocked(child):
                    report['protected'] += 1
                else:
                    allowed_dirs.append(name)
            dirs[:] = allowed_dirs
            for name in files:
                path = parent / name; s = path.lstat()
                if (self.blocked(path) or not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or
                        s.st_dev != root_stat.st_dev or s.st_uid != os.getuid() or getattr(s, 'st_flags', 0)):
                    report['protected'] += 1; continue
                key = str(path.relative_to(self.root)); before = state['entries'].get(key)
                new = before is None or before['identity'] != identity(s)
                changed = before is not None and before['fingerprint'] != fingerprint(s)
                seen = now if new else before['seen']
                last_use = max([used.get(path, 0)] + [used.get(p, 0) for p in path.parents if beneath(p, self.root)])
                active = path in opened or any(p in opened for p in path.parents)
                activity = max(seen, s.st_mtime, s.st_ctime, s.st_atime, last_use,
                               now if changed or active else 0, 0 if new else before['activity'])
                record = dict(identity=identity(s), fingerprint=fingerprint(s), seen=seen, activity=activity)
                entries[key] = record
                reason = ('newly_observed' if new else 'in_use' if active else
                          'changed' if changed else 'within_retention' if now - max(seen, activity) < self.days * DAY else None)
                if reason:
                    retain(reason)
                else:
                    report['eligible'].append(dict(relative=key, identity=identity(s), fingerprint=fingerprint(s),
                                                   bytes=s.st_blocks * 512, expires_at=max(seen, activity) + self.days * DAY))
        report['eligible'].sort(key=lambda r: r['relative'])
        report['digest'] = hashlib.sha256(json.dumps(report['eligible'], sort_keys=True).encode()).hexdigest()
        report['eligible_bytes'] = sum(r['bytes'] for r in report['eligible'])
        return report, dict(version=1, root=str(self.root), root_identity=identity(root_stat), entries=entries)

    def observe(self, touch=None):
        with self.lock():
            report, state = self.scan()
            if touch is not None:
                touch = Path(touch); physical(touch)
                if not beneath(touch, self.root) or not touch.exists():
                    raise ValueError('Touch target must exist inside the archive')
                touched = 0
                for key, value in state['entries'].items():
                    if beneath(self.root / key, touch):
                        value['activity'] = max(value['activity'], self.clock())
                        touched += 1
                report['touched'] = touched
                previous_count = len(report['eligible'])
                report['eligible'] = [r for r in report['eligible'] if not beneath(self.root / r['relative'], touch)]
                report['retained'] += previous_count - len(report['eligible'])
                report['eligible_bytes'] = sum(r['bytes'] for r in report['eligible'])
                report['digest'] = hashlib.sha256(json.dumps(report['eligible'], sort_keys=True).encode()).hexdigest()
            self.save(state)
            report['tracked'] = len(state['entries'])
            report['state_saved'] = True
            return report

    @contextlib.contextmanager
    def parent_fd(self, path, root_identity):
        physical(self.root)
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            if identity(os.fstat(fd)) != root_identity:
                raise ValueError('Archive root changed')
            current = self.root
            for part in path.parent.relative_to(self.root).parts:
                nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd); fd = nxt; current = current / part
                if self.blocked(current) or os.path.lexists(current / '.git') or os.path.lexists(current / '.devpurge-keep'):
                    raise ValueError('Protection added after scan')
            physical(path.parent)
            if identity(os.fstat(fd)) != identity(path.parent.lstat()):
                raise ValueError('Archive parent changed')
            if os.path.lexists(self.root / '.git') or os.path.lexists(self.root / '.devpurge-keep'):
                raise ValueError('Archive root became protected')
            yield fd
        finally:
            os.close(fd)

    def expire(self, expected=None, trash=False):
        with self.lock():
            report, state = self.scan()
            if expected is not None and report['digest'] != expected:
                raise ValueError('Archive changed since scan; scan again')
            self.save(state)  # Newly observed/used files get their timer even with no candidates.
            result = dict(removed=0, trashed=0, bytes=0, errors=[], retained=report['retained'], protected=report['protected'])
            if not report['eligible']:
                return result
            free_before = os.statvfs(self.root)
            opened = {p for p in self.opens() if beneath(p, self.root)}  # Recheck before mutation.
            log_path = self.state_dir / ('deletions-' + dt.datetime.now().strftime('%Y%m') + '.jsonl')
            physical(log_path)
            log_fd = os.open(log_path, os.O_CREAT | os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW, 0o600)
            with os.fdopen(log_fd, 'a') as journal:
                log_stat = os.fstat(journal.fileno())
                if not stat.S_ISREG(log_stat.st_mode) or log_stat.st_nlink != 1 or log_stat.st_uid != os.getuid():
                    raise ValueError('Unsafe archive journal')
                def log(row):
                    journal.write(json.dumps(dict(at=self.clock(), **row), ensure_ascii=False) + '\n')
                    journal.flush(); os.fsync(journal.fileno())
                for item in report['eligible']:
                    path = self.root / item['relative']
                    try:
                        if path in opened or any(p in opened for p in path.parents):
                            state['entries'][item['relative']]['activity'] = self.clock()
                            result['retained'] += 1; continue
                        if self.blocked(path):
                            raise ValueError('File became protected')
                        with self.parent_fd(path, state['root_identity']) as fd:
                            s = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
                            if (not stat.S_ISREG(s.st_mode) or identity(s) != item['identity'] or
                                    fingerprint(s) != item['fingerprint'] or s.st_nlink != 1 or getattr(s, 'st_flags', 0)):
                                raise ValueError('File changed since scan')
                            destination = None
                            if trash:
                                trash_dir = self.home / '.Trash'; physical(trash_dir)
                                trash_dir.mkdir(mode=0o700, exist_ok=True)
                                destination = trash_dir / ('devpurge-archive-' + uuid.uuid4().hex + '-' + path.name)
                            log(dict(stage='attempt', path=str(path), identity=item['identity'], bytes=item['bytes'],
                                     destination=str(destination) if destination else None))
                            if trash:
                                os.rename(path.name, destination, src_dir_fd=fd)
                            else:
                                os.unlink(path.name, dir_fd=fd)
                        log(dict(stage='trashed' if trash else 'removed', path=str(path), bytes=item['bytes']))
                        state['entries'].pop(item['relative'])
                        result['trashed' if trash else 'removed'] += 1; result['bytes'] += item['bytes']
                    except (OSError, ValueError) as error:
                        result['errors'].append(dict(path=str(path), error=str(error)))
                        log(dict(stage='failed', path=str(path), error=str(error)))
                        break
                self.save(state)
            free_after = os.statvfs(self.root)
            result['observed_free_increase_bytes'] = (free_after.f_bavail * free_after.f_frsize -
                                                     free_before.f_bavail * free_before.f_frsize)
            return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=('scan', 'observe', 'expire', 'touch'))
    p.add_argument('--home', required=True); p.add_argument('--root', required=True)
    p.add_argument('--state-dir', required=True); p.add_argument('--days', type=int, default=10)
    p.add_argument('--protect', action='append', default=[]); p.add_argument('--exclude', action='append', default=[])
    p.add_argument('--expected'); p.add_argument('--target'); p.add_argument('--trash', action='store_true')
    p.add_argument('--authorized', action='store_true')
    p.add_argument('--rows', action='store_true'); p.add_argument('--summary', action='store_true')
    args = p.parse_args()
    if os.geteuid() == 0:
        raise ValueError('Run archive retention as the archive owner, without sudo')
    archive = Archive(args.home, args.root, args.state_dir, args.days, args.protect, args.exclude)
    if args.command == 'scan':
        result, _ = archive.scan()
    elif args.command == 'observe':
        result = archive.observe()
    elif args.command == 'touch':
        if not args.target:
            raise ValueError('touch requires --target')
        result = archive.observe(args.target)
    else:
        if not args.authorized:
            raise ValueError('Archive expiry requires explicit authorization')
        result = archive.expire(args.expected, args.trash)
    if args.rows:
        if any(c in args.root for c in '|\t\r\n'):
            raise ValueError('Archive root cannot contain row delimiters')
        if result['eligible']:
            size = result['eligible_bytes']
            print('AR01|%s|archive|archive: %d files idle %dd|%.1fM|%d|archive:%s' %
                  (args.root, len(result['eligible']), args.days, size / 1048576, size, result['digest']))
    elif args.summary:
        print('%d|%d|%d|%d' % (result['removed'] + result['trashed'], result['bytes'], result['retained'], len(result['errors'])))
    else:
        compact = dict(result)
        if 'eligible' in compact:
            compact['eligible_files'] = len(compact.pop('eligible'))
        print(json.dumps(compact, ensure_ascii=False, indent=2))
    return 2 if result.get('errors') else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('Archive retained: ' + str(error), file=sys.stderr)
        sys.exit(2)
