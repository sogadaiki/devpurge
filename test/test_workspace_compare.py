import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import workspace_compare as wc


class WorkspaceCompareTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()
        mock_home = patch('pathlib.Path.home', return_value=root)
        mock_home.start()
        self.addCleanup(mock_home.stop)
        self.copy, self.keeper = root / 'work', root / 'keeper'
        self.copy.mkdir()
        self.keeper.mkdir()

    def file(self, p, value):
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(value)
        return p

    def test_subset_and_renamed_file(self):
        a = self.file(self.copy / 'nested/data.bin', b'contents')
        b = self.file(self.keeper / 'nested/data.bin', b'contents')
        # Even a sensitive or linked file existing only in the keeper is outside scope.
        (self.keeper / '.env').symlink_to('/nonexistent')
        result = wc.compare(self.copy, self.keeper)
        self.assertEqual((result['status'], result['matched_files'], result['matched_bytes']), ('match', 1, 8))
        renamed = b.with_name('kept.bin')
        b.rename(renamed)
        self.assertEqual(wc.compare(a, renamed)['status'], 'match')
        self.assertEqual(wc.compare(self.copy, self.keeper)['status'], 'different')

    def test_same_length_different_contents_and_partial(self):
        self.file(self.copy / 'a', b'abc')
        self.file(self.keeper / 'a', b'abd')
        self.file(self.copy / 'b', b'missing')
        answer = wc.compare(self.copy, self.keeper)
        self.assertEqual(answer['status'], 'different')
        self.assertEqual(answer['difference_count'], 2)
        self.file(self.copy / '.env', b'forbidden')
        inspected = []
        digest = wc._Comparison.digest
        def real_digest(this, fd, state):
            inspected.append((state.st_dev, state.st_ino))
            return digest(this, fd, state)
        with patch.object(wc._Comparison, 'digest', real_digest):
            result = wc.compare(self.copy, self.keeper)
        secret = (self.copy / '.env').stat()
        self.assertNotIn((secret.st_dev, secret.st_ino), inspected)
        self.assertEqual(result['status'], 'incomplete')
        self.assertEqual(result['difference_count'], 2)

    def test_hardlinks_symlinks_protection_and_overlap(self):
        a = self.file(self.copy / 'a', b'abc')
        b = self.keeper / 'a'
        os.link(a, b)
        same = wc.compare(a, b)
        self.assertEqual((same['status'], same['matched_files'], same['matched_bytes']), ('incomplete', 0, 0))
        link = self.copy / 'outside'
        link.symlink_to(self.keeper)
        for x, y in ((a, a), (self.copy, self.copy / 'inside'), (link / 'a', b),
                     (link, a), (self.copy.parent / 'CloudStorage/a', b)):
            self.assertEqual(wc.compare(x, y)['status'], 'incomplete')
        (self.copy / '.devpurge-keep').touch()
        self.assertEqual(wc.compare(self.copy, self.keeper)['matched_files'], 0)

    def test_limits_and_concurrent_replacement(self):
        a = self.file(self.copy / 'a', b'stable')
        b = self.file(self.keeper / 'a', b'stable')
        for key in ('_BYTES', '_SECONDS', '_ENTRIES'):
            with patch.object(wc, key, 0):
                self.assertEqual(wc.compare(self.copy, self.keeper)['status'], 'incomplete')
        original = wc._Comparison.digest
        swapped = False
        def replace(this, fd, snapshot):
            nonlocal swapped
            digest = original(this, fd, snapshot)
            if not swapped:
                swapped = True
                replacement = self.file(self.keeper / 'new', b'changed')
                replacement.replace(b)
            return digest
        with patch.object(wc._Comparison, 'digest', replace):
            self.assertEqual(wc.compare(a, b)['status'], 'incomplete')

    def test_finished_file_changed_later_is_rechecked(self):
        a = self.file(self.copy / 'data/a', b'abc')
        self.file(self.keeper / 'data/a', b'abc')
        confirm = wc._Comparison.confirm
        def modify_file(this):
            a.write_bytes(b'xyz')  # Parent directory entries and size stay unchanged.
            confirm(this)
        with patch.object(wc._Comparison, 'confirm', modify_file):
            result = wc.compare(self.copy, self.keeper)
        self.assertEqual(result['status'], 'incomplete')
        self.assertEqual(result['matched_files'], 0)


if __name__ == '__main__':
    unittest.main()
