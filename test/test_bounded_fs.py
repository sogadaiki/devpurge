import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib'))
import bounded_fs
import studio


class BoundedListingTests(unittest.TestCase):
    def test_children_are_bounded_and_links_not_followed(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw).resolve();(root/'directory').mkdir();(root/'file').write_text('fixture');(root/'link').symlink_to(root/'directory')
            names,limited=bounded_fs.listing(root,dirs_only=True)
            self.assertEqual(names,[root/'directory']);self.assertFalse(limited)
            names,limited=bounded_fs.listing(root,limit=1)
            self.assertLessEqual(len(names),1);self.assertTrue(limited)

    def test_blocked_child_times_out_without_blocking_parent(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw).resolve();worker=root/'reader.py'
            worker.write_text('import time\ntime.sleep(30)\n')
            started=time.monotonic()
            with patch.object(bounded_fs,'__file__',str(worker)):
                with self.assertRaises(OSError):bounded_fs.listing(root,timeout=0.1)
            self.assertLess(time.monotonic()-started,3)
            self.assertTrue(worker.exists())

    def test_failed_parent_is_held_without_repeated_read_attempts(self):
        with tempfile.TemporaryDirectory() as raw:
            s=studio.Studio(Path(raw).resolve());root=s.home/'Desktop/development'
            with patch.object(bounded_fs,'listing',side_effect=OSError('timeout')) as call:
                with self.assertRaises(OSError):s.directory(root)
                with self.assertRaises(OSError):s.directory(root/'child')
                self.assertEqual(call.call_count,1)

    def test_missing_directory_is_absent_not_permission_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            self.assertEqual(bounded_fs.listing(Path(raw).resolve()/'missing'),([],False))


if __name__=='__main__':unittest.main()
