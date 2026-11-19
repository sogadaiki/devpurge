import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import workspace_folders as wf


class WorkspaceFolderTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name).resolve()
        home = patch('pathlib.Path.home', return_value=self.home)
        home.start()
        self.addCleanup(home.stop)
        self.repo = self.home / 'Desktop/development/app'
        self.repo.mkdir(parents=True)
        self.shared = self.repo.parent / '.worktrees'

    def folder(self, base, name):
        path = base / name
        path.mkdir(parents=True)
        return path

    def rows(self, registered=()):
        report = wf.discover([self.repo], set(registered))
        return {Path(row['path']): row for row in report['folders']}

    def test_shared_folders_need_evidence_and_registered_paths_are_skipped(self):
        direct = self.folder(self.repo, '.claude/worktrees/feature')
        copy = self.folder(self.repo, 'app-copy-2')
        ambiguous = self.folder(self.shared, 'app-copy')
        backup = self.folder(self.shared, 'state-before-deploy')
        ordinary = self.folder(self.shared, 'app-resembles-repo')
        original = self.folder(self.repo, 'application-source')
        registered = self.folder(self.home, '.codex/worktrees/456/app')
        other = self.folder(self.home, '.codex/worktrees/789/other')
        (other / '.git').write_text('gitdir: /another/repo/.git/worktrees/other\n')
        rows = self.rows([registered])
        self.assertEqual(set(rows), {direct, copy, ambiguous, backup, ordinary, other})
        self.assertEqual(rows[direct]['project'], str(self.repo))
        self.assertEqual(rows[copy]['kind'], 'copy')
        self.assertEqual(rows[backup]['kind'], 'rollback')
        self.assertIsNone(rows[ambiguous]['project'])
        self.assertIsNone(rows[ordinary]['project'])
        self.assertEqual(rows[other]['kind'], 'other-worktree')
        self.assertIsNone(rows[other]['project'])
        self.assertTrue(original.exists())

    def test_known_lane_with_registered_sibling_and_retained_build_folders(self):
        lanes = self.repo.parent / 'app-lanes'
        active = self.folder(lanes, 'active')
        old_copy = self.folder(lanes, 'old-copy')
        keeper = self.folder(self.repo, 'build/retained-worktrees/keeper')
        elsewhere = self.folder(self.repo.parent, 'other-lanes/old-copy')
        rows = self.rows([active])
        self.assertEqual(rows[old_copy]['project'], str(self.repo))
        self.assertEqual(rows[keeper]['kind'], 'retained')
        self.assertNotIn(active, rows)
        self.assertNotIn(elsewhere, rows)

    def test_git_pointer_requires_trusted_owner_and_regular_bounded_marker(self):
        folder = self.folder(self.shared, 'actual')
        admin = self.folder(self.repo, '.git/worktrees/actual')
        marker = folder / '.git'
        marker.write_text('gitdir: ' + os.path.relpath(admin, folder) + '\n')
        (admin / 'gitdir').write_text(str(marker) + '\n')
        clone = self.folder(self.shared, 'clone')
        self.folder(clone, '.git/objects')
        (clone / '.git/HEAD').write_text('ref: refs/heads/main\n')
        broken = self.folder(self.shared, 'old-path')
        (broken / '.git').write_text('gitdir: ' + str(admin.parent / 'removed') + '\n')
        other = self.folder(self.shared, 'duplicate-pointer')
        (other / '.git').write_text('gitdir: ' + str(admin) + '\n')
        suspicious = self.folder(self.shared, 'redirect')
        (suspicious / '.git').symlink_to(marker)
        rows = self.rows()
        self.assertEqual(rows[clone]['kind'], 'independent-repo')
        self.assertEqual(rows[folder]['project'], str(self.repo))
        self.assertEqual(rows[broken]['kind'], 'unlisted-worktree')
        self.assertIn('異なり', rows[other]['reason'])
        self.assertEqual(rows[suspicious]['kind'], 'unknown')
        self.assertNotIn(folder, self.rows([folder]))

    def test_protected_scopes_and_partial_limits(self):
        kept = self.folder(self.shared, 'kept')
        (kept / '.devpurge-keep').touch()
        outside = self.folder(self.home, 'elsewhere')
        (self.shared / 'redirect').symlink_to(outside, target_is_directory=True)
        self.folder(self.shared, 'credentials')
        self.folder(self.repo, '.worktrees/private')
        (self.repo / '.devpurge-keep').touch()
        excluded = self.folder(self.shared, 'excluded')
        (self.home / '.devpurgerc').write_text('exclude=' + str(excluded) + '\n')
        self.assertEqual(self.rows(), {})
        self.folder(self.shared, 'plain')
        with patch.object(wf, '_MAX_ENTRIES', 0):
            report = wf.discover([self.repo], set())
        self.assertTrue(report['warnings'])
        self.assertEqual(report['folders'], [])


if __name__ == '__main__':
    unittest.main()
