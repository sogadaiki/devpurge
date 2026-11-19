import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

LIB = Path(__file__).resolve().parents[1] / 'lib'
sys.path.insert(0, str(LIB))
import project_index as index


class ProjectIndex(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name).resolve()
        self.root = self.home / '動画 案件'
        self.root.mkdir()
        self.manifest = self.root / index.MANIFEST
        self.rc = self.home / '.devpurgerc'
        self.keeper = self.root / 'release.txt'
        self.copy = self.root / 'trial.txt'
        self.copy.write_text('draft')
        self.keeper.write_text('draft')

    def cli(self, action='list', *args, expect=0):
        cmd = [sys.executable, '-B', str(LIB / 'project_index.py'), action]
        if action != 'projects':
            cmd.append(str(self.root))
        proc = subprocess.run(cmd + list(args) + ['--json'], env={**os.environ, 'HOME': str(self.home)},
                              capture_output=True, text=True, timeout=15)
        data = json.loads(proc.stdout)
        self.assertEqual(proc.returncode, expect, (data, proc.stderr))
        if expect:
            self.assertIn('error', data)
        return data

    def record(self, name, role, *extra, expect=0):
        return self.cli('record', '--path', name, '--role', role, '--owner', '編集担当',
                        '--reason', '作業記録', *extra, expect=expect)

    def row(self, path, result=None):
        return next(r for r in (result or self.cli())['entries'] if r['path'] == path)

    def test_read_only_discovery_bounded_scope_and_protected_paths(self):
        retained = self.root / index.RETAINED / 'kept'
        retained.mkdir(parents=True)
        (retained / 'private-asset').touch()
        (self.root / '.next').mkdir()
        (self.root / 'custom-protect').touch()
        (self.root / '.env.production').touch()
        (self.root / 'alias').symlink_to(self.keeper)
        self.rc.write_text(f'workspace_project={self.root}\nprotect=custom-protect\n')
        before = set(self.root.iterdir())
        report = self.cli()
        paths = {r['path'] for r in report['entries']}
        self.assertIn('.next', paths)
        self.assertFalse({'custom-protect', '.env.production', 'alias', str(index.RETAINED / 'kept/private-asset')} & paths)
        self.assertEqual(self.row(str(index.RETAINED / 'kept'), report)['decision'], 'keep')
        self.assertEqual(self.row('trial.txt', report)['revision'], 'new')
        self.assertFalse(self.manifest.exists())
        self.assertEqual(before, set(self.root.iterdir()))
        self.assertEqual(self.cli('projects')['projects'], [str(self.root)])
        self.rc.write_text(f'exclude={self.root}\n')
        self.cli(expect=1)
        self.record('trial.txt', 'temporary', expect=1)
        self.assertFalse(self.manifest.exists())

    def test_manifest_edits_roundtrip_including_missing_rows_and_stale_update(self):
        first = self.record('release.txt', 'deliverable', '--until', '配信後まで')
        row = self.row('release.txt', first)
        self.assertTrue(row['recorded'])
        self.assertEqual(row['decision'], 'keep')
        self.assertEqual(row['until'], '配信後まで')
        raw = self.manifest.read_bytes()
        self.assertNotIn(str(self.root).encode(), raw)
        self.assertEqual(self.manifest.stat().st_mode & 0o777, 0o600)
        self.record('release.txt', 'temporary', expect=1)
        self.assertEqual(self.manifest.read_bytes(), raw)
        updated = self.record('release.txt', 'temporary', '--expected', row['revision'],
                              '--rebuild', 'touch forbidden-test-marker')
        self.assertEqual(self.row('release.txt', updated)['decision'], 'review')
        self.assertFalse((self.root / 'forbidden-test-marker').exists())
        self.keeper.unlink()
        missing = self.row('release.txt')
        self.assertTrue(missing['recorded'])
        self.assertIn('実物', missing['detail'])

    def test_verification_is_live_and_does_not_persist_permission(self):
        self.record('trial.txt', 'copy', '--keeper', 'release.txt')
        before = self.manifest.read_bytes()
        revision = self.row('trial.txt')['revision']
        verify = ('--path', 'trial.txt', '--expected', revision)
        self.assertEqual(self.cli('verify', *verify)['decision'], 'candidate')
        self.assertEqual(self.row('trial.txt')['decision'], 'review')
        self.assertEqual(self.manifest.read_bytes(), before)
        self.copy.write_text('changed')
        self.assertEqual(self.cli('verify', *verify)['decision'], 'review')
        self.copy.write_text('draft')
        self.record('trial.txt', 'copy', '--keeper', 'release.txt', '--until', '公開完了後', '--expected', revision)
        self.cli('verify', *verify, expect=1)
        self.assertEqual(self.cli('verify', '--path', 'trial.txt')['decision'], 'review')

    def test_nested_kept_files_and_a_temporary_keeper_hold(self):
        for folder in ('trial', 'keeper'):
            (self.root / folder).mkdir()
            (self.root / folder / 'file').write_text('held')
        self.record('trial', 'copy', '--keeper', 'keeper')
        self.record('trial/file', 'source')
        self.assertEqual(self.cli('verify', '--path', 'trial')['decision'], 'keep')
        self.record('trial.txt', 'copy', '--keeper', 'release.txt')
        self.record('release.txt', 'temporary')
        self.assertEqual(self.cli('verify', '--path', 'trial.txt')['decision'], 'review')

    def test_two_concurrent_first_writes_preserve_both_and_same_row_conflicts(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            jobs = [pool.submit(self.record, name, 'source') for name in ('trial.txt', 'release.txt')]
            for job in jobs:
                job.result()
        self.assertEqual(len(json.loads(self.manifest.read_bytes())['entries']), 2)
        rev = self.row('trial.txt')['revision']
        def update(who):
            p = subprocess.run([sys.executable, '-B', str(LIB / 'project_index.py'), 'record', str(self.root),
                                '--path', 'trial.txt', '--role', 'temporary', '--owner', who, '--reason',
                                'finished', '--expected', rev, '--json'], env={**os.environ, 'HOME': str(self.home)},
                               capture_output=True, timeout=15)
            return p.returncode
        with concurrent.futures.ThreadPoolExecutor() as pool:
            self.assertEqual(sorted(pool.map(update, ('編集', '開発'))), [0, 1])

    def test_retained_copy_and_recorded_parent_keep_their_children(self):
        folder = self.root / index.RETAINED / 'example'
        folder.mkdir(parents=True)
        (folder / 'trial.txt').write_text('draft')
        path = str(index.RETAINED / 'example/trial.txt')
        self.record(path, 'copy', '--keeper', 'release.txt')
        self.assertEqual(self.row(path)['decision'], 'keep')
        self.assertEqual(self.cli('verify', '--path', path)['decision'], 'keep')
        (self.root / 'Assets').mkdir()
        (self.root / 'Assets' / 'take.txt').write_text('draft')
        self.record('Assets', 'source')
        self.record('Assets/take.txt', 'copy', '--keeper', 'release.txt')
        self.assertEqual(self.row('Assets/take.txt')['decision'], 'keep')
        self.assertEqual(self.cli('verify', '--path', 'Assets/take.txt')['decision'], 'keep')
        self.assertTrue(index.overlaps_kept('ASSETS/cafe\u0301/take', ({Path('assets/café')}, set())))
        self.record('RELEASE.txt', 'copy', '--keeper', 'release.txt', expect=1)

    def test_read_limits_warn_and_discovery_does_not_create_index(self):
        with patch.object(Path, 'home', return_value=self.home), patch.object(index, 'SCAN_LIMIT', 1):
            partial = index.execute(type('Args', (), dict(action='list', root=self.root))())
        self.assertTrue(partial['warnings'])
        self.assertFalse(self.manifest.exists())

    def test_unknown_version_fields_and_duplicate_keys_preserved(self):
        self.record('trial.txt', 'copy', '--keeper', 'release.txt')
        valid = json.loads(self.manifest.read_bytes())
        row = valid['entries'][0]
        for malformed in ('{"version":1,"version":1,"entries":[]}', 'not JSON', '[]',
                          json.dumps(dict(valid, version=2)), json.dumps(dict(valid, extension='future')),
                          json.dumps(dict(valid, entries=[dict(row, role='future')])),
                          json.dumps(dict(valid, entries=[dict(row, extra='future')]))):
            with self.subTest(malformed=malformed):
                self.manifest.write_text(malformed)
                self.cli(expect=1)
                self.record('trial.txt', 'source', expect=1)
                self.assertEqual(self.manifest.read_text(), malformed)

    def test_symlink_hardlink_keep_marker_invalid_paths_and_blocked_fields(self):
        self.manifest.symlink_to(self.keeper)
        self.record('trial.txt', 'source', expect=1)
        self.assertEqual(self.keeper.read_text(), 'draft')
        self.manifest.unlink()
        os.link(self.keeper, self.manifest)
        self.cli(expect=1)
        self.manifest.unlink()
        (self.root / 'link').symlink_to(self.keeper)
        for invalid in ('../outside', './trial.txt', 'a//b', str(self.keeper), 'link', index.MANIFEST, '.env'):
            self.record(invalid, 'source', expect=1)
        self.record('trial.txt', 'nonsense', expect=1)
        self.record('trial.txt', 'copy', '--keeper', 'trial.txt', expect=1)
        self.assertFalse(self.manifest.exists())
        self.rc.symlink_to(self.home / 'missing')
        self.cli(expect=1)
        self.rc.unlink()
        (self.root / '.devpurge-keep').touch()
        self.record('trial.txt', 'source', expect=1)

    def test_record_count_and_read_limit_leave_manifest_intact(self):
        self.record('trial.txt', 'source')
        before = self.manifest.read_bytes()
        with patch.object(Path, 'home', return_value=self.home), patch.object(index, 'MAX_RECORDS', 1):
            with self.assertRaises(ValueError):
                index.execute(type('Args', (), dict(action='record', root=self.root, path='release.txt',
                              role='source', owner='editor', reason='production', keeper=None, until=None,
                              rebuild=None, expected='new'))())
        self.assertEqual(self.manifest.read_bytes(), before)
        self.manifest.write_bytes(b' ' * (index.MAX_BYTES + 1))
        self.cli(expect=1)


if __name__ == '__main__':
    unittest.main()
