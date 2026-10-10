#!/usr/bin/env python3
"""Destructive-policy tests use isolated synthetic files only."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unicodedata
import unittest

spec = importlib.util.spec_from_file_location('archive', Path(__file__).resolve().parents[1] / 'lib/archive.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class Retention(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='devpurge-archive-test-')
        self.home = Path(self.tmp.name).resolve()
        self.root = self.home / 'archive'; self.root.mkdir()
        self.state = self.home / 'state'
        self.now = time.time() + 5
        self.opened = set(); self.used = {}
        self.a = m.Archive(self.home, self.root, self.state, clock=lambda: self.now,
                           opens=lambda: self.opened, usage=lambda *args: self.used)

    def tearDown(self):
        self.tmp.cleanup()

    def file(self, name='old.txt'):
        p = self.root / name; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b'fixture only')
        os.utime(p, (1000000000, 1000000000))
        return p

    def age(self):
        self.a.observe(); self.now += 10 * m.DAY

    def test_read_only_scan_never_creates_state_or_backdates_arrival(self):
        p = self.file()
        report, _ = self.a.scan()
        self.assertEqual(report['eligible'], []); self.assertFalse(self.state.exists())
        self.assertTrue(p.exists())

    def test_ten_full_days_and_only_then_expire(self):
        p = self.file(); self.a.observe(); self.now += 10 * m.DAY - 1
        self.assertEqual(self.a.expire()['removed'], 0)
        self.now += 1
        self.assertEqual(self.a.expire()['removed'], 1); self.assertFalse(p.exists())
        self.assertTrue(self.root.exists())
        stages = [json.loads(l)['stage'] for l in next(self.state.glob('deletions-*.jsonl')).read_text().splitlines()]
        self.assertEqual(stages, ['attempt', 'removed'])

    def test_repeated_observation_does_not_extend_idle_files(self):
        self.file(); self.a.observe(); self.now += 9 * m.DAY; self.a.observe(); self.now += m.DAY
        self.assertEqual(self.a.expire()['removed'], 1)

    def test_new_file_in_old_archive_gets_its_own_ten_days(self):
        old = self.file(); self.age(); new = self.file('new.txt')
        self.assertEqual(self.a.expire()['removed'], 1)
        self.assertFalse(old.exists()); self.assertTrue(new.exists())

    def test_edit_restarts_inactivity(self):
        p = self.file(); self.age(); p.write_bytes(b'new content')
        self.assertEqual(self.a.expire()['removed'], 0)
        self.now += 10 * m.DAY
        self.assertEqual(self.a.expire()['removed'], 1)

    def test_access_time_change_restarts_inactivity(self):
        p = self.file(); self.age(); os.utime(p, (self.now, p.stat().st_mtime))
        self.assertEqual(self.a.expire()['removed'], 0)

    def test_backdated_edit_is_still_a_change(self):
        p = self.file(); self.age(); p.write_bytes(b'edited and backdated')
        os.utime(p, (900000000, 900000000))
        self.assertEqual(self.a.expire()['removed'], 0)

    def test_open_file_is_retained(self):
        p = self.file(); self.age(); self.opened = {p}
        self.assertEqual(self.a.expire()['removed'], 0); self.assertTrue(p.exists())

    def test_open_directory_protects_descendants(self):
        p = self.file('case/sub/f.txt'); self.age(); self.opened = {p.parent.parent}
        self.assertEqual(self.a.expire()['removed'], 0)

    def test_spotlight_use_is_respected(self):
        p = self.file(); self.age(); self.used = {p: self.now - m.DAY}
        self.assertEqual(self.a.expire()['removed'], 0)

    def test_folder_use_protects_descendants(self):
        self.file('case/f.txt'); self.age(); self.used = {self.root / 'case': self.now}
        self.assertEqual(self.a.expire()['removed'], 0)

    def test_explicit_touch_protects_reused_case(self):
        p = self.file('case/f.txt'); self.age(); result = self.a.observe(p.parent)
        self.assertEqual(result['eligible'], []); self.assertEqual(result['touched'], 1)
        self.assertEqual(self.a.expire()['removed'], 0)

    def test_protected_unicode_and_secret_files_survive(self):
        good = self.file('case/disposable.txt')
        keep = [self.file('case/契約書.txt'), self.file('case/' + unicodedata.normalize('NFD', '証拠') + '.txt'),
                self.file('case/.env.local')]
        self.age(); self.assertEqual(self.a.expire()['removed'], 1)
        self.assertFalse(good.exists()); self.assertTrue(all(p.exists() for p in keep))

    def test_git_worktree_and_keep_marker_are_not_deleted(self):
        p = self.file('case/source.txt'); self.file('case/.git')
        q = self.file('held/file.txt'); self.file('held/.devpurge-keep')
        self.age(); self.assertEqual(self.a.expire()['removed'], 0)
        self.assertTrue(p.exists() and q.exists())

    def test_exclusion_applies_to_descendants(self):
        p = self.file('client/file.txt'); self.a.exclude = (self.root / 'client',)
        self.age(); self.assertEqual(self.a.expire()['removed'], 0); self.assertTrue(p.exists())

    def test_symlinks_and_hardlinks_are_retained(self):
        outside = self.home / 'outside'; outside.mkdir(); f = outside / 'file'; f.write_text('retain')
        (self.root / 'dir-link').symlink_to(outside, target_is_directory=True)
        (self.root / 'file-link').symlink_to(f)
        os.link(f, self.root / 'hard-link')
        self.age(); self.assertEqual(self.a.expire()['removed'], 0)
        self.assertEqual(f.read_text(), 'retain')

    def test_changed_since_selected_scan_is_refused(self):
        p = self.file(); self.age(); plan, _ = self.a.scan(); p.write_text('changed')
        with self.assertRaises(ValueError): self.a.expire(plan['digest'])
        self.assertEqual(p.read_text(), 'changed')

    def test_file_opened_between_scan_and_deletion_survives(self):
        p = self.file(); self.age(); calls = []
        def opens():
            calls.append(1); return {p} if len(calls) > 1 else set()
        self.a.opens = opens
        self.assertEqual(self.a.expire()['removed'], 0); self.assertTrue(p.exists())

    def test_parent_symlink_swap_is_refused(self):
        p = self.file('case/f'); self.age()
        outside = self.home / 'outside'; outside.mkdir(); (outside / 'f').write_text('outside')
        calls = []
        def opens():
            calls.append(1)
            if len(calls) == 2:
                p.parent.rename(self.home / 'saved-case'); (self.root / 'case').symlink_to(outside, target_is_directory=True)
            return set()
        self.a.opens = opens
        result = self.a.expire()
        self.assertEqual(result['removed'], 0); self.assertTrue(result['errors'])
        self.assertEqual((outside / 'f').read_text(), 'outside')

    def test_root_replacement_cannot_inherit_expired_state(self):
        self.file(); self.age(); self.root.rename(self.home / 'old-root'); self.root.mkdir(); p = self.file()
        self.assertEqual(self.a.expire()['removed'], 0); self.assertTrue(p.exists())

    def test_corrupt_state_and_nan_fail_closed(self):
        p = self.file(); self.age(); state = json.loads(self.a.state_path.read_text())
        state['entries']['old.txt']['seen'] = float('nan'); self.a.state_path.write_text(json.dumps(state))
        with self.assertRaises(ValueError): self.a.expire()
        self.assertTrue(p.exists())

    def test_state_symlink_is_refused(self):
        self.file(); self.state.mkdir(); target = self.home / 'important'; target.write_text('untouched')
        self.a.state_path.symlink_to(target)
        with self.assertRaises(ValueError): self.a.observe()
        self.assertEqual(target.read_text(), 'untouched')

    def test_missing_usage_or_open_information_fails_closed(self):
        p = self.file(); self.age()
        def fail(*args): raise RuntimeError('not available')
        self.a.usage = fail
        with self.assertRaises(RuntimeError): self.a.expire()
        self.assertTrue(p.exists())

    def test_trash_mode_moves_instead_of_permanent_delete(self):
        p = self.file(); self.age(); result = self.a.expire(trash=True)
        self.assertEqual(result['removed'], 0); self.assertEqual(result['trashed'], 1)
        self.assertFalse(p.exists()); self.assertEqual(next((self.home / '.Trash').iterdir()).read_bytes(), b'fixture only')

    def test_trash_symlink_cannot_escape(self):
        p = self.file(); self.age(); outside = self.home / 'outside'; outside.mkdir()
        (self.home / '.Trash').symlink_to(outside, target_is_directory=True)
        result = self.a.expire(trash=True)
        self.assertTrue(result['errors']); self.assertTrue(p.exists()); self.assertEqual(list(outside.iterdir()), [])

    def test_no_repeat_deletion_and_removed_entries_are_pruned(self):
        self.file(); self.age(); self.assertEqual(self.a.expire()['removed'], 1)
        self.assertEqual(self.a.expire()['removed'], 0)
        self.assertEqual(json.loads(self.a.state_path.read_text())['entries'], {})

    def test_hardlinked_journal_fails_before_deletion(self):
        p = self.file(); self.age()
        other = self.home / 'other'; other.write_text('unchanged')
        log = self.state / ('deletions-' + m.dt.datetime.now().strftime('%Y%m') + '.jsonl')
        os.link(other, log)
        with self.assertRaises(ValueError): self.a.expire()
        self.assertTrue(p.exists()); self.assertEqual(other.read_text(), 'unchanged')

    def test_dangerous_root_and_zero_days_are_refused(self):
        for root in (self.home, self.home / 'Desktop', self.home.parent):
            with self.assertRaises(ValueError): m.Archive(self.home, root, self.state)
        with self.assertRaises(ValueError): m.Archive(self.home, self.root, self.state, 0)


if __name__ == '__main__':
    unittest.main()
