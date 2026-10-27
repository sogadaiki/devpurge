"""Expanded discovery must never turn size or a label into deletion authority."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib'))
import studio
import expanded_scope as scope
import cleanup_assistant


class ExpandedScopeTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name).resolve();self.s=studio.Studio(self.home)
        self.project=self.home/'Desktop/development/example'

    def directory(self,relative):
        p=self.home/relative;p.mkdir(parents=True,exist_ok=True);return p

    def symbols(self):
        p=self.directory('Library/Developer/Xcode/iOS DeviceSupport/iPhone16,1 27.0.1 (24A446)')
        (p/'arm64e/Symbols').mkdir(parents=True)
        return p

    def test_hidden_worktree_discovery_without_history_or_links(self):
        wanted=[self.directory(x) for x in ('.codex/worktrees/one/app/.next',
            'Desktop/development/example/.claude/worktrees/two/app/.open-next',
            'Desktop/development/example/.worktrees/three/app/.next')]
        secret=self.directory('.claude/projects/history/.next')
        (self.project/'linked').symlink_to(secret.parent,target_is_directory=True)
        found={x[0] for x in scope.discover(self.s)}
        self.assertTrue(set(wanted)<=found);self.assertNotIn(secret,found)

    def test_unknown_large_directory_is_not_authority(self):
        p=self.directory('Library/Caches/unknown')
        with self.assertRaises(ValueError):scope.evidence(self.s,p)

    def test_device_symbol_layout_and_process_guard(self):
        p=self.symbols()
        with patch.object(scope,'process_guard') as guard:
            self.assertEqual(scope.evidence(self.s,p)['kind'],'device-symbol-cache')
            guard.assert_called_once_with(scope.XCODE_PROCESSES)
        (p/'original.mov').write_bytes(b'original')
        with self.assertRaises(ValueError):scope.evidence(self.s,p)

    def test_active_device_debugger_keeps(self):
        with patch.object(scope.care,'run',return_value=subprocess.CompletedProcess([],0,'/usr/bin/debugserver\n','')):
            with self.assertRaises(ValueError):scope.evidence(self.s,self.symbols())

    def test_process_names_do_not_confuse_codex_with_vscode(self):
        with patch.object(scope.care,'run',return_value=subprocess.CompletedProcess([],0,'/Applications/Codex.app/codex\n','')):
            scope.process_guard(('code','shipit'))

    def test_symbols_symlink_rejected_by_full_local_check(self):
        p=self.symbols();(p/'arm64e/Symbols/link').symlink_to(self.home)
        with patch.object(scope,'process_guard'),self.assertRaises(ValueError):
            cleanup_assistant.Assistant(self.s).local_check({'path':str(p)})

    def test_shader_requires_retained_source(self):
        p=self.directory('Desktop/development/example/.godot/shader_cache')
        with self.assertRaises(ValueError):scope.evidence(self.s,p)

    def test_imported_assets_remain_review_only(self):
        p=self.directory('Desktop/development/example/.godot/imported')
        self.assertEqual(next(x for x in scope.discover(self.s) if x[0]==p)[-1],'review')
        with self.assertRaises(ValueError):scope.evidence(self.s,p)

    def test_xcode_requires_valid_workspace_and_ignored_output(self):
        p=self.directory('Desktop/development/example/derived/ModuleCache.noindex')
        info=p.parent/'info.plist';info.write_bytes(b'broken')
        with self.assertRaises(ValueError):scope.evidence(self.s,p)
        workspace=self.directory('Desktop/development/example/App.xcodeproj')
        info.write_bytes(plistlib.dumps({'WorkspacePath':str(workspace)}))
        with patch.object(scope.care,'run',return_value=subprocess.CompletedProcess([],1,'','')):
            with self.assertRaises(ValueError):scope.evidence(self.s,p)
        with patch.object(scope.care,'run',return_value=subprocess.CompletedProcess([],0,'','')),patch.object(scope,'process_guard'),patch.object(scope.care,'activity',return_value={}),patch.object(scope.care,'open_under',return_value=False):
            self.assertEqual(scope.evidence(self.s,p)['kind'],'xcode-build-cache')


if __name__=='__main__':unittest.main()
