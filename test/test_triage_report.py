"""Exercise report-only degradation without network, notifications or cleanup."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("triage_report", ROOT / "scripts/triage-report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class TriageReportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="devpurge-triage-test-")
        self.root = Path(self.tmp.name)
        self.scan = {"items": [
            {"path": "/fixture/wt", "tier": "worktree", "deletable": True,
             "bytes": 2 * 1024**3, "description": "worktree: old"},
            {"path": "/fixture/clip-v2.mp4", "tier": "review", "deletable": False,
             "bytes": 1024**3, "description": "older version (newest: clip-v3.mp4)"},
        ]}
        (self.root / "scan.json").write_text(json.dumps(self.scan))
        (self.root / "quarantine.txt").write_text("expires after 30 days\nQ001 1G 24d held /fixture\n")
        (self.root / "removed-worktrees.tsv").write_text(
            "999999\tr\tw\tb\tsha\tremoved\n999999\tr\tx\tb\tsha\tfailed\n"
            "1\tr\told\tb\tsha\tremoved\n999999\tr\tattempt\tb\tsha\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_counts_only_confirmed_recent_results_and_warns_on_expiry(self):
        result = report.render(self.root, now=1000000)
        self.assertIn("確認済み成功 1件", result)
        self.assertIn("1件・2.0 GiB", result)
        self.assertIn("表示候補 1件・1.0 GiB", result)
        self.assertIn("期限切れ・7日以内: Q001", result)
        self.assertLessEqual(len(result), 1800)

    def test_missing_quarantine_output_is_unknown(self):
        (self.root / "quarantine.txt").write_text("")
        self.assertIn("状態の確認が必要", report.render(self.root, now=1000000))

    def test_dry_run_falls_back_when_ai_authentication_fails(self):
        scanner = self.root / "scan-stub"
        scanner.write_text('#!/bin/bash\ncase "$1" in\n--json) cat "${FIXTURE_SCAN}";;\nquarantine) echo "Quarantine is empty.";;\n*) exit 91;;\nesac\n')
        scanner.chmod(0o700)
        ai = self.root / "ai-stub"
        ai.write_text('#!/bin/bash\necho \'{"is_error":true,"result":"OAuth session expired"}\'\nexit 1\n')
        ai.chmod(0o700)
        env = dict(os.environ, DEVPURGE_TRIAGE_DRY="1", DEVPURGE_BIN=str(scanner),
                   DEVPURGE_TRIAGE_CLAUDE_BIN=str(ai), FIXTURE_SCAN=str(self.root / "scan.json"),
                   DEVPURGE_TRIAGE_WORK_DIR=str(self.root / "work"),
                   DEVPURGE_LOG_DIR=str(self.root / "logs"))
        run = subprocess.run(["/bin/bash", str(ROOT / "scripts/triage-weekly.sh")],
                             env=env, capture_output=True, text=True, check=True)
        self.assertIn("[DRY]", run.stdout)
        self.assertIn("AI分析が利用できない", run.stdout)
        self.assertIn("確認済み成功 0件", run.stdout)
        self.assertTrue((self.root / "work/report.md").is_file())


if __name__ == "__main__":
    unittest.main()
