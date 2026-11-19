import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


CLI = Path(__file__).resolve().parents[1] / 'bin/devpurge'


class WorkspaceCLI(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name).resolve()
        self.repo = self.home / 'Desktop/development/sample'
        self.repo.mkdir(parents=True)
        self.env = {**os.environ, 'HOME': str(self.home), 'GIT_CONFIG_NOSYSTEM': '1'}
        def git(*args):
            subprocess.run(['git', '-C', str(self.repo), *args], env=self.env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
        git('init', '-b', 'main')
        git('-c', 'user.name=Example', '-c', 'user.email=test@example.invalid',
            'commit', '--allow-empty', '-m', 'initial')
        git('branch', 'task/<example>')

    def run_cli(self, *args):
        return subprocess.run([str(CLI), 'workspaces', *args], cwd=self.home, env=self.env,
                              capture_output=True, text=True, timeout=30)

    def test_formats_and_repeated_project(self):
        answer = self.run_cli('sample', 'sample', '--json')
        self.assertEqual(answer.returncode, 0, answer.stderr)
        [project] = json.loads(answer.stdout)['projects']
        self.assertEqual(len(project['worktrees']), 1)
        self.assertEqual(len(project['branches']), 2)
        html = self.run_cli('--html', 'sample')
        self.assertEqual(html.returncode, 0, html.stderr)
        self.assertIn('task/&lt;example&gt;', html.stdout)
        self.assertNotIn('task/<example>', html.stdout)
        self.assertIn('task/<example>', self.run_cli('--details', 'sample').stdout)

    def test_missing_project_does_not_hide_valid_results(self):
        response = self.run_cli('sample', 'missing', '--json')
        self.assertNotEqual(response.returncode, 0)
        data = json.loads(response.stdout)
        self.assertEqual(len(data['projects']), 1)
        self.assertEqual(data['failed_projects'], 1)
        self.assertTrue(data['warnings'])

    def test_action_requires_one_project(self):
        result = self.run_cli('sample', 'another', '--retire', str(self.repo))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.repo.is_dir())

    def test_private_weekly_report_requires_registration_and_preserves_last_success(self):
        output = self.home / 'workspaces.html'
        option = ('--refresh-report', str(self.home))
        self.assertEqual(self.run_cli(*option).returncode, 0)
        self.assertFalse(output.exists())
        rc = self.home / '.devpurgerc'
        rc.write_text(f'workspace_project={self.repo}\n')
        self.assertEqual(self.run_cli(*option).returncode, 0)
        before = output.read_bytes()
        self.assertIn(b'task/&lt;example&gt;', before)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.run_cli('--json').returncode, 0)
        rc.write_text(f'workspace_project={self.home}/missing\n')
        self.assertNotEqual(self.run_cli(*option).returncode, 0)
        self.assertEqual(output.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
