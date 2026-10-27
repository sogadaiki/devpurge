#!/usr/bin/env python3
"""Local storage observability. No dependencies, telemetry or privileged helper.

Scan != approval. Mutations require a short-lived server-side plan, tree identity
revalidation, activity checks and a durable write-ahead recovery journal.
"""
import argparse
import concurrent.futures
import ctypes
from collections import deque
import datetime as dt
import fcntl
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socketserver
import stat
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.parse
import webbrowser
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import job_recovery
import cleanup_assistant


def render_care_module():
    spec = importlib.util.spec_from_file_location('devpurge_render_care', ROOT / 'lib/render_care.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def care_state(home):
    root = home / 'Library/Application Support/devpurge/render-care'
    def read(name, default):
        p = root / name
        return json.loads(p.read_text()) if p.is_file() and not p.is_symlink() else default
    latest = read('latest.json', {})
    latest['items'] = [{k: v for k, v in row.items() if k != 'proof'} for row in latest.get('items', [])]
    return {'latest': latest, 'config': read('config.json', {}), 'review': read('review.json', {}),
            'receipt': read('last-receipt.json', {}), 'operation': read('operation.json', {}),
            'service': read('service-status.json', {}),
            'history': read('history.json', [])[-144:]}
PROTECTED = ['証拠', '裁判', '訴訟', '別訴', '告訴', '準備書面', '判決', '弁護士', '法務', '原本', '契約書']
GENERATED = {'node_modules': 'dependencies', '.next': 'build', '.open-next': 'build', '.venv': 'python', 'venv': 'python', '__pycache__': 'build'}
INTERMEDIATE = {'renders', 'render', 'tmp', 'temp', 'intermediates', 'proxy', 'proxies', 'exports', 'output', 'outputs'}
LABELS = {'cache': '再取得できるキャッシュ', 'python': 'Python・仮想環境', 'build': 'ビルド生成物', 'dependencies': 'プロジェクトの依存ライブラリ', 'worktree': 'AIの作業コピー', 'intermediate': '制作途中・出力候補', 'models': 'AIモデル', 'history': 'AIの会話・作業履歴', 'system': 'OSの一時領域', 'other': 'その他の保管データ'}


def command(argv, timeout=15):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env={**os.environ, 'LC_ALL': 'C'})
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return -1, '', str(e)


def atomic_json(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.' + secrets.token_hex(6) + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def inside(path, root):
    return path == root or root in path.parents


def deleted_open_files(output):
    """Aggregate lsof field output without paths; deduplicate open descriptors.

    File size is logical, not allocated/reclaimable APFS space. A shared inode
    appears once globally, but under every owner that would need to close it.
    """
    files, owners = {}, {}
    process, record = None, None
    incomplete = 0

    def finish():
        nonlocal incomplete
        if not record or record.get('t') != 'REG':
            return
        if not record.get('k', '').isdigit():
            incomplete += 1
            return
        if record['k'] != '0':
            return
        if process is None or not record.get('D') or not record.get('i', '').isdigit() or not record.get('s', '').isdigit():
            incomplete += 1
            return
        identity = (record['D'], record['i'])
        files[identity] = max(files.get(identity, 0), int(record['s']))
        owners[process]['files'].add(identity)

    for line in output.splitlines():
        if not line:
            continue
        field, value = line[0], line[1:]
        if field == 'p':
            finish()
            record = None
            process = int(value) if value.isdigit() else None
            if process is not None:
                owners.setdefault(process, {'pid': process, 'name': '不明なプロセス', 'files': set()})
        elif field == 'c' and process is not None:
            owners[process]['name'] = value[:120]
        elif field == 'f':
            finish()
            record = {}
        elif record is not None and field in ('t', 'k', 'D', 'i', 's'):
            record[field] = value
    finish()
    processes = [{'pid': p['pid'], 'name': p['name'], 'bytes': sum(files[k] for k in p['files']), 'files': len(p['files'])} for p in owners.values() if p['files']]
    return {'observed_bytes': sum(files.values()), 'file_count': len(files), 'incomplete': incomplete,
            'processes': sorted(processes, key=lambda p: p['bytes'], reverse=True)[:12]}


def process_footprint(pid):
    """Metadata only, including compressed memory; never inspect process memory.

    Darwin's public rusage_info_v0 ABI (sys/resource.h). Unknown is not zero.
    Physical footprint is a memory accounting measure, NOT reclaimable disk.
    """
    if sys.platform != 'darwin':
        return None
    class Usage(ctypes.Structure):
        _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(key, ctypes.c_uint64) for key in
            ('user', 'system', 'idle', 'interrupts', 'pageins', 'wired', 'resident', 'footprint', 'start', 'exit')]
    try:
        function = ctypes.CDLL('/usr/lib/libproc.dylib').proc_pid_rusage
        function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        function.restype = ctypes.c_int
        usage = Usage()
        return int(usage.footprint) if function(pid, 0, ctypes.byref(usage)) == 0 else None
    except (OSError, AttributeError):
        return None


def process_label(executable):
    """Explain known local Python environments from executable metadata only."""
    path = Path(executable)
    if path.name.lower().startswith('python'):
        if 'audio-studio-mcp' in path.parts:
            return 'Audio Studio（音生成） / Python'
        for marker in ('.venv', 'venv'):
            if marker in path.parts:
                index = path.parts.index(marker)
                if index > 1:
                    return path.parts[index-1] + ' / Python'
    return path.name


def swap_values(output, code=0):
    values = {}
    for field, key in [('used', 'swap_used'), ('total', 'swap_reserved')]:
        match = re.search(r'\b' + field + r'\s*=\s*([\d.]+)([MG])', output)
        values[key] = int(float(match[1]) * 1024 ** (2 if match[2] == 'M' else 3)) if code == 0 and match else None
    return values


def pressure_change(previous, current):
    """Compare overlapping gauges separately; never add them as savings."""
    if not previous:
        return None
    result = {'free_delta': current['free'] - previous['free'], 'reboot': bool(
        previous.get('boot_epoch') and current.get('boot_epoch') and previous['boot_epoch'] != current['boot_epoch'])}
    for key in ('swap_used', 'swap_reserved', 'vm_volume_bytes', 'deleted_open_bytes', 'temp_bytes'):
        a, b = previous.get(key), current.get(key)
        result[key + '_decrease'] = a - b if a is not None and b is not None else None
    return result


def temporary_storage():
    """Bounded metadata-only probes; no enumeration in the API and no cleanup.

    User T and /private/tmp are distinct. Other users' folders and protected OS
    caches remain outside coverage. Permission errors must not become zero.
    """
    code, path, _ = command(['/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR'], timeout=5)
    resolved = Path(path.strip()).resolve() if code == 0 and path.strip().startswith('/') else None
    user_temp = resolved if resolved and any(inside(resolved, Path(root)) for root in ('/private/var/folders', '/var/folders')) else None
    rows = []
    for name, target in [('user_temp', user_temp), ('shared_temp', Path('/private/tmp'))]:
        if target is None:
            rows.append({'name': name, 'bytes': None, 'observed_bytes': None, 'status': 'unknown'})
            continue
        code, out, error = command(['/usr/bin/du', '-sk', str(target)], timeout=5)
        fields = out.strip().split(None, 1)
        observed = int(fields[0])*1024 if fields and fields[0].isdigit() else None
        valid = code == 0 and not error.strip() and observed is not None
        rows.append({'name': name, 'bytes': observed if valid else None, 'observed_bytes': observed,
                     'status': 'observed' if valid else 'partial' if observed is not None else 'unknown'})
    return {'bytes': sum(r['bytes'] for r in rows) if all(r['bytes'] is not None for r in rows) else None,
            'regions': rows}


class Studio:
    def __init__(self, home=None, state=None):
        self.home = Path(home or Path.home()).resolve()
        self.state = Path(state or self.home / 'Library/Application Support/devpurge/studio')
        self.lock = threading.Lock()
        self.result = None
        self.progress = {'running': False, 'message': 'まだスキャンしていません', 'done': 0, 'total': 0}
        self.plans = {}
        self.browsed = {}
        self.assistant_owner = secrets.token_hex(16)
        self.protected = list(PROTECTED)
        self.excluded = [self.home / 'Desktop/development/sadame']
        rc = self.home / '.devpurgerc'
        if rc.is_file() and not rc.is_symlink():
            for line in rc.read_text().splitlines():
                key, sep, value = line.partition('=')
                if sep and key.strip() == 'protect' and value.strip():
                    self.protected.append(value.strip())
                if sep and key.strip() in ('exclude', 'archive_root') and value.strip():
                    self.excluded.append(Path(value.strip().replace('~', str(self.home), 1)).absolute())

    def blocked(self, path):
        text = unicodedata.normalize('NFC', str(path))
        return any(p in text for p in self.protected) or any(inside(path, p) for p in self.excluded) or any(p.startswith('.env') or p in ('.git', '.devpurge-keep', '.ssh', '.aws', 'Keychains', 'auth.json', '.npmrc', '.pypirc', '.netrc', 'credentials.json') for p in path.parts)

    def physical(self, path):
        path = Path(path)
        if not path.is_absolute() or path != path.resolve() or self.blocked(path):
            raise ValueError('リンク・保護対象・除外パスは操作できません')
        return path

    def targets(self):
        # Fixed, explainable paths; no broad scan of private application data.
        specs = [
            ('.cache/uv', 'python', 'uvの共有キャッシュ', 'uv公式のpruneで整理します。環境本体は保持します。', 'uv'),
            ('Library/Caches/uv', 'python', 'uvの共有キャッシュ（macOS）', 'uv公式のpruneで整理します。', 'review'),
            ('Library/Caches/pip', 'cache', 'pipのダウンロードキャッシュ', '再インストール時に再ダウンロードします。', 'trash'),
            ('.cache/pip', 'cache', 'pipの共有キャッシュ', '再インストール時に再ダウンロードします。', 'trash'),
            ('.npm/_cacache', 'cache', 'npmのダウンロードキャッシュ', '依存ライブラリ本体は残ります。次回取得時に通信します。', 'trash'),
            ('.npm/_npx', 'cache', 'npxの実行環境', 'MCPや開発ツールが使う環境の可能性があります。', 'review'),
            ('Library/Caches/Homebrew', 'cache', 'Homebrewのダウンロード', 'インストール済みアプリは残ります。再取得に通信します。', 'trash'),
            ('Library/Caches/Google/Chrome', 'cache', 'Chromeの表示キャッシュ', 'Chrome終了後に確認してください。ログイン保存領域は対象外です。', 'review'),
            ('Library/Caches/pypoetry', 'python', 'Poetryの環境・キャッシュ', '仮想環境が含まれるため自動整理しません。', 'review'),
            ('.local/share/uv', 'python', 'uvのPython・ツール本体', '実行環境です。キャッシュとは分けて保持します。', 'review'),
            ('.pyenv', 'python', 'Pythonのバージョン管理', 'プロジェクトが参照している可能性があります。', 'review'),
            ('.cache/huggingface', 'models', 'Hugging Faceモデル', '再ダウンロードの容量・時間が必要です。', 'review'),
            ('.ollama/models', 'models', 'Ollamaモデル', 'モデルを使う作業への影響を確認してください。', 'review'),
            ('.cache/whisper', 'models', 'Whisperモデル', '文字起こしで使うモデルです。', 'review'),
            ('.codex/worktrees', 'worktree', 'Codexの作業コピー', '未統合のコード・設定・素材を含み得ます。Git経由で個別確認が必要です。', 'review'),
            ('.claude/projects', 'history', 'Claudeの作業履歴', '会話・作業の復元に使う履歴です。内容は読みません。', 'review'),
            ('.codex/sessions', 'history', 'Codexの作業履歴', '会話・作業の復元に使う履歴です。内容は読みません。', 'review'),
            ('.codex/archived_sessions', 'history', 'Codexのアーカイブ済み履歴', 'アーカイブは削除ではありません。過去の作業を復元する履歴として保持します。', 'review'),
            ('.codex/visualizations', 'intermediate', 'Codexの制作・表示ファイル', 'プレビューだけでなく成果物の正本を含む可能性があります。納品先・再制作元を確認してください。', 'review'),
            ('.codex/generated_images', 'intermediate', 'Codexの生成画像', '生成画像そのものです。別の保持先が確認できるまで削除しません。', 'review'),
            ('Library/Application Support/Adobe/Common/Media Cache Files', 'cache', 'Adobeのメディアキャッシュ', '編集アプリを終了後、専用画面からの整理も可能です。', 'review'),
            ('Desktop/01_完成品', 'other', '完成品', '制作物の正本として保持します。', 'review'),
            ('.Trash', 'other', 'ゴミ箱', '移動だけでは空き容量は増えません。完全削除はFinderで確認してください。', 'review'),
        ]
        return [(self.home / p, cat, title, reason, action) for p, cat, title, reason, action in specs]

    def discover(self):
        found = self.targets()
        base = self.home / 'Desktop/development'
        # Bounded name-only discovery; never enter secrets, Git or generated roots.
        count = 0
        limited = False
        queue = deque([(base, 0)])
        while queue and count < 6000:
            root, depth = queue.popleft()
            if depth > 4 or self.blocked(root) or root.is_symlink():
                continue
            try:
                with os.scandir(root) as iterator:
                    entries = []
                    for n, entry in enumerate(iterator):
                        if n >= 15000:
                            limited = True
                            break
                        if entry.is_dir(follow_symlinks=False):
                            entries.append(Path(entry.path))
            except OSError:
                continue
            for p in sorted(entries):
                count += 1
                if count > 6000:
                    limited = True
                    break
                if p.is_symlink() or self.blocked(p) or not p.is_dir():
                    continue
                if p.name in GENERATED or p.name.lower() in INTERMEDIATE:
                    cat = GENERATED.get(p.name, 'intermediate')
                    reason = '完成品の存在だけでは不要と判断できません。残す正本と再制作の必要性を確認してください。'
                    if cat == 'python':
                        reason = 'プロジェクト専用のPython環境です。消すと再構築が必要なため保持します。'
                    elif cat in ('build', 'dependencies'):
                        reason = '再生成候補です。稼働中・復元用設定・未保存データの確認が必要です。'
                    found.append((p, cat, p.parent.name + ' / ' + p.name, reason, 'review'))
                elif not p.name.startswith('.') and p.name not in ('assets', 'images', 'screenshots', 'vendor', 'target', 'dist'):
                    queue.append((p, depth + 1))
        code, out, _ = command(['getconf', 'DARWIN_USER_TEMP_DIR'])
        if code == 0 and out.strip():
            temp = Path(out.strip()).resolve()
            # Report the whole user temp region once. Child details avoid double counting.
            found.append((temp, 'system', 'このユーザーの一時ファイル', 'Pythonの展開・ビルド残骸などを含みます。OSや実行中アプリのデータもあるため一括削除しません。', 'review'))
            self.temp = temp
        self.discovery_limited = limited or bool(queue)
        return found

    def measure(self, spec):
        p, cat, title, reason, action = spec
        if self.blocked(p) or p.is_symlink():
            return None
        try:
            p.lstat()
        except FileNotFoundError:
            return None
        except OSError:
            return {'id': hashlib.sha256(str(p).encode()).hexdigest()[:16], 'path': str(p), 'category': cat, 'title': title, 'reason': reason, 'action': 'review', 'bytes': None, 'status': 'permission', 'error': 'アクセス権限のため未計測'}
        code, out, err = command(['du', '-sk', str(p)], timeout=25)
        observed = None
        try:
            observed = int(out.split()[0]) * 1024
        except (ValueError, IndexError):
            pass
        size = observed if code == 0 else None
        result = {'id': hashlib.sha256(str(p).encode()).hexdigest()[:16], 'path': str(p), 'category': cat, 'title': title, 'reason': reason, 'action': action if size is not None else 'review', 'bytes': size, 'observed_bytes': observed, 'status': 'measured' if size is not None else 'partial', 'error': '' if size is not None else '権限不足または25秒の計測上限。全体の容量は不明です。'}
        if cat == 'system':
            result['breakdown'] = self.temp_breakdown(p)
        return result

    def temp_breakdown(self, root):
        groups = {}
        try:
            with os.scandir(root) as entries:
                for index, e in enumerate(entries):
                    if index > 30000:
                        break
                    if not e.is_dir(follow_symlinks=False):
                        continue
                    group = 'Pythonの展開・ビルド候補' if e.name.startswith(('pip-', 'uv-')) else None
                    if group:
                        groups.setdefault(group, []).append(e.path)
        except OSError:
            return [{'title': '一時領域', 'bytes': None, 'count': None, 'partial': True}]
        result = []
        for title, paths in groups.items():
            size = 0
            partial = False
            started = time.monotonic()
            for offset in range(0, len(paths), 100):
                if time.monotonic() - started > 35:
                    partial = True
                    break
                code, out, _ = command(['du', '-sk'] + paths[offset:offset+100], timeout=10)
                partial |= code != 0
                for line in out.splitlines():
                    first = line.split('\t', 1)[0]
                    if first.isdigit():
                        size += int(first) * 1024
            result.append({'title': title, 'bytes': size, 'count': len(paths), 'partial': partial})
        return result

    def system(self):
        usage = shutil.disk_usage(self.home)
        code, swap, _ = command(['sysctl', 'vm.swapusage'])
        _, uptime, _ = command(['uptime'])
        scode, snapshots, _ = command(['tmutil', 'listlocalsnapshots', '/'])
        pcode, processes, _ = command(['ps', '-axo', 'pid=,ppid=,rss=,comm='])
        rcode, ram, _ = command(['sysctl', '-n', 'hw.memsize'])
        bcode, boot, _ = command(['sysctl', 'kern.boottime'])
        boot_match = re.search(r'\bsec\s*=\s*(\d+)', boot)
        vcode, volume, _ = command(['/bin/df', '-k', '/System/Volumes/VM'])
        fields = volume.splitlines()[-1].split() if volume.strip() else []
        vm_bytes = int(fields[2]) * 1024 if vcode == 0 and len(fields) >= 6 and fields[2].isdigit() and fields[-1] == '/System/Volumes/VM' else None
        top = []
        for line in processes.splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) == 4 and all(p.isdigit() for p in parts[:3]) and len(top) < 2000:
                pid = int(parts[0])
                top.append({'pid': pid, 'parent': int(parts[1]), 'bytes': int(parts[2]) * 1024,
                            'footprint': process_footprint(pid), 'name': process_label(parts[3])})
        return {'total': usage.total, 'free': usage.free, 'used': usage.used,
                **swap_values(swap, code), 'vm_volume_bytes': vm_bytes,
                'ram': int(ram.strip()) if rcode == 0 and ram.strip().isdigit() else None,
                'boot_epoch': int(boot_match[1]) if bcode == 0 and boot_match else None,
                'uptime': uptime.strip(), 'snapshots': snapshots.strip() if scode == 0 else None,
                'processes': sorted(top, key=lambda p: p['footprint'] if p['footprint'] is not None else p['bytes'], reverse=True)[:20],
                'process_tree': top,
                'process_status': 'ok' if pcode == 0 else 'unknown'}

    def pressure(self):
        """Quick read-only diagnosis, independent of the full folder scan."""
        with self.lock:
            system = self.system()
            temporary = temporary_storage()
            # No file names, command arguments, contents, sudo, or process control.
            code, output, error = command(['/usr/sbin/lsof', '-nP', '+L1', '-F', 'pcftsiDk'], timeout=15)
            opened = deleted_open_files(output)
            valid = code in (0, 1) and not error.strip() and not opened['incomplete']
            opened['status'] = 'observed' if valid else 'partial' if output else 'unknown'
            opened['bytes'] = opened['observed_bytes'] if valid else None
            history = self.load('pressure-history.json', [])
            previous = history[-1] if history else None
            at = dt.datetime.now(dt.timezone.utc).isoformat()
            sample = {'at': at, 'free': system['free'], 'swap_used': system['swap_used'],
                      'swap_reserved': system.get('swap_reserved'), 'vm_volume_bytes': system.get('vm_volume_bytes'),
                      'temp_bytes': temporary['bytes'], 'temp_regions': temporary['regions'],
                      'boot_epoch': system['boot_epoch'], 'deleted_open_bytes': opened['bytes'],
                      'top_memory': [{k: p.get(k) for k in ('pid', 'name', 'footprint')} for p in system.get('processes', [])[:5]]}
            result = {'at': at, 'system': system, 'deleted_open': opened, 'temporary': temporary, 'previous': previous,
                      'comparison': pressure_change(previous, sample),
                      'free_delta': system['free'] - previous['free'] if previous else None,
                      'boot_changed': bool(previous and previous.get('boot_epoch') and system['boot_epoch'] and previous['boot_epoch'] != system['boot_epoch'])}
            atomic_json(self.state / 'pressure-history.json', (history + [sample])[-2048:])
            atomic_json(self.state / 'pressure.json', result)
            return result

    def landscape(self):
        """A separate non-additive inventory explains data beyond cache candidates."""
        specs = []
        bases = [(self.home/'Desktop/development', 'プロジェクト全体'),
                 (self.home/'Library/Application Support', 'アプリの保存データ'),
                 (self.home/'Desktop', 'デスクトップ')]
        for base, kind in bases:
            try:
                for p in sorted(base.iterdir())[:250]:
                    if p.is_symlink() or self.blocked(p) or p.name.startswith('.') or (base.name=='Desktop' and p.name=='development'):
                        continue
                    specs.append((p, 'other', p.name, kind, 'review'))
            except OSError:
                pass
        for relative in ('Downloads', 'Movies', 'Documents', '.cache', '.codex', '.claude'):
            specs.append((self.home/relative, 'other', relative, 'ユーザーの保存領域', 'review'))
        results = []
        self.progress.update(message='プロジェクト・アプリの保存量を計測中', done=0, total=len(specs), phase='landscape')
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            jobs = [pool.submit(self.measure, s) for s in specs]
            for job in concurrent.futures.as_completed(jobs):
                item = job.result()
                if item:
                    results.append(item)
                self.progress['done'] += 1
                self.progress['message'] = 'プロジェクト・アプリの保存量を計測中'
        return sorted(results, key=lambda i: i['bytes'] or i.get('observed_bytes') or 0, reverse=True)

    def scan(self):
        if not self.lock.acquire(blocking=False):
            raise ValueError('別のスキャンまたは整理が進行中です')
        try:
            self.progress = {'running': True, 'message': '対象を探しています', 'done': 0, 'total': 0}
            specs = self.discover()
            self.progress['total'] = len(specs)
            items = []
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                jobs = {pool.submit(self.measure, s): s for s in specs}
                for job in concurrent.futures.as_completed(jobs):
                    item = job.result()
                    if item:
                        items.append(item)
                    self.progress['done'] += 1
                    self.progress['message'] = jobs[job][2]
            # Suppress nested paths in totals. Individual category sizes are not free-space promises.
            kept = []
            for item in sorted(items, key=lambda i: len(Path(i['path']).parts)):
                if not any(inside(Path(item['path']), Path(parent['path'])) for parent in kept):
                    kept.append(item)
            previous = self.load('latest.json', {})
            old = {i['id']: i for i in previous.get('items', [])}
            for i in kept:
                prior = old.get(i['id'], {}).get('bytes')
                i['delta'] = i['bytes'] - prior if i['bytes'] is not None and prior is not None else None
            landscape = self.landscape()
            self.result = {'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'items': sorted(kept, key=lambda i: i['bytes'] or 0, reverse=True), 'landscape': landscape, 'system': self.system(), 'finals': self.final_suggestions(), 'previous_at': previous.get('at'), 'discovery_limited': self.discovery_limited,
                           'scope': '既知のAI・開発キャッシュ、development配下4階層、作業コピー、ユーザー一時領域。全ディスクの網羅調査ではありません。'}
            atomic_json(self.state / 'latest.json', self.result)
            history = self.load('history.json', [])
            history.append({'at': self.result['at'], 'free': self.result['system']['free'], 'swap_used': self.result['system']['swap_used'], 'measured': sum(i['bytes'] or 0 for i in kept)})
            atomic_json(self.state / 'history.json', history[-90:])
            self.record_daily_scan(self.result['at'])
            return self.result
        finally:
            self.progress['running'] = False
            self.lock.release()

    def load(self, name, fallback):
        try:
            return json.loads((self.state / name).read_text())
        except (OSError, ValueError):
            return fallback

    def daily(self):
        today = dt.datetime.now().astimezone().date().isoformat()
        days = self.load('daily.json', [])
        return {'today': today, 'days': days, 'completed_days': sum(bool(d.get('completed_at')) for d in days), 'current': next((d for d in days if d['day'] == today), None)}

    def record_daily_scan(self, at):
        daily = self.daily()
        days = daily['days']
        current = daily['current']
        if current is None:
            current = {'day': daily['today']}
            days.append(current)
        current['scan_at'] = at
        atomic_json(self.state / 'daily.json', days)

    def finish_daily(self, data):
        with self.lock:
            daily = self.daily()
            current = daily['current']
            if not current or not current.get('scan_at'):
                raise ValueError('まず今日のスキャンを完了してください')
            if data.get('decision') not in ('keep', 'reviewed', 'organized', 'refreshed'):
                raise ValueError('今日の判断を選んでください')
            if data['decision'] == 'keep':
                result = self.result or self.load('latest.json', {})
                if data.get('id') not in {i['id'] for i in result.get('items', [])}:
                    raise ValueError('確認した項目が見つかりません')
            if data['decision'] in ('organized', 'refreshed'):
                receipts = self.receipts() if data['decision'] == 'organized' else [json.loads(p.read_text()) for p in (self.state / 'refresh').glob('refresh-*.json')]
                receipt = next((r for r in receipts if r['id'] == data.get('id')), None)
                required = 'moved' if data['decision'] == 'organized' else 'completed'
                if not receipt or receipt.get('status') != required or dt.datetime.fromisoformat(receipt['at']).astimezone().date().isoformat() != daily['today']:
                    raise ValueError('今日完了した整理の記録を確認できません')
            # One stamp per day, never per byte removed or repeated click.
            if not current.get('completed_at'):
                current.update(completed_at=dt.datetime.now(dt.timezone.utc).isoformat(), decision=data['decision'], item_id=data.get('id'))
                atomic_json(self.state / 'daily.json', daily['days'])
            return self.daily()

    def keeper_hash(self, path):
        path = self.physical(Path(path))
        if path.suffix.lower() in ('.pem', '.key', '.p12', '.pfx') or path.name in ('.npmrc', '.pypirc', '.netrc', 'auth.json') or re.search(r'(credential|secret|token|api[_-]?key)', path.name, re.I):
            raise ValueError('認証情報の可能性があるファイルは読みません')
        if not inside(path, self.home) or not path.is_file():
            raise ValueError('保持する完成品はホーム内の通常ファイルを指定してください')
        digest = hashlib.sha256()
        before = path.stat()
        started = time.monotonic()
        with path.open('rb') as f:
            for chunk in iter(lambda: f.read(4 * 1024 * 1024), b''):
                digest.update(chunk)
                if time.monotonic() - started > 120:
                    raise ValueError('完成品の検証が120秒を超えました。今回は保持します')
        after = path.stat()
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError('検証中に完成品が変更されました')
        return {'path': str(path), 'sha256': digest.hexdigest(), 'bytes': after.st_size}

    def complete(self, data):
        """Explicit user declaration; a filename such as final.mp4 proves nothing."""
        with self.lock:
            title = str(data.get('title', '')).strip()[:120]
            if not title or data.get('acknowledged') is not True:
                raise ValueError('再編集に必要な原本を保持したことを確認してください')
            paths = data.get('keepers', [])
            intermediates = data.get('intermediates', [])
            if not isinstance(paths, list) or not 1 <= len(paths) <= 10 or not isinstance(intermediates, list) or not 1 <= len(intermediates) <= 20:
                raise ValueError('完成品1〜10個、中間フォルダ1〜20個を指定してください')
            keepers = [self.keeper_hash(p) for p in paths]
            candidates = []
            for raw in intermediates:
                p = self.physical(Path(raw))
                if not inside(p, self.home / 'Desktop/development') or p.name.lower() not in INTERMEDIATE or not p.is_dir():
                    raise ValueError('中間フォルダはdevelopment内のrenders / tmp / output等を指定してください')
                if any(inside(Path(k['path']), p) for k in keepers):
                    raise ValueError('残す完成品が中間フォルダの中にあります。先に正本を別の場所へ保持してください')
                tree = self.tree(p)
                candidates.append({'path': str(p), 'bytes': tree['bytes']})
            record = {'id': secrets.token_hex(8), 'title': title, 'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'keepers': keepers, 'intermediates': candidates}
            records = self.load('completions.json', [])
            records.append(record)
            atomic_json(self.state / 'completions.json', records)
            return record

    def completion_plan(self, id_):
        with self.lock:
            record = next((r for r in self.load('completions.json', []) if r['id'] == id_), None)
            if not record:
                raise ValueError('制作完了記録が見つかりません')
            for keeper in record['keepers']:
                if self.keeper_hash(keeper['path']) != keeper:
                    raise ValueError('完成品が変更・移動されています。整理せず再確認してください')
            entries = []
            for item in record['intermediates']:
                p = Path(item['path'])
                tree = self.tree(p)
                self.idle(p, tree['newest'])
                if any(inside(p, Path(e['path'])) or inside(Path(e['path']), p) for e in entries):
                    raise ValueError('対象フォルダが重なっています')
                entries.append({**item, 'title': p.name, 'tree': tree})
            key = secrets.token_urlsafe(24)
            plan = {'id': key, 'created': time.time(), 'entries': entries, 'keepers': record['keepers'], 'bytes': sum(i['tree']['bytes'] for i in entries), 'effect': '完成品のSHA-256を再確認して、中間フォルダをゴミ箱へ移動します。再編集用の素材はご自身の確認に基づきます。'}
            self.plans[key] = plan
            return plan

    def refresh_plan(self):
        with self.lock:
            executable = shutil.which('uv')
            if not executable:
                raise ValueError('uvが見つかりません。インストールは自動で行いません')
            path = self.physical(self.home / '.cache/uv')
            tree = self.tree(path, uv_cache=True)
            self.idle(path, tree['newest'])
            key = secrets.token_urlsafe(24)
            plan = {'id': key, 'created': time.time(), 'kind': 'uv-prune', 'executable': executable,
                    'entries': [{'path': str(path), 'title': 'uvの未使用キャッシュ', 'tree': tree}], 'bytes': None,
                    'effect': 'uv公式の cache prune を実行します。未使用キャッシュは完全削除され、ゴミ箱から戻せません。必要時に再取得・再構築します。削除量は実行前には分かりません。'}
            self.plans[key] = plan
            return plan

    def tree(self, path, uv_cache=False):
        """Metadata fingerprint, never file contents. Fail closed on unknowns."""
        self.physical(path)
        if uv_cache and (path != self.home / '.cache/uv' or not path.is_dir()):
            raise ValueError('uvの既定キャッシュ以外は操作できません')
        digest = hashlib.sha256()
        newest = 0
        size = 0
        count = 0
        start = time.monotonic()
        stack = [path]
        while stack:
            p = stack.pop()
            if self.blocked(p):
                raise ValueError('保護ファイルを含むため保持します')
            s = p.lstat()
            link = stat.S_ISLNK(s.st_mode)
            # Only the official uv command may handle cache links. uv's build
            # environments also link to retained Python executables. These
            # references are inspected without traversing/moving the target.
            if link and uv_cache:
                try:
                    target = p.resolve()
                except (OSError, RuntimeError) as e:
                    raise ValueError('リンク先を確認できないため保持します') from e
                python_roots = (self.home / '.local/share/uv/python', Path('/Library/Frameworks/Python.framework/Versions'))
                retained_python = (p.parent.name == 'bin' and re.fullmatch(r'python(?:\d+(?:\.\d+)?)?', p.name)
                                  and any(inside(target, root) for root in python_roots)
                                  and target.parent.name == 'bin' and re.fullmatch(r'python\d+\.\d+', target.name)
                                  and target.is_file())
                if (not inside(target, path) and not retained_python) or self.blocked(target):
                    raise ValueError('キャッシュ外へのリンクを含むため保持します')
            elif link or not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)):
                raise ValueError('リンクまたは特殊ファイルを含むため保持します')
            count += 1
            if count > 250000 or time.monotonic() - start > 25:
                raise ValueError('検証量の上限を超えたため保持します')
            newest = max(newest, s.st_mtime)
            size += s.st_blocks * 512
            digest.update(json.dumps([str(p.relative_to(path)), s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode]).encode())
            if stat.S_ISDIR(s.st_mode):
                stack.extend(sorted(p.iterdir(), reverse=True))
        return {'fingerprint': digest.hexdigest(), 'bytes': size, 'newest': newest, 'count': count, 'inode': path.stat().st_ino}

    def idle(self, path, newest):
        if time.time() - newest < 86400:
            raise ValueError('24時間以内に変更があります。今は保持します')
        code, out, err = command(['/usr/sbin/lsof', '-nP', '+D', str(path)], timeout=20)
        if code != 1 or out.strip() or err.strip():
            raise ValueError('使用中、または使用状態を確実に確認できません。関連アプリを終了して再確認してください')
        # lsof misses future accesses by installers; block known package managers as well.
        code, out, _ = command(['ps', '-axo', 'comm='])
        if code != 0:
            raise ValueError('プロセス確認に失敗しました')
        if any(re.search(r'(^|/)(pip[\d.]*|uv|npm|brew)$', line.strip()) for line in out.splitlines()):
            raise ValueError('パッケージ管理ツールが実行中です。処理が終わってから整理してください')

    def plan(self, ids):
        with self.lock:
            if not isinstance(ids, list) or not ids or len(ids) > 20 or len(set(ids)) != len(ids):
                raise ValueError('1〜20項目を重複なく選択してください')
            items = {i['id']: i for i in (self.result or self.load('latest.json', {})).get('items', [])}
            allowed = {str(p): action for p, _, _, _, action in self.targets()}
            entries = []
            for id_ in ids:
                i = items.get(id_)
                if not i or i['action'] != 'trash' or allowed.get(i['path']) != 'trash':
                    raise ValueError('この項目は個別確認が必要で、整理操作の対象外です')
                p = self.physical(Path(i['path']))
                tree = self.tree(p)
                self.idle(p, tree['newest'])
                entries.append({**i, 'tree': tree})
            key = secrets.token_urlsafe(24)
            plan = {'id': key, 'created': time.time(), 'entries': entries, 'bytes': sum(i['tree']['bytes'] for i in entries), 'effect': 'ゴミ箱へ移動します。空き容量は増えません。元に戻す操作を用意します。'}
            self.plans[key] = plan
            return plan

    def apply(self, key):
        with self.lock:
            plan = self.plans.pop(key, None)
            if not plan or time.time() - plan['created'] > 300:
                raise ValueError('確認の有効期限が切れました。もう一度確認してください')
            for keeper in plan.get('keepers', []):
                if self.keeper_hash(keeper['path']) != keeper:
                    raise ValueError('完成品が変わったため整理を中止しました')
            for i in plan['entries']:
                p = Path(i['path'])
                if self.tree(p, uv_cache=plan.get('kind') == 'uv-prune') != i['tree']:
                    raise ValueError('確認後にファイルが変わりました。再スキャンしてください')
                self.idle(p, i['tree']['newest'])
            if plan.get('kind') == 'uv-prune':
                batch = 'refresh-' + time.strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(4)
                log = self.state / 'refresh' / (batch + '.json')
                receipt = {'id': batch, 'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'status': 'started', 'free_before': shutil.disk_usage(self.home).free, 'path': plan['entries'][0]['path']}
                atomic_json(log, receipt)
                code, out, err = command([plan['executable'], 'cache', 'prune', '--cache-dir', receipt['path'], '--offline', '--no-config', '--no-progress'], timeout=120)
                receipt.update(status='completed' if code == 0 else 'failed-or-partial', exit_code=code, output=(out+err)[-5000:], free_after=shutil.disk_usage(self.home).free)
                atomic_json(log, receipt)
                return receipt
            trash = self.home / '.Trash'
            trash.mkdir(mode=0o700, exist_ok=True)
            self.physical(trash)
            batch = 'studio-' + time.strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(4)
            destination = trash / batch
            destination.mkdir(mode=0o700)
            receipt = {'id': batch, 'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'entries': [], 'status': 'moving', 'free_before': shutil.disk_usage(self.home).free}
            log = self.state / 'receipts' / (batch + '.json')
            atomic_json(log, receipt)
            try:
                for n, i in enumerate(plan['entries']):
                    source = Path(i['path'])
                    self.physical(source)
                    if self.tree(source) != i['tree']:
                        raise ValueError('移動直前に内容が変わりました')
                    dest = destination / (str(n) + '-' + source.name)
                    if source.stat().st_dev != destination.stat().st_dev:
                        raise ValueError('別ボリュームへの移動は行いません')
                    entry = {'source': str(source), 'destination': str(dest), 'inode': source.stat().st_ino, 'bytes': i['tree']['bytes'], 'status': 'prepared'}
                    receipt['entries'].append(entry)
                    atomic_json(log, receipt)
                    os.rename(source, dest)
                    entry['status'] = 'moved'
                    atomic_json(log, receipt)
                receipt['status'] = 'moved'
            except (OSError, ValueError) as e:
                receipt['status'] = 'partial'
                receipt['error'] = str(e)
            receipt['free_after'] = shutil.disk_usage(self.home).free
            atomic_json(log, receipt)
            return receipt

    def receipts(self):
        folder = self.state / 'receipts'
        return [json.loads(p.read_text()) for p in sorted(folder.glob('studio-*.json'), reverse=True)][:50]

    def final_suggestions(self):
        root = self.home / 'Desktop/01_完成品'
        queue = deque([(root, 0)])
        files = []
        count = 0
        extensions = {'.mp4', '.mov', '.webm', '.pdf', '.pptx', '.docx', '.xlsx', '.png', '.jpg', '.wav', '.mp3', '.prproj'}
        while queue and count < 1000 and len(files) < 100:
            folder, depth = queue.popleft()
            if folder.is_symlink() or self.blocked(folder):
                continue
            try:
                for p in sorted(folder.iterdir()):
                    count += 1
                    if count > 1000 or len(files) >= 100:
                        break
                    if p.is_symlink() or self.blocked(p):
                        continue
                    if p.is_dir() and depth < 3:
                        queue.append((p, depth + 1))
                    elif p.is_file() and p.suffix.lower() in extensions:
                        files.append({'path': str(p), 'name': str(p.relative_to(root))})
            except OSError:
                continue
        return files

    def reveal(self, id_):
        result = self.result or self.load('latest.json', {})
        item = self.browsed.get(id_) or next((i for i in result.get('items', []) + result.get('landscape', []) if i['id'] == id_), None)
        if not item or self.blocked(Path(item['path'])):
            raise ValueError('表示対象が見つかりません')
        code, _, _ = command(['/usr/bin/open', '-R', item['path']])
        if code:
            raise ValueError('Finderで開けませんでした')
        return {'revealed': True}

    def browse(self, id_):
        result = self.result or self.load('latest.json', {})
        item = self.browsed.get(id_) or next((i for i in result.get('items', []) + result.get('landscape', []) if i['id'] == id_), None)
        if not item:
            raise ValueError('計測済みの保管場所を選択してください')
        root = self.physical(Path(item['path']))
        if not root.is_dir():
            raise ValueError('ファイルです。Finderで表示してください')
        specs = []
        limited = False
        with os.scandir(root) as entries:
            for e in entries:
                p = Path(e.path)
                if e.is_symlink() or self.blocked(p):
                    continue
                if len(specs) >= 100:
                    limited = True
                    break
                specs.append((p, 'other', p.name, '保管場所の内訳。サイズだけでは不要と判断しません。', 'review'))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            items = [i for i in pool.map(self.measure, specs) if i]
        items.sort(key=lambda i: i['bytes'] or i.get('observed_bytes') or 0, reverse=True)
        if len(self.browsed) > 2000:
            self.browsed.clear()
        self.browsed.update({i['id']: i for i in items})
        return {'parent': item, 'items': items, 'limited': limited}

    def restore(self, id_):
        if not re.fullmatch(r'studio-[\d-]+-[a-f0-9]{8}', id_):
            raise ValueError('不正な復元IDです')
        with self.lock:
            log = self.state / 'receipts' / (id_ + '.json')
            receipt = json.loads(log.read_text())
            for entry in receipt['entries']:
                if entry['status'] == 'restored':
                    continue
                source, dest = Path(entry['source']), Path(entry['destination'])
                self.physical(source.parent)
                self.physical(dest)
                if self.blocked(source) or not inside(source, self.home) or not inside(dest, self.home / '.Trash' / id_):
                    raise ValueError('復元先を検証できません')
                if source.exists() or source.is_symlink():
                    raise ValueError('元の場所に新しいデータがあります。上書きせず保持します')
                if dest.stat().st_ino != entry['inode']:
                    raise ValueError('ゴミ箱内のデータが入れ替わっています')
                os.rename(dest, source)
                entry['status'] = 'restored'
                atomic_json(log, receipt)
            receipt['status'] = 'restored'
            atomic_json(log, receipt)
            return receipt


class Server(http.server.ThreadingHTTPServer):
    # Closing the native window must let already accepted operations finish.
    daemon_threads = False

    def __init__(self, *args, **kwargs):
        self.closing = threading.Event()
        self.scan_thread = None
        super().__init__(*args, **kwargs)

    def server_bind(self):
        # HTTPServer normally reverse-resolves even a numeric loopback address.
        # This local-only service must start without a DNS/network dependency.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def stop_after_input(self, stream):
        try:
            stream.read()
        finally:
            self.closing.set()
            self.shutdown()

    def server_close(self):
        super().server_close()  # joins active HTTP operations, including moves
        if self.scan_thread:
            self.scan_thread.join()


def handler(studio, token):
    class Handler(http.server.BaseHTTPRequestHandler):
        timeout = 15

        def log_message(self, *_):
            pass  # no paths/tokens in access logs

        def send(self, code, data, kind='application/json'):
            payload = json.dumps(data, ensure_ascii=False).encode() if kind == 'application/json' else data
            self.send_response(code)
            self.send_header('Content-Type', kind + ('; charset=utf-8' if kind.startswith('text/') or kind == 'application/json' else ''))
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(payload)

        def authorized(self):
            host = '127.0.0.1:' + str(self.server.server_port)
            if self.headers.get('Host') != host:
                return False
            origin = self.headers.get('Origin')
            return (not origin or origin == 'http://' + host) and secrets.compare_digest(self.headers.get('X-Studio-Token', ''), token)

        def do_GET(self):
            host = '127.0.0.1:' + str(self.server.server_port)
            if self.headers.get('Host') != host:
                return self.send(403, {'error': 'ローカルアクセスのみ許可します'})
            path = urllib.parse.urlsplit(self.path).path
            assets = {'/': ('index.html', 'text/html'), '/app.js': ('app.js', 'text/javascript'), '/style.css': ('style.css', 'text/css'), '/daily.js': ('daily.js', 'text/javascript'), '/daily.css': ('daily.css', 'text/css'), '/assets/companion.png': ('assets/companion.png', 'image/png')}
            assets.update({'/refresh.js': ('refresh.js', 'text/javascript'), '/refresh.css': ('refresh.css', 'text/css')})
            assets['/care.js'] = ('care.js', 'text/javascript')
            assets['/assistant.js'] = ('assistant.js', 'text/javascript')
            assets['/assistant.css'] = ('assistant.css', 'text/css')
            if path in assets:
                name, kind = assets[path]
                return self.send(200, (ROOT / 'ui' / name).read_bytes(), kind)
            if not self.authorized():
                return self.send(403, {'error': '起動時のURLから開いてください'})
            if path == '/api/health':
                return self.send(200, {'app': 'devpurge-studio', 'protocol': 1, 'closing': self.server.closing.is_set()})
            if path == '/api/render-care':
                return self.send(200, care_state(studio.home))
            if path == '/api/job-recovery':
                return self.send(200, job_recovery.Recovery(studio.home).status())
            if path == '/api/assistant':
                return self.send(200, cleanup_assistant.Assistant(studio).status())
            if path == '/api/state':
                refresh = [json.loads(p.read_text()) for p in sorted((studio.state / 'refresh').glob('refresh-*.json'), reverse=True)][:30]
                result = studio.result or studio.load('latest.json', None)
                # Never enter Desktop on startup/status reads. Permission or
                # provider stalls must not hold the whole diagnostic UI hostage.
                return self.send(200, {'progress': studio.progress, 'result': result, 'history': studio.load('history.json', []), 'receipts': studio.receipts(), 'completions': studio.load('completions.json', []), 'refresh': refresh, 'native_refresh': studio.load('native-refresh-history.json', []), 'pressure': studio.load('pressure.json', None), 'pressure_history': studio.load('pressure-history.json', []), 'finals': (result or {}).get('finals', []), 'daily': studio.daily()})
            return self.send(404, {'error': '見つかりません'})

        def do_POST(self):
            if not self.authorized():
                return self.send(403, {'error': '操作を許可できません'})
            if self.server.closing.is_set():
                return self.send(503, {'error': '終了処理中です。整理が完了してからアプリを開いてください'})
            try:
                length = int(self.headers.get('Content-Length', 0))
                if not 0 < length <= 16000 or self.headers.get('Content-Type') != 'application/json':
                    raise ValueError('不正なリクエストです')
                data = json.loads(self.rfile.read(length))
                if not isinstance(data, dict):
                    raise ValueError('JSONオブジェクトが必要です')
                if self.path == '/api/assistant':
                    assistant = cleanup_assistant.Assistant(studio)
                    if studio.progress['running'] or studio.lock.locked():
                        raise ValueError('別の処理が完了してから実行してください')
                    action = data.get('action')
                    if action == 'prepare':
                        primary, reviewer = data.get('primary', 'sol'), data.get('reviewer', 'terra')
                        if primary not in job_recovery.care.MODELS or reviewer not in job_recovery.care.MODELS:
                            raise ValueError('モデルを選択してください')
                        operation = assistant.lock()
                        operation.__enter__()
                        try:
                            job_recovery.care.save(assistant.state / 'operation.json', {'running':True,'at':time.time(),'owner':studio.assistant_owner})
                        except Exception:
                            operation.__exit__(*sys.exc_info())
                            raise
                        studio.progress['running'] = True
                        def run_assistant():
                            try:
                                assistant.prepare(primary, reviewer)
                                job_recovery.care.save(assistant.state / 'operation.json', {'running':False,'at':time.time()})
                            except Exception as e:
                                job_recovery.care.save(assistant.state / 'operation.json', {'running':False,'at':time.time(),'error':str(e)})
                            finally:
                                studio.progress['running'] = False
                                operation.__exit__(None, None, None)
                        self.server.scan_thread = threading.Thread(target=run_assistant)
                        self.server.scan_thread.start()
                        return self.send(202, {'started':True})
                    with assistant.lock(), studio.lock:
                        if action == 'plan':
                            return self.send(200, assistant.plan(data.get('ids')))
                        if action == 'apply':
                            return self.send(200, assistant.apply(data.get('ticket')))
                        raise ValueError('不明な操作です')
                if self.path == '/api/job-recovery':
                    if studio.progress['running'] or not studio.lock.acquire(blocking=False):
                        raise ValueError('別の処理が完了してから実行してください')
                    try:
                        recovery = job_recovery.Recovery(studio.home)
                        with recovery.lock():
                            if data.get('action') == 'scan':
                                recovery.scan()
                            elif data.get('action') == 'apply':
                                recovery.apply(data.get('ticket'))
                            else:
                                raise ValueError('不明な操作です')
                        return self.send(200, recovery.status())
                    finally:
                        studio.lock.release()
                if self.path == '/api/render-care':
                    if studio.progress['running'] or not studio.lock.acquire(blocking=False):
                        raise ValueError('別の処理が完了してから実行してください')
                    try:
                        module = render_care_module()
                        care = module.Care(state=studio.home / 'Library/Application Support/devpurge/render-care')
                        if not care.config()['sources']:
                            raise ValueError('保持するRemotionプロジェクトの登録が必要です')
                        apply = data.get('apply') is True
                        studio.progress = {'running': True, 'message': '一時データと元素材を照合しています', 'done': 0, 'total': 0}
                        module.save(care.state / 'operation.json', {'running': True, 'at': time.time()})
                    except Exception:
                        studio.lock.release()
                        raise
                    def run_care():
                        try:
                            result = care.cycle(apply=apply)
                            error = result.get('ai', {}).get('error')
                            module.save(care.state / 'operation.json', {'running': False, 'at': time.time(), 'error': error})
                        except Exception as e:
                            module.save(care.state / 'operation.json', {'running': False, 'at': time.time(), 'error': str(e)})
                        finally:
                            studio.progress = {'running': False, 'message': 'レンダリングの片付けを確認しました', 'done': 0, 'total': 0}
                            studio.lock.release()
                    self.server.scan_thread = threading.Thread(target=run_care)
                    self.server.scan_thread.start()
                    return self.send(202, {'started': True})
                if self.path == '/api/scan':
                    if studio.progress['running'] or studio.lock.locked():
                        raise ValueError('処理中です')
                    studio.progress['running'] = True
                    def run():
                        try:
                            studio.scan()
                        except Exception as e:
                            studio.progress = {'running': False, 'message': str(e), 'error': True, 'done': 0, 'total': 0}
                    self.server.scan_thread = threading.Thread(target=run)
                    self.server.scan_thread.start()
                    return self.send(202, {'started': True})
                if self.path == '/api/plan':
                    return self.send(200, studio.plan(data.get('ids')))
                if self.path == '/api/complete':
                    return self.send(200, studio.complete(data))
                if self.path == '/api/completion-plan':
                    return self.send(200, studio.completion_plan(data.get('id')))
                if self.path == '/api/refresh-plan':
                    return self.send(200, studio.refresh_plan())
                if self.path == '/api/pressure':
                    if studio.lock.locked():
                        raise ValueError('スキャン・整理が完了してから、もう一度確認してください')
                    return self.send(200, studio.pressure())
                if self.path == '/api/reveal':
                    return self.send(200, studio.reveal(data.get('id')))
                if self.path == '/api/browse':
                    return self.send(200, studio.browse(data.get('id')))
                if self.path == '/api/daily-finish':
                    return self.send(200, studio.finish_daily(data))
                if self.path == '/api/apply':
                    return self.send(200, studio.apply(data.get('id')))
                if self.path == '/api/restore':
                    return self.send(200, studio.restore(data.get('id', '')))
                return self.send(404, {'error': '見つかりません'})
            except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as e:
                return self.send(400, {'error': str(e)})
    return Handler


def main():
    parser = argparse.ArgumentParser(description='devpurge Storage Studio')
    parser.add_argument('command', choices=['studio', 'diagnose'])
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--no-open', action='store_true')
    parser.add_argument('--native', action='store_true', help='Private app handoff; exits safely when its input pipe closes')
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error('sudoでは起動しないでください')
    studio = Studio()
    studio.state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if studio.state != studio.state.resolve():
        parser.error('保存場所にシンボリックリンクが含まれています')
    lock_file = (studio.state / 'instance.lock').open('a')
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        if args.command == 'studio' and (args.native or not args.no_open):
            existing = studio.load('instance.json', {}).get('url', '')
            if re.fullmatch(r'http://127\.0\.0\.1:\d+/#[-_A-Za-z0-9]+', existing):
                if args.native:
                    print(json.dumps({'url': existing, 'owned': False}), flush=True)
                else:
                    webbrowser.open(existing)
                return
        parser.error('Studioまたは診断がすでに動いています。先に終了してください')
    if args.command == 'diagnose':
        print(json.dumps(studio.scan(), ensure_ascii=False, indent=2))
        return
    token = secrets.token_urlsafe(32)
    server = Server(('127.0.0.1', args.port), handler(studio, token))
    url = 'http://127.0.0.1:' + str(server.server_port) + '/#' + token
    atomic_json(studio.state / 'instance.json', {'pid': os.getpid(), 'url': url})
    if args.native:
        print(json.dumps({'url': url, 'owned': True}), flush=True)
        threading.Thread(target=server.stop_after_input, args=(sys.stdin.buffer,), daemon=True).start()
    else:
        print('devpurge Storage Studio\n' + url + '\nCtrl+Cで終了。ファイルは自動削除しません。', flush=True)
    if not args.no_open and not args.native:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.closing.set()
        server.server_close()
        (studio.state / 'instance.json').unlink(missing_ok=True)


if __name__ == '__main__':
    main()
