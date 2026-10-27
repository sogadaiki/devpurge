#!/usr/bin/env python3
"""Manual recovery of disconnected Remotion browsers; never signal a PID.

Only a registered Remotion executable, orphaned parent, absent controller,
dead page server and stable repeated evidence qualify. Unknown means keep.
The browser UUID endpoint receives Browser.close; no force kill fallback.
"""
import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import time
import urllib.request
from urllib.parse import urlsplit
import render_care as care


def processes():
    result = care.run(['/bin/ps', '-axo', 'pid=,ppid=,uid=,lstart=,comm='])
    result.check_returncode()
    rows = {}
    for line in result.stdout.splitlines():
        p = line.split(None, 8)
        if len(p) == 9:
            rows[int(p[0])] = {'pid': int(p[0]), 'parent': int(p[1]), 'uid': int(p[2]),
                             'birth': ' '.join(p[3:8]), 'exe': p[8]}
    return rows


def json_endpoint(port, route):
    # Ignore proxy settings and redirects: only the validated local listener.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args):
            raise ValueError('Redirect refused')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open('http://127.0.0.1:%d/json/%s' % (port, route), timeout=3) as response:
        raw = response.read(65537)
        if len(raw) > 65536:
            raise ValueError('Oversize browser response')
        return json.loads(raw)


def dead_server(url):
    p = urlsplit(url)
    if p.scheme != 'http' or p.hostname not in ('localhost', '127.0.0.1') or p.path != '/index.html' or not p.port or p.query or p.fragment or p.username:
        raise ValueError('Unknown page; preserved')
    for host in ('127.0.0.1', '::1'):
        try:
            with socket.create_connection((host, p.port), timeout=1):
                raise ValueError('Page server is running; preserved')
        except ConnectionRefusedError:
            pass
    return p.port


def evidence(pid, sources):
    rows = processes()
    row = rows[pid]
    if row['parent'] != 1 or row['uid'] != os.getuid():
        raise ValueError('Parent/controller exists; preserved')
    exe = Path(row['exe'])
    allowed = [Path(s) / 'node_modules/.remotion/chrome-headless-shell/mac-arm64/chrome-headless-shell-mac-arm64/chrome-headless-shell' for s in sources]
    allowed += [Path(s) / 'node_modules/.remotion/chrome-headless-shell/mac-x64/chrome-headless-shell-mac-x64/chrome-headless-shell' for s in sources]
    if exe not in allowed or not exe.is_file() or exe.stat().st_uid != os.getuid():
        raise ValueError('Unregistered browser; preserved')
    started = time.mktime(time.strptime(row['birth'], '%a %b %d %H:%M:%S %Y'))
    if time.time() - started < 3600:
        raise ValueError('Recent browser; preserved')
    tree = {pid}
    while True:
        expanded = tree | {p for p, r in rows.items() if r['parent'] in tree}
        if expanded == tree:
            break
        tree = expanded
    if any(rows[p]['exe'] != str(exe) or rows[p]['uid'] != os.getuid() for p in tree):
        raise ValueError('Unknown child process; preserved')
    observed = care.activity(sources)
    if any(r['pid'] not in tree for r in observed['renderers']):
        raise ValueError('Another renderer/controller is running; preserved')
    args = care.run(['/bin/ps', '-p', str(pid), '-o', 'args='])
    args.check_returncode()
    match = re.search(r'--user-data-dir=(\S+)', args.stdout)
    if not match:
        raise ValueError('No private browser profile')
    profile = Path(match[1]).resolve()
    if profile.parent != care.user_temp() or not re.fullmatch(r'puppeteer_dev_chrome_profile-[A-Za-z0-9]+', profile.name):
        raise ValueError('Unknown profile')
    port_file = profile / 'DevToolsActivePort'
    if port_file.is_symlink() or port_file.stat().st_uid != os.getuid() or port_file.stat().st_size > 512:
        raise ValueError('Invalid endpoint file')
    port, endpoint = port_file.read_text().splitlines()
    if not port.isdigit() or not 1 <= int(port) <= 65535 or not re.fullmatch(r'/devtools/browser/[a-f0-9-]{36}', endpoint):
        raise ValueError('Invalid endpoint')
    net = care.run(['/usr/sbin/lsof', '-nP', '-a', '-p', ','.join(map(str, sorted(tree))), '-iTCP', '-FpnT'])
    if net.returncode or net.stderr.strip():
        raise ValueError('Network evidence unavailable')
    owner = None
    listeners = []
    for line in net.stdout.splitlines():
        if line.startswith('p'):
            owner = int(line[1:])
        elif line.startswith('n'):
            listeners.append((owner, line[1:]))
        elif line.startswith('TST=') and line != 'TST=LISTEN':
            raise ValueError('Connected browser; preserved')
    if listeners != [(pid, '127.0.0.1:' + port)]:
        raise ValueError('Unexpected sockets; preserved')
    version = json_endpoint(int(port), 'version')
    if version.get('webSocketDebuggerUrl') != 'ws://127.0.0.1:' + port + endpoint:
        raise ValueError('Browser identity mismatch')
    targets = json_endpoint(int(port), 'list')
    if not targets or any(t.get('type') != 'page' for t in targets):
        raise ValueError('Unknown targets; preserved')
    pages = [t for t in targets if t.get('url') != 'about:blank']
    if not pages:
        raise ValueError('No ended render evidence')
    ports = sorted({dead_server(t['url']) for t in pages})
    return {'process': row, 'tree': [rows[p] for p in sorted(tree)], 'port': int(port),
            'endpoint': endpoint, 'profile_identity': care.identity(profile),
            'targets': sorted(t['id'] for t in targets), 'dead_ports': ports}


def same_process(a, b):
    return bool(a) and all(a.get(k) == b.get(k) for k in ('pid', 'birth', 'uid', 'exe'))


def close_browser(proof, sources):
    """RFC6455 masked close command, bound to the browser UUID (not PID)."""
    key = base64.b64encode(os.urandom(16)).decode()
    with socket.create_connection(('127.0.0.1', proof['port']), timeout=3) as sock:
        request = ('GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n') % (proof['endpoint'], proof['port'], key)
        sock.sendall(request.encode())
        header = b''
        while b'\r\n\r\n' not in header and len(header) < 8192:
            chunk = sock.recv(1)
            if not chunk:
                break
            header += chunk
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        fields = dict(line.split(':', 1) for line in header.decode().split('\r\n')[1:] if ':' in line)
        fields = {k.lower(): v.strip() for k, v in fields.items()}
        if not header.startswith(b'HTTP/1.1 101 ') or fields.get('sec-websocket-accept') != accept:
            raise ValueError('WebSocket handshake failed')
        # Once connected, allow exactly our own controller connection. Recheck
        # before sending the only mutating command; abort if another attaches.
        pid = proof['process']['pid']
        if processes().get(pid) != proof['process']:
            raise ValueError('Browser process changed')
        net = care.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-Fn'])
        expected = ['127.0.0.1:%d' % proof['port'], '127.0.0.1:%d->127.0.0.1:%d' % (proof['port'], sock.getsockname()[1])]
        if net.returncode or net.stderr.strip() or sorted(x[1:] for x in net.stdout.splitlines() if x.startswith('n')) != sorted(expected):
            raise ValueError('Controller connections changed')
        tree = {r['pid'] for r in proof['tree']}
        if any(r['pid'] not in tree for r in care.activity(sources)['renderers']):
            raise ValueError('Renderer started; preserved')
        for port in proof['dead_ports']:
            dead_server('http://localhost:%d/index.html' % port)
        message = b'{"id":1,"method":"Browser.close"}'
        mask = os.urandom(4)
        sock.sendall(bytes([0x81, 0x80 | len(message)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(message)))


class Recovery:
    def __init__(self, home=None):
        self.home = Path(home or Path.home())
        self.state = self.home / 'Library/Application Support/devpurge/job-recovery'

    def sources(self):
        return care.load(self.home / 'Library/Application Support/devpurge/render-care/config.json', {}).get('sources', [])

    @contextlib.contextmanager
    def lock(self):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.state.resolve() != self.state:
            raise ValueError('State link refused')
        fd = os.open(self.state / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    def scan(self):
        items = []
        sources = self.sources()
        for pid, row in processes().items():
            if Path(row['exe']).name != 'chrome-headless-shell' or row['parent'] != 1:
                continue
            item = {'pid': pid, 'ready': False}
            try:
                first = evidence(pid, sources)
                time.sleep(2)
                if evidence(pid, sources) != first:
                    raise ValueError('Process state changed; preserved')
                item.update(ready=True, proof=first, id=secrets.token_hex(16), reason='親処理・制御接続・ページサーバーの終了を再確認')
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
                item['reason'] = str(e)
            items.append(item)
        result = {'at': time.time(), 'items': items, 'free': shutil.disk_usage(self.home).free}
        care.save(self.state / 'latest.json', result)
        return result

    def apply(self, ticket):
        plan = care.load(self.state / 'latest.json', {})
        if not isinstance(ticket, str) or not 0 <= time.time() - plan.get('at', 0) < 300:
            raise ValueError('確認から5分経過しました。再確認してください')
        matches = [x for x in plan.get('items', []) if x.get('id') == ticket and x.get('ready')]
        if len(matches) != 1:
            raise ValueError('確認済みの対象を選択してください')
        item = matches[0]
        proof = evidence(item['pid'], self.sources())
        if proof != item['proof']:
            raise ValueError('状態が変化したため保持しました')
        receipt = {'at': time.time(), 'pid': item['pid'], 'before_free': shutil.disk_usage(self.home).free, 'status': 'requested', 'proof': proof}
        # Consume the ticket and persist intent before sending a close request.
        item['ready'] = False
        care.save(self.state / 'latest.json', plan)
        path = self.state / ('receipt-' + ticket + '.json')
        care.save(path, receipt)
        try:
            close_browser(proof, self.sources())
            for _ in range(20):
                remaining = processes()
                if all(not same_process(remaining.get(p['pid']), p) for p in proof['tree']):
                    receipt['status'] = 'closed'
                    break
                time.sleep(0.5)
            else:
                receipt['status'] = 'not_closed_no_force'
        except Exception as e:
            receipt.update(status='failed_no_force', error=str(e))
        receipt['after_free'] = shutil.disk_usage(self.home).free
        receipt['free_delta'] = receipt['after_free'] - receipt['before_free']
        care.save(path, receipt)
        care.save(self.state / 'receipt.json', receipt)
        return receipt

    def status(self):
        result = care.load(self.state / 'latest.json', {'items': []})
        result['items'] = [{k: v for k, v in x.items() if k != 'proof'} for x in result['items']]
        result['receipt'] = care.load(self.state / 'receipt.json', {})
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['scan', 'status', 'apply'])
    parser.add_argument('--ticket')
    args = parser.parse_args()
    recovery = Recovery()
    with recovery.lock():
        result = recovery.apply(args.ticket) if args.command == 'apply' else getattr(recovery, args.command)()
    print(json.dumps(result, ensure_ascii=False, indent=2))
