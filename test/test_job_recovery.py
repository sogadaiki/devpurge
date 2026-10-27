#!/usr/bin/env python3
"""Never touch real processes: identity, network and expiry guards."""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import job_recovery as job


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name).resolve()
        self.engine = job.Recovery(self.home)
        self.row = dict(pid=123, parent=1, uid=os.getuid(), birth='Mon Oct 26 08:00:00 2026', exe='/fixture/chrome-headless-shell')
        self.proof = {'process': self.row, 'tree': [self.row], 'port': 12345,
                      'endpoint': '/devtools/browser/11111111-1111-1111-1111-111111111111', 'dead_ports': [3000]}

    def tearDown(self):
        self.tmp.cleanup()

    def plan(self):
        job.care.save(self.engine.state / 'latest.json', {'at': time.time(), 'items': [{'id': 'ticket', 'pid': 123, 'ready': True, 'proof': self.proof}]})

    def test_pid_reuse_and_reparenting(self):
        self.assertTrue(job.same_process({**self.row, 'parent': 2}, self.row))
        self.assertFalse(job.same_process({**self.row, 'birth': 'different'}, self.row))

    def test_unknown_ticket_never_closes(self):
        self.plan()
        with patch.object(job, 'close_browser') as close:
            with self.assertRaises(ValueError):
                self.engine.apply('arbitrary-pid')
            close.assert_not_called()

    def test_expired_plan(self):
        self.plan()
        with patch.object(job.time, 'time', return_value=time.time() + 301), patch.object(job, 'close_browser') as close:
            with self.assertRaises(ValueError):
                self.engine.apply('ticket')
            close.assert_not_called()

    def test_changed_process_keeps(self):
        self.plan()
        with patch.object(job, 'evidence', return_value={**self.proof, 'port': 1}), patch.object(job, 'close_browser') as close:
            with self.assertRaises(ValueError):
                self.engine.apply('ticket')
            close.assert_not_called()

    def test_close_receipt_and_ticket_single_use(self):
        self.plan()
        with patch.object(job, 'evidence', return_value=self.proof), patch.object(job, 'close_browser') as close, patch.object(job, 'processes', return_value={}):
            self.assertEqual(self.engine.apply('ticket')['status'], 'closed')
            with self.assertRaises(ValueError):
                self.engine.apply('ticket')
            close.assert_called_once()
        self.assertTrue((self.engine.state / 'receipt-ticket.json').exists())

    def test_failed_close_is_recorded_no_force(self):
        self.plan()
        with patch.object(job, 'evidence', return_value=self.proof), patch.object(job, 'close_browser', side_effect=ValueError('controller attached')):
            self.assertEqual(self.engine.apply('ticket')['status'], 'failed_no_force')

    def test_reparented_child_not_reported_closed(self):
        self.plan()
        with patch.object(job, 'evidence', return_value=self.proof), patch.object(job, 'close_browser'), patch.object(job, 'processes', return_value={123: {**self.row, 'parent': 55}}), patch.object(job.time, 'sleep'):
            self.assertEqual(self.engine.apply('ticket')['status'], 'not_closed_no_force')

    def test_scan_requires_stable_evidence(self):
        with patch.object(job, 'processes', return_value={123: self.row}), patch.object(job, 'evidence', side_effect=[self.proof, {}]), patch.object(job.time, 'sleep'):
            self.assertFalse(self.engine.scan()['items'][0]['ready'])

    def test_scan_keeps_on_inspection_timeout(self):
        with patch.object(job, 'processes', return_value={123: self.row}), patch.object(job, 'evidence', side_effect=subprocess.TimeoutExpired('lsof', 45)):
            self.assertFalse(self.engine.scan()['items'][0]['ready'])

    def test_live_parent_and_unregistered_executable_keep(self):
        for row in ({**self.row, 'parent': 5}, self.row):
            with patch.object(job, 'processes', return_value={123: row}):
                with self.assertRaises(ValueError):
                    job.evidence(123, [])

    def test_live_page_server_keeps(self):
        with socket.socket() as server:
            server.bind(('127.0.0.1', 0)); server.listen()
            with self.assertRaises(ValueError):
                job.dead_server('http://localhost:%d/index.html' % server.getsockname()[1])

    def test_foreign_page_and_ambiguous_network_keep(self):
        for url in ('https://example.com/index.html', 'http://localhost:3000/editor', 'http://localhost:3000/index.html?render=1'):
            with self.assertRaises(ValueError):
                job.dead_server(url)
        with patch.object(socket, 'create_connection', side_effect=TimeoutError('unknown')):
            with self.assertRaises(TimeoutError):
                job.dead_server('http://localhost:3000/index.html')

    def test_exclusive_lock(self):
        with self.engine.lock():
            with self.assertRaises(BlockingIOError):
                with job.Recovery(self.home).lock():
                    pass

    def test_websocket_only_sends_close_after_guards(self):
        for connected in (False, True):
            received = []
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0)); listener.listen()
                port = listener.getsockname()[1]
                peer_port = []
                def server():
                    conn, peer = listener.accept()
                    with conn:
                        conn.settimeout(3); peer_port.append(peer[1])
                        header = b''
                        while b'\r\n\r\n' not in header:
                            header += conn.recv(1024)
                        key = next(x.split(': ',1)[1] for x in header.decode().split('\r\n') if x.startswith('Sec-WebSocket-Key:'))
                        accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                        conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode())
                        frame = conn.recv(1024)
                        if frame:
                            size = frame[1] & 127
                            while len(frame) < 6+size:
                                frame += conn.recv(1024)
                            received.append(json.loads(bytes(b ^ frame[2+i%4] for i,b in enumerate(frame[6:6+size]))))
                thread = threading.Thread(target=server); thread.start()
                def net(*args, **kwargs):
                    text = 'n127.0.0.1:%d\nn127.0.0.1:%d->127.0.0.1:%d\n' % (port, port, peer_port[0])
                    if connected: text += 'n127.0.0.1:123->127.0.0.1:456\n'
                    return subprocess.CompletedProcess([], 0, text, '')
                try:
                    with patch.object(job, 'processes', return_value={123:self.row}), patch.object(job.care, 'run', side_effect=net), patch.object(job.care, 'activity', return_value={'renderers': []}), patch.object(job, 'dead_server'):
                        if connected:
                            with self.assertRaises(ValueError): job.close_browser({**self.proof, 'port':port}, [])
                        else: job.close_browser({**self.proof, 'port':port}, [])
                finally:
                    thread.join(5)
                self.assertEqual(received, [] if connected else [{'id':1,'method':'Browser.close'}])


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.source = self.root / 'source'
        self.exe = self.source / 'node_modules/.remotion/chrome-headless-shell/mac-arm64/chrome-headless-shell-mac-arm64/chrome-headless-shell'
        self.exe.parent.mkdir(parents=True); self.exe.write_text('fixture')
        self.profile = self.root / 'T/puppeteer_dev_chrome_profile-fixture'
        self.profile.mkdir(parents=True)
        self.endpoint = '/devtools/browser/11111111-1111-1111-1111-111111111111'
        (self.profile / 'DevToolsActivePort').write_text('12345\n' + self.endpoint)
        self.row = dict(pid=123, parent=1, uid=os.getuid(), birth=time.strftime('%a %b %d %H:%M:%S %Y', time.localtime(time.time()-7200)), exe=str(self.exe))
        self.rows = {123:self.row}
        self.net = 'p123\nn127.0.0.1:12345\nTST=LISTEN\n'
        self.active = {'renderers': []}
        self.targets = [{'id':'page','type':'page','url':'http://localhost:3000/index.html'}]
        def run(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, '--user-data-dir=' + str(self.profile) if argv[0] == '/bin/ps' else self.net, '')
        def endpoint(port, route):
            return {'webSocketDebuggerUrl':'ws://127.0.0.1:12345'+self.endpoint} if route=='version' else self.targets
        for patcher in (patch.object(job, 'processes', side_effect=lambda:self.rows), patch.object(job.care, 'run', side_effect=run), patch.object(job.care, 'user_temp', return_value=self.profile.parent), patch.object(job.care, 'activity', side_effect=lambda *_:self.active), patch.object(job, 'json_endpoint', side_effect=endpoint), patch.object(socket, 'create_connection', side_effect=ConnectionRefusedError)):
            patcher.start(); self.addCleanup(patcher.stop)

    def inspect(self):
        return job.evidence(123, [str(self.source)])

    def test_complete_evidence_qualifies(self):
        self.assertEqual(self.inspect()['dead_ports'], [3000])

    def test_attached_controller_keeps(self):
        self.net += 'n127.0.0.1:12345->127.0.0.1:9999\nTST=ESTABLISHED\n'
        with self.assertRaises(ValueError): self.inspect()

    def test_other_renderer_keeps(self):
        self.active['renderers'] = [{'pid':999}]
        with self.assertRaises(ValueError): self.inspect()

    def test_unknown_child_keeps(self):
        self.rows[124] = {**self.row, 'pid':124, 'parent':123, 'exe':'/another/app'}
        with self.assertRaises(ValueError): self.inspect()

    def test_unknown_page_keeps(self):
        self.targets[0]['url'] = 'https://example.com/index.html'
        with self.assertRaises(ValueError): self.inspect()

    def test_recent_browser_keeps(self):
        self.row['birth'] = time.strftime('%a %b %d %H:%M:%S %Y')
        with self.assertRaises(ValueError): self.inspect()

    def test_endpoint_symlink_keeps(self):
        p = self.profile / 'DevToolsActivePort'; p.rename(self.root/'port')
        p.symlink_to(self.root/'port')
        with self.assertRaises(ValueError): self.inspect()

    def test_partial_inventory_keeps(self):
        with patch.object(job.care, 'activity', side_effect=ValueError('incomplete')):
            with self.assertRaises(ValueError): self.inspect()


if __name__ == '__main__':
    unittest.main()
