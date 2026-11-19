"""Run the resource bundled for Finder launches, away from the source checkout."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("headroom_installer", ROOT / "headroom/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class WorkspaceBundleTest(unittest.TestCase):
    def test_configured_projects_and_protections_in_bundled_backend(self):
        with tempfile.TemporaryDirectory(prefix="余白 bundle ") as temp:
            root = Path(temp).resolve()
            contents = root / "余白.app/Contents"
            installer.bundle_workspace_backend(ROOT, contents)
            script = contents / "Resources/devpurge/lib/workspaces.py"
            home = root / "home"
            projects = home / "Desktop/development"
            projects.mkdir(parents=True)
            env = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}

            def run_backend(*args):
                result = subprocess.run(
                    ["/usr/bin/python3", "-E", "-s", "-B", "-S", script, "--json", *args],
                    cwd=root, env=env, text=True, capture_output=True, timeout=30,
                )
                return result.returncode, json.loads(result.stdout)

            code, empty = run_backend("--configured-only")
            self.assertEqual((code, empty["projects"]), (0, []))
            allowed, excluded = projects / "project A", projects / "project B"
            for repo in (allowed, excluded):
                subprocess.run(["/usr/bin/git", "init", "--quiet", "-b", "main", repo], check=True, env=env)
                subprocess.run(["/usr/bin/git", "-C", repo, "-c", "user.name=test",
                                "-c", "user.email=test@example.test", "commit", "--quiet",
                                "--allow-empty", "-m", "base"], check=True, env=env)
            (home / ".devpurgerc").write_text(
                f"workspace_project={allowed}\nworkspace_project={excluded}\n"
                f"exclude={excluded}\nprotect=confidential-sample\n"
            )
            code, inventory = run_backend("--configured-only")
            self.assertEqual(code, 0, inventory)
            self.assertEqual([p["repo"] for p in inventory["projects"]], [str(allowed), str(excluded)])
            self.assertEqual([p["metadata_only"] for p in inventory["projects"]], [False, True])
            branch = inventory["projects"][1]["branches"][0]
            code, held = run_backend(excluded, "--retire-branch", branch["name"], branch["head"])
            self.assertEqual((code, held["status"]), (1, "held"))
            self.assertIn("除外", held["reason"])

            left, right = projects / "copy", projects / "original"
            for folder in (left, right):
                folder.mkdir()
                (folder / "note.txt").write_text("retained content")
            code, match = run_backend("--compare", left, right)
            self.assertEqual((code, match["status"], match["matched_files"]), (0, "match", 1))
            (left / "confidential-sample.txt").write_text("protected content")
            code, incomplete = run_backend("--compare", left, right)
            self.assertEqual((code, incomplete["status"]), (2, "incomplete"))


if __name__ == "__main__":
    unittest.main()
