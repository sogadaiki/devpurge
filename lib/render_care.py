#!/usr/bin/env python3
"""Reclaim verified Remotion bundles. AI may veto, never grant delete authority.

No user contents or paths are sent to Codex. No model tools, credentials, shell
commands or paths from model output are accepted by the cleanup engine.
"""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

STATE = Path.home() / 'Library/Application Support/devpurge/render-care'
MODELS = ('luna', 'terra', 'sol', 'astra')
BUNDLE = re.compile(r'remotion-webpack-bundle-[A-Za-z0-9]+$')
GENERATED = re.compile(r'(?:index\.html|favicon\.ico|source-map-helper\.wasm|(?:\d+\.)?bundle\.js(?:\.map)?)$')
PROTECTED = ('証拠', '裁判', '訴訟', '準備書面', '判決', '原本', '契約書', '.devpurge-keep')


def run(argv, timeout=30):
    environment = {**os.environ, 'LC_ALL': 'C'}
    if Path(argv[0]).name == 'codex':
        # Do not accidentally switch this credit-backed job to API billing.
        for key in ('OPENAI_API_KEY', 'CODEX_API_KEY', 'OPENAI_BASE_URL'):
            environment.pop(key, None)
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                          stdin=subprocess.DEVNULL,
                          env=environment)


def resolve_model(role):
    """Use the installed CLI's advertised models, not the desktop's catalog."""
    catalog = Path.home() / '.codex/models_cache.json'
    if catalog.exists() and not catalog.is_symlink():
        data = json.loads(catalog.read_text())
        matches = []
        for row in data.get('models', []):
            slug = row.get('slug', '')
            match = re.fullmatch(r'gpt-(\d+)(?:\.(\d+))?-' + re.escape(role), slug)
            if match:
                matches.append(((int(match[1]), int(match[2] or 0)), slug))
        if matches:
            return max(matches)[1]
    raise ValueError('No advertised Codex CLI model for ' + role + '; refresh Codex model catalog')


def save(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.resolve() != path.parent or path.is_symlink():
        raise ValueError('State path must not be a link')
    fd, tmp = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load(path, default):
    if path.is_symlink():
        raise ValueError('State symlink refused')
    return json.loads(path.read_text()) if path.exists() else default


def physical(path):
    p = Path(path)
    if not p.is_absolute() or p != p.resolve() or not p.is_dir():
        raise ValueError('Expected existing physical directory')
    return p


def user_temp():
    result = run(['/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR'])
    result.check_returncode()
    p = Path(result.stdout.strip()).resolve()
    if not str(p).startswith('/private/var/folders/') or p.name != 'T' or p.stat().st_uid != os.getuid():
        raise ValueError('Unexpected user temporary directory')
    return p


def identity(p):
    s = p.lstat()
    return [s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns]


def digest(p, cache):
    key = (str(p), tuple(identity(p)))
    if key not in cache:
        h = hashlib.sha256()
        # Do not follow a final-component link if it was replaced during inspection.
        fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise ValueError('Not a regular file')
            for block in iter(lambda: f.read(4 * 1024 * 1024), b''):
                h.update(block)
        if key[1] != tuple(identity(p)):
            raise ValueError('File changed while hashing')
        cache[key] = h.hexdigest()
    return cache[key]


def protected(p):
    return any(x in str(p) for x in PROTECTED) or any(
        x.startswith('.env') or x in ('.git', '.ssh', 'auth.json', 'credentials.json', '.npmrc', '.netrc') for x in p.parts)


def inspect_bundle(path, public, cache, blocked=protected):
    """All public regular files must match retained originals, links match links.

    Generated top-level files have a narrow Remotion bundler grammar. We never
    traverse public links; unlinking a copied link cannot remove its destination.
    """
    physical(path)
    physical(public)
    records, keepers, unmatched, copies, allocated = [], [], [], [], 0
    def unreadable(error):
        raise error
    for base, dirs, files in os.walk(path, followlinks=False, onerror=unreadable):
        dirs.sort()
        for name in sorted(dirs + files):
            p = Path(base) / name
            rel = p.relative_to(path)
            if blocked(p):
                raise ValueError('Protected filename')
            sig = identity(p)
            s = p.lstat()
            if s.st_uid != os.getuid():
                raise ValueError('Different owner')
            records.append([str(rel), sig])
            allocated += s.st_blocks * 512
            if rel.parts[0] != 'public':
                if len(rel.parts) != 1 or not p.is_file() or p.is_symlink() or not GENERATED.fullmatch(name):
                    raise ValueError('Unknown generated file')
                continue
            source = public.joinpath(*rel.parts[1:])
            if blocked(source):
                raise ValueError('Protected source')
            if p.is_symlink():
                if not source.is_symlink() or os.readlink(p) != os.readlink(source) or not source.exists():
                    unmatched.append(str(rel))
                else:
                    keepers.append([str(source), identity(source), 'link', os.readlink(source)])
            elif stat.S_ISDIR(s.st_mode):
                if source != source.resolve() or not source.is_dir():
                    unmatched.append(str(rel))
            elif stat.S_ISREG(s.st_mode):
                if source != source.resolve() or not source.is_file() or source.stat().st_size != s.st_size:
                    unmatched.append(str(rel))
                    continue
                sha = digest(p, cache)
                if sha != digest(source, cache):
                    unmatched.append(str(rel))
                    continue
                keepers.append([str(source), identity(source), 'sha256', sha])
                copies.append([str(rel), sig, s.st_blocks * 512])
            else:
                raise ValueError('Special file refused')
    if not (path / 'index.html').is_file() or not (path / 'bundle.js').is_file() or not (path / 'public').is_dir():
        raise ValueError('Not a complete bundler layout')
    if unmatched and not copies:
        raise ValueError('No identical retained originals; keeping all files')
    return {'identity': identity(path), 'tree': records, 'keepers': keepers, 'bytes': allocated,
            'unmatched': unmatched, 'copies': copies,
            'reclaimable_bytes': sum(x[2] for x in copies) if unmatched else allocated}


def unlink_copy(root, relative, expected):
    """Descriptor-relative unlink; never traverse a replaced directory link."""
    parts = Path(relative).parts
    if not parts or parts[0] != 'public' or any(p in ('..', '.') for p in parts) or Path(relative).is_absolute():
        raise ValueError('Invalid copy path')
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        s = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        sig = [s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns]
        if sig != expected or not stat.S_ISREG(s.st_mode):
            raise ValueError('Copy changed before unlink')
        os.unlink(parts[-1], dir_fd=fd)
    finally:
        os.close(fd)


def activity(sources=()):
    """Fail closed on missing process/open-file evidence. Keep raw argv in memory.

    Legacy bundles created during any live render's lifetime are protected even
    when the renderer has no file open. Source-root Node processes count too.
    """
    p = run(['/bin/ps', '-axo', 'pid=,lstart=,comm='])
    p.check_returncode()
    a = run(['/bin/ps', '-axo', 'pid=,args='])
    a.check_returncode()
    args_by_pid = {int(x.split(None, 1)[0]): x.split(None, 1)[1] for x in a.stdout.splitlines() if len(x.split(None, 1)) == 2}
    f = run(['/usr/sbin/lsof', '-nP', '-Fpfn'], timeout=45)
    if f.returncode != 0 or f.stderr.strip():
        raise ValueError('Open-file inventory incomplete; keeping all candidates')
    cwd_pids, paths = set(), []
    pid, descriptor = None, None
    for line in f.stdout.splitlines():
        if line.startswith('p'):
            pid = int(line[1:])
        elif line.startswith('f'):
            descriptor = line[1:]
        elif line.startswith('n/'):
            paths.append(line[1:])
            if descriptor == 'cwd' and any(line[1:] == root or line[1:].startswith(root + '/') for root in sources):
                cwd_pids.add(pid)
    rows = []
    for line in p.stdout.splitlines():
        parts = line.strip().split(None, 6)
        if len(parts) != 7 or not parts[0].isdigit() or int(parts[0]) == os.getpid():
            continue
        pid, executable = int(parts[0]), parts[6]
        args = args_by_pid.get(pid, '')
        # Shell wrappers can contain this program's literal source: consider
        # actual executable names, not arbitrary shell command text.
        name = Path(executable).name.lower()
        if ('chrome-headless' in name or name == 'remotion' or
                (name in ('node', 'ffmpeg') and (pid in cwd_pids or 'remotion' in args or 'podcast_render' in args))):
            started = time.mktime(time.strptime(' '.join(parts[1:6]), '%a %b %d %H:%M:%S %Y'))
            rows.append({'pid': pid, 'name': name, 'started': started})
    return {'renderers': rows, 'open_paths': paths, 'arguments': list(args_by_pid.values())}


def open_under(path, observed):
    prefixes = [str(path), str(path).replace('/private/var/', '/var/', 1)]
    return any(p == root or p.startswith(root + '/') for p in observed['open_paths'] for root in prefixes)


def active_bundle(path, observed):
    if open_under(path, observed):
        return True
    if any(path.name in value for value in observed.get('arguments', [])):
        return True
    # The legacy bundler makes a new random directory per invocation. Preserve
    # every directory born within one hour before the oldest live renderer,
    # plus all newer directories. Missing birth/start evidence means keep.
    renderers = observed['renderers']
    if not renderers:
        return False
    birth = getattr(path.stat(), 'st_birthtime', None)
    starts = [x.get('started') for x in renderers]
    return birth is None or not all(starts) or birth >= min(starts) - 3600


class Care:
    def __init__(self, state=STATE, temp=None, probe=activity):
        self.state = Path(state).absolute()
        self.temp = physical(temp) if temp else user_temp()
        self.probe = (lambda: activity(self.config()['sources'])) if probe is activity else probe
        self.cache = {}
        self.excluded = [Path.home() / 'Desktop/development/sadame']
        self.protected_names = list(PROTECTED)
        rc = Path.home() / '.devpurgerc'
        if rc.is_file() and not rc.is_symlink():
            for line in rc.read_text().splitlines():
                key, sep, value = line.partition('=')
                if sep and value.strip():
                    if key.strip() in ('exclude', 'archive_root'):
                        self.excluded.append(Path(value.strip()).expanduser().absolute())
                    elif key.strip() == 'protect':
                        self.protected_names.append(value.strip())

    def blocked(self, path):
        p = Path(path)
        return protected(p) or any(x in str(p) for x in self.protected_names) or any(p == x or x in p.parents for x in self.excluded)

    @contextlib.contextmanager
    def locked(self):
        self.state.mkdir(parents=True, mode=0o700, exist_ok=True)
        physical(self.state)
        fd = os.open(self.state / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield

    def config(self):
        return load(self.state / 'config.json', {'sources': [], 'primary': 'luna', 'reviewer': 'terra', 'enabled': False})

    def scan(self, verify=False):
        config = self.config()
        public_dirs = [physical(p) / 'public' for p in config['sources']]
        observed = self.probe()
        before = load(self.state / 'latest.json', {})
        previous = {x['id']: x for x in before.get('items', [])}
        items = []
        for path in sorted(self.temp.iterdir()):
            if not path.name.startswith(('remotion-', 'react-motion-render')):
                continue
            row = {'id': hashlib.sha256(str(path).encode()).hexdigest()[:16], 'name': path.name,
                   'kind': 'bundle' if BUNDLE.fullmatch(path.name) else 'render-intermediate',
                   'status': 'keep', 'reason': 'Unregistered render intermediate', 'bytes': None}
            items.append(row)
            if path.is_symlink() or not path.is_dir() or self.blocked(path):
                row['reason'] = 'Invalid or protected target'
                continue
            size = run(['/usr/bin/du', '-sk', str(path)], timeout=15)
            if size.returncode == 0 and not size.stderr and size.stdout.split()[0].isdigit():
                row['bytes'] = int(size.stdout.split()[0]) * 1024
            row['delta'] = (row['bytes'] - previous[row['id']]['bytes']) if row['bytes'] is not None and previous.get(row['id'], {}).get('bytes') is not None else None
            if row['kind'] != 'bundle':
                continue
            if active_bundle(path, observed):
                row['reason'] = 'Active renderer/browser or open files; preserved'
                continue
            if time.time() - path.stat().st_mtime < 3600:
                row['reason'] = 'Recent bundle; wait at least one hour'
                continue
            if not verify:
                row['reason'] = 'Needs retained-original verification'
                continue
            errors = []
            for public in public_dirs:
                try:
                    proof = inspect_bundle(path, public, self.cache, self.blocked)
                    if time.time() - max([path.stat().st_mtime] + [x[1][4] / 1e9 for x in proof['tree']]) < 3600:
                        raise ValueError('Recent nested modification')
                    row.update(status='verified', reason='Identical public copies only; differing files retained' if proof['unmatched'] else 'Public copies match retained originals; generated bundler files only', proof=proof, reclaimable_bytes=proof['reclaimable_bytes'])
                    break
                except (OSError, ValueError) as e:
                    errors.append(str(e))
            if row['status'] != 'verified':
                row['reason'] = '; '.join(errors[:3]) or 'No retained source configured'
        now = time.time()
        total = sum(x['bytes'] or 0 for x in items)
        result = {'at': now, 'free': shutil.disk_usage(self.temp).free, 'items': items,
                  'renderers': observed['renderers'],
                  'temp_bytes': total if all(x['bytes'] is not None for x in items) else None,
                  'observed_temp_bytes': total,
                  'scope': 'Remotion top-level temp directories only; overlapping totals are not added'}
        result['growth_bytes'] = result['temp_bytes'] - before['temp_bytes'] if result['temp_bytes'] is not None and before.get('temp_bytes') is not None else None
        result['alert'] = result['free'] < 50 * 2**30 or (result['growth_bytes'] or 0) >= 10 * 2**30
        save(self.state / 'latest.json', result)
        history = load(self.state / 'history.json', [])
        history.append({k: result[k] for k in ('at', 'free', 'temp_bytes', 'growth_bytes', 'alert')})
        save(self.state / 'history.json', history[-2016:])
        return result

    def classify(self, result):
        """Only opaque IDs and verified facts leave this Mac, never file paths."""
        rows = [dict(id=x['id'], kind=x['kind'], bytes=x.get('reclaimable_bytes', 0), local_verified=x['status'] == 'verified',
                     active=x['status'] != 'verified', retained_originals=x['status'] == 'verified') for x in result['items']]
        candidates = [x for x in rows if x['local_verified']]
        if not candidates:
            return {'status': 'not-needed', 'decisions': [], 'runs': []}
        config = self.config()
        try:
            first = model_review(candidates, config['primary'], self.state)
        except (ValueError, OSError, subprocess.SubprocessError):
            # A primary model outage is not permission to delete. The configured
            # reviewer must return an independently valid answer instead.
            if config['reviewer'] == config['primary']:
                raise
            first = model_review(candidates, config['reviewer'], self.state)
            first['fallback_from'] = config['primary']
        decisions = {x['id']: x for x in first['decisions']}
        large_batch = sum(x['bytes'] or 0 for x in candidates) >= 10 * 2**30
        ambiguous = [x for x in candidates if decisions[x['id']]['decision'] == 'review' or
                     (large_batch and decisions[x['id']]['decision'] == 'cleanup')]
        runs = [first['model']]
        if ambiguous:
            second = model_review(ambiguous, config['reviewer'], self.state)
            decisions.update({x['id']: x for x in second['decisions']})
            runs.append(second['model'])
        return {'status': 'reviewed', 'decisions': list(decisions.values()), 'runs': runs,
                'fallback_from': first.get('fallback_from')}

    def apply(self, result, ai):
        if time.time() - result['at'] > 600:
            raise ValueError('Plan expired')
        if not shutil.rmtree.avoids_symlink_attacks:
            raise ValueError('This Python lacks descriptor-safe removal')
        allowed = {x['id'] for x in ai.get('decisions', []) if x['decision'] == 'cleanup'}
        receipt = {'at': time.time(), 'before_free': shutil.disk_usage(self.temp).free,
                   'ai': ai, 'items': [], 'permanent': True}
        target = self.state / 'receipts' / ('run-' + str(time.time_ns()) + '.json')
        proof_file = target.with_name(target.stem + '-proof.json')
        save(proof_file, {x['name']: x['proof'] for x in result['items'] if x['status'] == 'verified' and x['id'] in allowed})
        receipt['proof_file'] = proof_file.name
        save(target, receipt)
        for row in result['items']:
            if row['status'] != 'verified' or row['id'] not in allowed:
                continue
            path = self.temp / row['name']
            entry = {'name': row['name'], 'status': 'pending', 'bytes': row['proof']['reclaimable_bytes']}
            receipt['items'].append(entry)
            save(target, receipt)
            try:
                if not BUNDLE.fullmatch(row['name']) or path.parent != self.temp:
                    raise ValueError('Not allowlisted')
                proof = row['proof']
                # Rebuild the full tree and rehash originals/copies on the first
                # use in this run. Cache keys include inode, ctime and mtime.
                verified = False
                for root in self.config()['sources']:
                    candidate_public = physical(root) / 'public'
                    try:
                        current = inspect_bundle(path, candidate_public, self.cache, self.blocked)
                        if current == proof:
                            verified = True
                            break
                    except (OSError, ValueError):
                        pass
                if not verified:
                    raise ValueError('Target or retained originals changed')
                observed = self.probe()
                known = {(x['pid'], x.get('started')) for x in result.get('renderers', [])}
                appeared = any((x['pid'], x.get('started')) not in known for x in observed['renderers'])
                if appeared or active_bundle(path, observed):
                    raise ValueError('Renderer started or file opened; kept')
                if identity(path) != proof['identity']:
                    raise ValueError('Target identity changed')
                entry['status'] = 'removing'
                save(target, receipt)  # durable attempt, not claimed success
                if proof['unmatched']:
                    entry['retained_unmatched'] = proof['unmatched']
                    entry['removed_copies'] = []
                    for relative, sig, size in proof['copies']:
                        unlink_copy(path, relative, sig)
                        entry['removed_copies'].append(relative)
                    entry['status'] = 'trimmed'
                else:
                    shutil.rmtree(path)
                    entry['status'] = 'removed' if not path.exists() else 'failed'
            except (OSError, ValueError, subprocess.SubprocessError) as e:
                entry.update(status='kept-or-partial', error=str(e))
            save(target, receipt)
        receipt['after_free'] = shutil.disk_usage(self.temp).free
        receipt['free_delta'] = receipt['after_free'] - receipt['before_free']
        receipt['removed_bytes'] = sum(x['bytes'] or 0 for x in receipt['items'] if x['status'] in ('removed', 'trimmed'))
        save(target, receipt)
        save(self.state / 'last-receipt.json', receipt)
        return receipt

    def cycle(self, apply=False):
        with self.locked():
            result = self.scan(verify=True)
            try:
                ai = self.classify(result)
            except (ValueError, OSError, subprocess.SubprocessError) as e:
                ai = {'status': 'unavailable', 'error': str(e), 'decisions': [], 'runs': []}
            save(self.state / 'review.json', ai)
            return self.apply(result, ai) if apply and ai['status'] == 'reviewed' else {'scan': result, 'ai': ai}


def model_review(rows, model, state, runner=run):
    if model not in MODELS:
        raise ValueError('Unsupported model')
    schema = {'type': 'object', 'additionalProperties': False, 'required': ['decisions'], 'properties': {
        'decisions': {'type': 'array', 'items': {'type': 'object', 'additionalProperties': False,
            'required': ['id', 'decision', 'reason'], 'properties': {
                'id': {'type': 'string'}, 'decision': {'type': 'string', 'enum': ['cleanup', 'keep', 'review']},
                'reason': {'type': 'string'}}}}}}
    executable = shutil.which('codex')
    if not executable:
        raise ValueError('Codex CLI unavailable; keeping candidates')
    resolved_model = resolve_model(model)
    # Isolated ephemeral cwd; user config is disabled and no source contents are
    # supplied. CLI global instructions may still load. Auth is reused by CLI.
    with tempfile.TemporaryDirectory(prefix='model-', dir=state) as directory:
        directory = Path(directory)
        save(directory / 'schema.json', schema)
        prompt = ('Classify these trusted LOCAL verification facts. Do not use any tools. '
                  'Return exactly one decision per id. cleanup only for local_verified=true, '
                  'retained_originals=true, active=false bundles. Otherwise keep; review if uncertain. '
                  'No filesystem actions. Facts: ' + json.dumps(rows, separators=(',', ':')))
        p = runner([executable, 'exec', '--ignore-user-config', '--ephemeral', '--skip-git-repo-check',
                    '-C', str(directory), '-s', 'read-only', '-m', resolved_model,
                    '-c', 'model_reasoning_effort="low"',
                    '-c', 'forced_login_method="chatgpt"',
                    '--output-schema', str(directory / 'schema.json'), '-o', str(directory / 'answer.json'), prompt], timeout=180)
        if p.returncode != 0:
            raise ValueError('Codex failed; no deletion (exit %s)' % p.returncode)
        output = directory / 'answer.json'
        if not output.is_file() or output.stat().st_size > 128000:
            raise ValueError('Invalid model response')
        data = json.loads(output.read_text())
        decisions = data.get('decisions', [])
        ids = [x.get('id') for x in decisions]
        if len(ids) != len(rows) or set(ids) != {x['id'] for x in rows}:
            raise ValueError('Model omitted, duplicated or invented IDs')
        for item in decisions:
            if item.get('decision') not in ('cleanup', 'keep', 'review') or not isinstance(item.get('reason'), str):
                raise ValueError('Invalid model decision')
            item['reason'] = item['reason'][:500]
        return {'model': resolved_model, 'decisions': decisions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['scan', 'review', 'apply', 'configure', 'watch'])
    parser.add_argument('--source', type=Path, action='append', default=[])
    parser.add_argument('--primary', choices=MODELS, default='luna')
    parser.add_argument('--reviewer', choices=MODELS, default='terra')
    parser.add_argument('--enable', action='store_true', help='Explicit opt-in for watch to permanently reclaim verified bundles')
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.geteuid() == 0:
        parser.error('macOS ordinary user required; no sudo')
    care = Care()
    try:
        if args.command == 'configure':
            sources = []
            for source in args.source:
                source = physical(source)
                if protected(source) or '/Desktop/development/sadame/' in str(source) + '/':
                    raise ValueError('Protected source')
                physical(source / 'public')
                if not (source / 'src/index.ts').is_file() or not (source / 'package.json').is_file():
                    raise ValueError('Expected retained Remotion project')
                sources.append(str(source))
            if not sources:
                raise ValueError('At least one retained source required')
            result = dict(sources=sources, primary=args.primary, reviewer=args.reviewer, enabled=args.enable)
            with care.locked():
                save(care.state / 'config.json', result)
        elif args.command == 'scan':
            with care.locked():
                result = care.scan()
        elif args.command == 'watch':
            result = care.cycle(apply=care.config()['enabled'])
            save(care.state / 'service-status.json', {'at': time.time(), 'ok': result.get('ai', {}).get('status') != 'unavailable',
                'removed_bytes': result.get('removed_bytes', 0), 'free_delta': result.get('free_delta'),
                'error': result.get('ai', {}).get('error')})
            # Periodic logs must not grow by dumping thousands of proof paths.
            print(json.dumps(load(care.state / 'service-status.json', {})))
            return
        else:
            result = care.cycle(apply=args.command == 'apply')
        # Proofs stay in private local state; terminal output is compact.
        if 'items' in result:
            result = {**result, 'items': [{k: v for k, v in r.items() if k != 'proof'} for r in result['items']]}
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        if args.command == 'watch':
            save(care.state / 'service-status.json', {'at': time.time(), 'ok': False, 'error': str(e)})
        parser.exit(1, str(e) + '\n')


if __name__ == '__main__':
    main()
