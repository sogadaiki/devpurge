import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))
import workspace_retire as wr
REAL_IDLE = wr.idle


class RetireTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name).resolve()
        self.repo = self.home / "primary repo"
        self.target = self.home / "linked project"
        self.repo.mkdir()
        self.call(self.repo, "init", "-q", "-b", "main")
        self.call(self.repo, "config", "user.name", "Fixture")
        self.call(self.repo, "config", "user.email", "fixture@example.invalid")
        (self.repo / "prototype").write_text("original")
        (self.repo / ".gitignore").write_text("ignored/\n")
        self.call(self.repo, "add", ".")
        self.call(self.repo, "commit", "-qm", "version one")
        self.call(self.repo, "worktree", "add", "-b", "feature/test", str(self.target))
        self.ref = self.call(self.repo, "rev-parse", "HEAD").strip()
        self.clock = time.time() + 10 * 86400
        self.addCleanup(patch.stopall)
        patch.object(wr, "user_home", return_value=self.home).start()
        patch.object(wr.time, "time", side_effect=lambda: self.clock).start()
        self.idle = patch.object(wr, "idle").start()
        patch.dict(os.environ, {"DEVPURGE_LOG_DIR": str(self.home / "logs"),
                                 "DEVPURGE_WORKTREE_AGE_DAYS": "7"}).start()

    def call(self, cwd, *args):
        return subprocess.run(["/usr/bin/git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout

    def held(self):
        report = wr.retire(self.repo, self.target)
        self.assertEqual(report["status"], "held", report)
        self.assertTrue(self.target.is_dir())
        return report

    def test_retire_matches_existing_branch_guard_and_recovery_command(self):
        self.idle.side_effect = REAL_IDLE
        report = wr.retire(self.repo, self.target, expected=("feature/test", self.ref))
        self.assertEqual(report["status"], "retired", report)
        self.assertTrue(report["verified"])
        self.assertFalse(self.target.exists())
        self.assertEqual(self.call(self.repo, "rev-parse", "feature/test").strip(), self.ref)
        pre = Path(report["record"]).read_text().strip().split("\t")
        self.assertEqual(pre[1:], [str(self.repo), str(self.target), "feature/test", self.ref])
        canonical = self.home / "Library/Application Support/devpurge/logs" / Path(report["record"]).name
        self.assertEqual(canonical.read_text(), Path(report["record"]).read_text())
        evidence = next((self.home / "logs").glob("worktree-removal-results-*.tsv"))
        self.assertEqual(evidence.read_text().splitlines()[0].split("\t"), pre + ["removed"])
        cmd = 'source "$1"; _dp_merged_branches "$2" main'
        deletable = subprocess.check_output(["/bin/bash", "-c", cmd, "fixture", str(LIB / "branches.sh"), str(self.repo)], text=True)
        self.assertNotIn("feature/test", deletable.splitlines())
        subprocess.run(wr.shlex.split(report["restore_command"]), check=True, capture_output=True)
        self.assertEqual((self.target / "prototype").read_text(), "original")

    def test_confirmation_holds_changed_commit_or_branch_at_same_path(self):
        for expected in (("feature/test", "0" * len(self.ref)), ("other-branch", self.ref)):
            result = wr.retire(self.repo, self.target, expected=expected)
            self.assertEqual(result["status"], "held", result)
            self.assertIn("確認したブランチ", result["reason"])
            self.assertTrue(self.target.is_dir())

    def test_holds_dirty_untracked_ignored_and_recent(self):
        file = self.target / "prototype"
        old = file.stat()
        file.write_text("altered!")
        os.utime(file, ns=(old.st_atime_ns, old.st_mtime_ns))
        self.held()
        file.write_text("original")
        extra = self.target / "untracked"
        extra.write_text("local")
        self.held()
        extra.unlink()
        ignored = self.target / "ignored"
        ignored.mkdir()
        (ignored / "local").write_text("keep")
        self.held()
        (ignored / "local").unlink()
        self.held()  # Git cannot retain an empty local directory.
        ignored.rmdir()
        self.clock -= 10 * 86400
        self.held()

    def test_respects_lock_detached_and_different_repository(self):
        self.call(self.repo, "worktree", "lock", str(self.target))
        self.held()
        self.call(self.repo, "worktree", "unlock", str(self.target))
        self.call(self.target, "checkout", "--detach", "-q")
        self.held()
        self.call(self.target, "switch", "feature/test")
        other = self.home / "other"
        other.mkdir()
        self.call(other, "init", "-q", "-b", "main")
        self.assertEqual(wr.retire(other, self.target)["status"], "held")
        self.assertEqual(wr.retire(self.repo, self.repo)["status"], "held")
        alias = self.home / "alias"
        alias.symlink_to(self.target)
        self.assertEqual(wr.retire(self.repo, alias)["status"], "held")

    def test_unmerged_branch_and_private_detached_commit_are_held(self):
        self.call(self.target, "commit", "--allow-empty", "-qm", "unique change")
        self.held()
        self.call(self.target, "reset", "--hard", self.ref)
        self.held()  # The reset tip is now reachable only through the target's reflog.

    def test_staged_skip_flags_and_exclusions_are_held(self):
        self.call(self.target, "update-index", "--assume-unchanged", "prototype")
        self.held()
        self.call(self.target, "update-index", "--no-assume-unchanged", "prototype")
        (self.target / "new").write_text("stage")
        self.call(self.target, "add", "new")
        self.held()
        self.call(self.target, "reset", "--hard", self.ref)
        (self.home / ".devpurgerc").write_text("exclude=" + str(self.target / "prototype") + "\n")
        self.held()
        (self.home / ".devpurgerc").write_text("protect=linked project\n")
        self.held()

    def test_busy_and_failure_to_record_block_removal(self):
        self.idle.side_effect = ValueError("open by editor")
        self.held()
        self.idle.side_effect = None
        (self.home / "logs").symlink_to(self.target, target_is_directory=True)
        self.held()

    def test_rechecks_ignored_file_between_proof_and_git_remove(self):
        def add_local_file(_):
            if self.idle.call_count == 2:
                (self.target / "ignored").mkdir()
                (self.target / "ignored" / "local").write_text("must survive")
        self.idle.side_effect = add_local_file
        self.held()
        self.assertEqual((self.target / "ignored/local").read_text(), "must survive")

    def test_actual_open_worktree_is_held(self):
        sleeper = subprocess.Popen(["/bin/sleep", "30"], cwd=self.target)
        try:
            self.idle.side_effect = REAL_IDLE
            self.assertIn("使用中", self.held()["reason"])
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=5)

    def test_post_removal_journal_failure_is_unverified(self):
        append = wr.append_record
        def fail_result(folder, name, line):
            if "removal-results" in name:
                raise OSError("simulated full disk")
            return append(folder, name, line)
        with patch.object(wr, "append_record", side_effect=fail_result):
            result = wr.retire(self.repo, self.target)
        self.assertFalse(self.target.exists())
        self.assertEqual(result["status"], "unverified")
        self.assertEqual(self.call(self.repo, "rev-parse", "feature/test").strip(), self.ref)

    def test_check_only_does_not_create_recovery_journal_or_change_index(self):
        index = Path(self.call(self.target, "rev-parse", "--absolute-git-dir").strip()) / "index"
        before = (index.read_bytes(), index.stat().st_mtime_ns)
        result = wr.retire(self.repo, self.target, check_only=True)
        self.assertEqual(result["status"], "eligible", result)
        self.assertEqual(result["head"], self.ref)
        self.assertEqual((index.read_bytes(), index.stat().st_mtime_ns), before)
        self.assertFalse((self.home / "logs").exists())
        self.assertFalse((self.home / "Library").exists())
        self.assertTrue(self.target.is_dir())
        (self.repo / ".devpurge-keep").touch()
        self.assertEqual(wr.retire(self.repo, self.target, check_only=True)["status"], "held")
        self.held()
        self.assertFalse((self.home / "Library").exists())

    def test_origin_default_and_local_default_must_both_contain_branch(self):
        self.call(self.repo, "commit", "--allow-empty", "-qm", "needs push")
        ahead = self.call(self.repo, "rev-parse", "HEAD").strip()
        self.call(self.repo, "branch", "trunk", ahead)
        self.call(self.target, "merge", "--ff-only", "main")
        self.call(self.repo, "update-ref", "refs/remotes/origin/trunk", self.ref)
        self.call(self.repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        self.assertEqual(wr.retire(self.repo, self.target, check_only=True)["status"], "held")
        self.held()
        self.call(self.repo, "update-ref", "refs/remotes/origin/trunk", ahead)
        self.call(self.repo, "reset", "--hard", self.ref)
        result = wr.retire(self.repo, self.target, check_only=True)
        self.assertEqual(result["status"], "eligible", result)
        self.assertEqual(result["integration_ref"], "refs/heads/trunk")


if __name__ == "__main__":
    unittest.main()
