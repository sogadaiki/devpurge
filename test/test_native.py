#!/usr/bin/env python3
"""Native lifecycle and transactional installer tests; disposable homes only."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import select
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


studio = load('studio', ROOT / 'lib/studio.py')
installer = load('installer', ROOT / 'scripts/install-studio-app.py')


class NativeLifecycle(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'AppKit requires macOS')
    def test_native_refresh_identity_and_protection(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp)/'policy'
            subprocess.run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(Path(temp)/'cache'),
                            str(ROOT/'native/Refresh.swift'), str(ROOT/'test/refresh_policy.swift'), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn('checks passed', result.stdout)

    def test_local_start_does_not_perform_dns_lookup(self):
        with tempfile.TemporaryDirectory() as temp, patch('socket.getfqdn', side_effect=AssertionError('Unexpected DNS lookup')):
            server = studio.Server(('127.0.0.1', 0), studio.handler(studio.Studio(temp), 'fixture'))
            try:
                self.assertEqual(server.server_name, '127.0.0.1')
                self.assertGreater(server.server_port, 0)
            finally:
                server.server_close()

    def test_owned_engine_handoff_and_eof_shutdown(self):
        with tempfile.TemporaryDirectory() as temp:
            argv = [sys.executable, '-B', str(ROOT / 'lib/studio.py'), 'studio', '--native']
            env = {**os.environ, 'HOME': temp}
            child = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(select.select([child.stdout], [], [], 5)[0], 'engine readiness timed out')
                info = json.loads(child.stdout.readline())
                self.assertTrue(info['owned'])
                base, token = info['url'].split('/#')
                req = urllib.request.Request(base + '/api/health', headers={'X-Studio-Token': token})
                with urllib.request.urlopen(req, timeout=5) as response:
                    self.assertEqual(json.load(response), {'app': 'devpurge-studio', 'protocol': 1, 'closing': False})
                peer = subprocess.run(argv, env=env, input='', text=True, capture_output=True, timeout=5, check=True)
                shared = json.loads(peer.stdout)
                self.assertFalse(shared['owned'])
                self.assertEqual(shared['url'], info['url'])
                self.assertIsNone(child.poll(), 'handoff must leave the existing server running')
                child.stdin.close()
                self.assertEqual(child.wait(timeout=5), 0)
                self.assertFalse((Path(temp) / 'Library/Application Support/devpurge/studio/instance.json').exists())
            finally:
                if child.poll() is None:
                    child.stdin.close()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        # This is only our disposable test child, never a real
                        # user's engine. Preserve the original assertion error.
                        child.kill()
                        child.wait(timeout=5)
                child.stdout.close()
                child.stderr.close()

    def test_closing_rejects_new_action_and_health_requires_auth(self):
        with tempfile.TemporaryDirectory() as temp:
            engine = studio.Studio(temp)
            server = studio.Server(('127.0.0.1', 0), studio.handler(engine, 'fixture'))
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            url = 'http://127.0.0.1:' + str(server.server_port)
            try:
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(url + '/api/health', timeout=5)
                self.assertEqual(error.exception.code, 403)
                error.exception.close()
                server.closing.set()
                request = urllib.request.Request(url + '/api/apply', data=b'{"id":"x"}', headers={'Content-Type': 'application/json', 'X-Studio-Token': 'fixture'})
                with patch.object(engine, 'apply') as apply:
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(request, timeout=5)
                    self.assertEqual(error.exception.code, 503)
                    error.exception.close()
                    apply.assert_not_called()
            finally:
                server.shutdown(); server.server_close(); thread.join()

    def test_close_waits_for_accepted_operation(self):
        with tempfile.TemporaryDirectory() as temp:
            engine = studio.Studio(temp)
            server = studio.Server(('127.0.0.1', 0), studio.handler(engine, 'fixture'))
            entered, finish, closed = threading.Event(), threading.Event(), threading.Event()
            replies, failures = [], []
            def operation(_):
                entered.set()
                finish.wait(5)
                return {'status': 'saved'}
            def request():
                try:
                    req = urllib.request.Request('http://127.0.0.1:' + str(server.server_port) + '/api/apply', data=b'{"id":"x"}', headers={'Content-Type': 'application/json', 'X-Studio-Token': 'fixture'})
                    with urllib.request.urlopen(req, timeout=6) as response:
                        replies.append(json.load(response))
                except Exception as error:
                    failures.append(str(error))
            def close():
                server.closing.set(); server.shutdown(); server.server_close(); closed.set()
            serving = threading.Thread(target=server.serve_forever)
            serving.start()
            with patch.object(engine, 'apply', side_effect=operation):
                client = threading.Thread(target=request); client.start()
                self.assertTrue(entered.wait(3))
                closing = threading.Thread(target=close); closing.start()
                self.assertFalse(closed.wait(.7), 'must not interrupt an accepted operation')
                finish.set()
                closing.join(5); client.join(5); serving.join(5)
                self.assertTrue(closed.is_set())
                self.assertEqual(failures, [])
                self.assertEqual(replies, [{'status': 'saved'}])


class InstallerSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / 'devpurge Studio.app'
    def tearDown(self):
        self.temp.cleanup()
    def fixture(self, path, value='old', bundle=installer.BUNDLE_ID):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'studio'}))
        (path / 'Contents/MacOS/studio').write_text(value)
    def test_build_failure_retains_installed_app(self):
        self.fixture(self.app)
        with patch.object(installer, 'build', side_effect=RuntimeError('compile failure')):
            with self.assertRaises(RuntimeError): installer.install(self.app)
        self.assertEqual((self.app / 'Contents/MacOS/studio').read_text(), 'old')
        self.assertEqual(list(self.root.iterdir()), [self.app])
    def test_update_replaces_only_owned_bundle_and_removes_build_cache(self):
        self.fixture(self.app)
        def build(path, *_):
            self.fixture(path, 'new')
            (path.parent / 'module-cache').mkdir()
        with patch.object(installer, 'build', side_effect=build): installer.install(self.app)
        self.assertEqual((self.app / 'Contents/MacOS/studio').read_text(), 'new')
        self.assertEqual(list(self.root.iterdir()), [self.app])
    def test_unknown_app_and_symlink_refused(self):
        self.fixture(self.app, bundle='another.app')
        with self.assertRaises(ValueError): installer.install(self.app)
        link = self.root / 'linked.app'; link.symlink_to(self.app)
        with self.assertRaises(ValueError): installer.install(link)
    def test_running_native_app_refused(self):
        self.fixture(self.app)
        with patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, str(self.app / 'Contents/MacOS/studio') + '\n')):
            with self.assertRaisesRegex(ValueError, 'Quit'): installer.install(self.app)
    def test_failed_install_rename_rolls_back(self):
        self.fixture(self.app)
        rename = Path.rename
        def fail(source, target):
            if source.name == 'devpurge Studio.app' and source != self.app:
                raise OSError('fixture rename failure')
            return rename(source, target)
        with patch.object(installer, 'build', side_effect=lambda path, *_: self.fixture(path, 'new')), patch.object(Path, 'rename', fail):
            with self.assertRaises(OSError): installer.install(self.app)
        self.assertEqual((self.app / 'Contents/MacOS/studio').read_text(), 'old')


if __name__ == '__main__':
    unittest.main()
