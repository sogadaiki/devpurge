import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import workspace_branch


class BranchRetirementTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.logs = self.root / 'logs'
        env = patch.dict(os.environ, {'DEVPURGE_LOG_DIR': str(self.logs)})
        env.start()
        self.addCleanup(env.stop)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        self.git('commit', '-qm', 'first', '--allow-empty')
        self.sha = self.git('rev-parse', 'HEAD')
        self.git('branch', 'topic', self.sha)
        self.git('commit', '-qm', 'second', '--allow-empty')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def retire(self, name='topic', sha=None):
        return workspace_branch.retire_branch(self.repo, name, self.sha if sha is None else sha)

    def test_stale_sha_checked_out_and_recovery_log_hold(self):
        self.assertEqual(self.retire(sha=self.git('rev-parse', 'HEAD'))['status'], 'held')
        self.git('worktree', 'add', '-q', str(self.root / 'copy'), 'topic')
        self.assertEqual(self.retire()['status'], 'held')
        self.git('worktree', 'remove', str(self.root / 'copy'))
        self.logs.mkdir()
        (self.logs / 'removed-worktrees-1.tsv').write_text(f'1\t{self.repo}\t/former\ttopic\t{self.sha}\n')
        self.assertEqual(self.retire()['status'], 'held')
        self.assertEqual(self.git('rev-parse', 'topic'), self.sha)

    def test_out_of_date_cached_default_and_unmerged_upstream_hold(self):
        self.git('branch', 'new', 'HEAD')
        self.git('update-ref', 'refs/remotes/origin/main', self.sha)
        self.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
        self.assertEqual(self.retire('new', self.git('rev-parse', 'new'))['status'], 'held')
        self.git('symbolic-ref', '--delete', 'refs/remotes/origin/HEAD')
        self.git('branch', '--set-upstream-to=topic', 'new')
        self.assertEqual(self.retire('new', self.git('rev-parse', 'new'))['status'], 'held')

    def test_delete_packed_branch_keep_pin_and_log_once(self):
        self.git('pack-refs', '--all')
        result = self.retire()
        # Older Git cannot install the per-command additive prepared hook; hold safely.
        cap = subprocess.run(['git', '-C', str(self.repo), 'hook', 'list', '-z', 'reference-transaction'],
                             capture_output=True)
        if cap.returncode not in (0, 1):
            self.assertEqual(result['status'], 'held')
            self.skipTest('Git has no configurable reference-transaction hook')
        self.assertEqual(result['status'], 'retired', result)
        self.assertEqual(self.git('rev-parse', 'refs/devpurge/retired-branches/' + self.sha), self.sha)
        self.assertNotIn('topic', self.git('branch', '--format=%(refname:short)').splitlines())
        self.assertEqual(self.retire()['status'], 'held')
        records = [line for f in self.logs.glob('deleted-branches-*.tsv') for line in f.read_text().splitlines()]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].split('\t')[1:], [str(self.repo), 'topic', self.sha])

    def test_actual_race_after_preflight_is_vetoed_by_prepared_hook(self):
        original = workspace_branch._git
        replacement = self.git('rev-parse', 'main')
        def race(path, *args, **kwargs):
            if ('branch', '-d', '--', 'topic') == args[-4:]:
                self.git('update-ref', 'refs/heads/topic', replacement, self.sha)
            return original(path, *args, **kwargs)
        with patch('workspace_branch._git', side_effect=race):
            self.assertEqual(self.retire()['status'], 'held')
        supported = subprocess.run(['git', '-C', str(self.repo), 'hook', 'list', '-z', 'reference-transaction'],
                                   capture_output=True)
        if supported.returncode in (0, 1):
            self.assertEqual(self.git('rev-parse', 'topic'), replacement)

    def test_post_deletion_readback_failure_stays_unverified(self):
        original = workspace_branch._git
        deleted = False
        def fail_readback(path, *args, **kwargs):
            nonlocal deleted
            if deleted and args[0] == 'show-ref':
                raise workspace_branch.InventoryError('simulated failure')
            result = original(path, *args, **kwargs)
            if ('branch', '-d', '--', 'topic') == args[-4:]:
                deleted = True
            return result
        with patch('workspace_branch._git', side_effect=fail_readback):
            result = self.retire()
        if not deleted:
            self.skipTest('Native branch deletion unavailable')
        self.assertEqual(result['status'], 'unverified')


if __name__ == '__main__':
    unittest.main()
