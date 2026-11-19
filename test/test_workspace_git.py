import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from workspace_git import InventoryError, inventory


class GitInventoryTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.repo = self.root / 'project'
        self.repo.mkdir()
        self.logs = self.root / 'logs'
        env = patch.dict(os.environ, {'DEVPURGE_LOG_DIR': str(self.logs), 'GIT_CONFIG_GLOBAL': '/dev/null',
                                      'GIT_CONFIG_NOSYSTEM': '1'})
        env.start()
        self.addCleanup(env.stop)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        (self.repo / 'version').write_text('one')
        self.git('add', 'version')
        self.git('commit', '-qm', 'first')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *map(str, args)],
                                       stderr=subprocess.DEVNULL).decode().strip()

    def test_intersection_of_local_remote_and_protection(self):
        start = self.git('rev-parse', 'HEAD')
        for branch in ('complete', 'restored', 'develop'):
            self.git('branch', branch)
        self.git('update-ref', 'refs/remotes/origin/main', start)
        self.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
        (self.repo / 'version').write_text('two')
        self.git('commit', '-qam', 'second')
        self.git('branch', 'local-only')
        self.logs.mkdir()
        (self.logs / 'removed-worktrees-1.tsv').write_text(f'1\t{self.repo}\t/former\trestored\t{start}\n')
        linked = self.root / 'linked space'
        self.git('worktree', 'add', '-q', linked, 'complete')
        self.git('worktree', 'lock', linked)
        unusual = self.root / 'split\npath'
        self.git('worktree', 'add', '-q', '--detach', unusual)
        result = inventory(self.repo)
        rows = {row['name']: row for row in result['branches']}
        self.assertEqual(result['base'], 'refs/heads/main')
        self.assertTrue(rows['complete']['checked_out'])
        self.assertTrue(rows['complete']['merged'])
        self.assertFalse(rows['local-only']['merged'])
        self.assertFalse(rows['local-only']['checked_out'])
        self.assertTrue(all(rows[n]['protected'] for n in ['main', 'develop', 'restored']))
        self.assertFalse(rows['complete']['protected'])
        wt = {row['path']: row for row in result['worktrees']}
        self.assertIn(str(unusual), wt)
        self.assertEqual(wt[str(linked)]['status'], 'locked')
        self.assertEqual(wt[str(self.repo)]['status'], 'clean')
        self.assertTrue(wt[str(self.repo)]['primary'])

    def test_missing_or_replaced_checkout_cannot_look_clean(self):
        linked = self.root / 'linked'
        self.git('worktree', 'add', '-qb', 'gone', linked)
        shutil.rmtree(linked)
        result = inventory(self.repo)
        row = next(x for x in result['worktrees'] if x['branch'] == 'gone')
        self.assertEqual((row['present'], row['prunable'], row['status']), (False, True, 'missing'))
        self.assertTrue(next(b for b in result['branches'] if b['name'] == 'gone')['checked_out'])
        linked.mkdir()
        subprocess.run(['git', 'init', '-qb', 'gone', str(linked)], check=True)
        result = inventory(self.repo)
        self.assertEqual(next(x for x in result['worktrees'] if x['branch'] == 'gone')['status'], 'unknown')
        self.assertTrue(result['warnings'])

    def test_tracked_disk_state_uses_metadata_without_clean_filters_or_new_index(self):
        marker = self.root / 'filter-ran'
        (self.repo / '.gitattributes').write_text('version filter=observe\n')
        self.git('add', '.gitattributes')
        self.git('commit', '-qm', 'attrs')
        self.git('config', 'filter.observe.clean', 'touch ' + shlex.quote(str(marker)) + ' && cat')
        index = self.repo / '.git/index'
        index_before = (index.stat().st_mtime_ns, index.read_bytes())
        (self.repo / 'version').write_text('new')
        self.assertEqual(inventory(self.repo)['worktrees'][0]['status'], 'unknown')
        (self.repo / 'version').write_text('much longer')
        self.assertEqual(inventory(self.repo)['worktrees'][0]['status'], 'dirty')
        self.assertFalse(marker.exists())
        self.assertEqual(index_before, (index.stat().st_mtime_ns, index.read_bytes()))
        self.git('update-index', '--assume-unchanged', 'version')
        self.assertEqual(inventory(self.repo)['worktrees'][0]['status'], 'unknown')
        (self.repo / 'untracked').touch()
        self.assertEqual(inventory(self.repo)['worktrees'][0]['status'], 'dirty')

    def test_unknown_evidence_is_preserved(self):
        self.logs.mkdir()
        (self.logs / 'removed-worktrees-1.tsv').write_text('partial row')
        self.git('branch', 'topic')
        self.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/missing')
        result = inventory(self.repo)
        self.assertTrue(result['warnings'])
        self.assertTrue(all(b['protected'] and b['merged'] is None for b in result['branches']))
        with self.assertRaises(InventoryError):
            inventory(self.root)

    def test_holds_blocked_primary_link_and_registered_protected_paths(self):
        link = self.root / 'alias'
        link.symlink_to(self.repo)
        with self.assertRaises(InventoryError):
            inventory(link)
        protected = self.root / 'sadame'
        self.git('worktree', 'add', '-qb', 'hold', protected)
        with patch('workspace_git._working_state', wraps=__import__('workspace_git')._working_state) as state:
            report = inventory(self.repo)
            self.assertEqual([x.args[0] for x in state.call_args_list], [self.repo])
        row = next(x for x in report['worktrees'] if x['branch'] == 'hold')
        self.assertEqual(row['status'], 'unknown')
        self.assertIsNone(row['present'])
        with patch('workspace_git._git', side_effect=AssertionError('Git invoked inside a protected root')):
            with self.assertRaises(InventoryError):
                inventory(protected)

    def test_explicit_cleaning_exclusion_allows_only_primary_git_metadata(self):
        self.git('branch', 'retained')
        with patch('workspace_git.Studio.blocked', return_value=True), \
             patch('workspace_git._inspect', side_effect=AssertionError('checkout scanned')):
            report = inventory(self.repo)
        self.assertTrue(report['warnings'])
        self.assertTrue(report['metadata_only'])
        self.assertEqual(len(report['worktrees']), 1)
        self.assertEqual(report['worktrees'][0]['status'], 'unknown')
        self.assertEqual({row['name'] for row in report['branches']}, {'main', 'retained'})
        self.assertTrue(all(row['protected'] for row in report['branches']))

    def test_local_copy_of_remote_default_takes_precedence_over_legacy_main(self):
        self.git('branch', 'trunk')
        self.git('update-ref', 'refs/remotes/origin/trunk', self.git('rev-parse', 'HEAD'))
        self.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/trunk')
        report = inventory(self.repo)
        self.assertEqual(report['base'], 'refs/heads/trunk')
        self.assertTrue(all(b['protected'] for b in report['branches']))

    def test_log_override_still_observes_default_recovery_rows(self):
        default = self.root / 'Library/Application Support/devpurge/logs'
        default.mkdir(parents=True)
        self.logs.mkdir()
        self.git('branch', 'kept')
        self.git('branch', 'also-kept')
        sha = self.git('rev-parse', 'HEAD')
        for folder, branch in [(default, 'kept'), (self.logs, 'also-kept')]:
            (folder / 'removed-worktrees-1.tsv').write_text(f'1\t{self.repo}\t/former\t{branch}\t{sha}\n')
        with patch('workspace_git.Path.home', return_value=self.root):
            report = inventory(self.repo)
        self.assertTrue(all(b['protected'] for b in report['branches']))

    def test_default_and_tracking_branch_ancestry_are_separate(self):
        first = self.git('rev-parse', 'HEAD')
        self.git('remote', 'add', 'origin', str(self.root / 'offline-remote.git'))
        self.git('commit', '-qm', 'second', '--allow-empty')
        latest = self.git('rev-parse', 'HEAD')
        self.git('update-ref', 'refs/remotes/origin/main', latest)
        self.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
        for branch, remote in [('ready', latest), ('behind-local', first), ('gone', first)]:
            self.git('branch', branch, latest)
            self.git('update-ref', 'refs/remotes/origin/' + branch, remote)
            self.git('branch', '--set-upstream-to=origin/' + branch, branch)
        self.git('update-ref', '-d', 'refs/remotes/origin/gone')
        self.git('branch', 'no-upstream')
        self.git('branch', 'unknown-remote')
        self.git('config', 'branch.unknown-remote.remote', 'absent')
        self.git('config', 'branch.unknown-remote.merge', 'refs/heads/not-fetched')
        self.git('branch', 'ambiguous')
        self.git('branch', '--set-upstream-to=origin/main', 'ambiguous')
        self.git('config', '--add', 'branch.ambiguous.merge', 'refs/heads/ready')
        rows = {row['name']: row for row in inventory(self.repo)['branches']}
        self.assertTrue(all(row['merged'] for row in rows.values()))
        self.assertTrue(rows['ready']['upstream_merged'])
        self.assertEqual(rows['behind-local']['upstream'], 'refs/remotes/origin/behind-local')
        self.assertFalse(rows['behind-local']['upstream_merged'])
        self.assertFalse(rows['no-upstream']['upstream_configured'])
        for branch in ['unknown-remote', 'gone', 'ambiguous']:
            self.assertTrue(rows[branch]['upstream_configured'])
            self.assertIsNone(rows[branch]['upstream_merged'])


if __name__ == '__main__':
    unittest.main()
