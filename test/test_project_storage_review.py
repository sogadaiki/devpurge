import fcntl
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from project_storage_review import review
from studio import Studio


class ProjectStorageReviewTest(unittest.TestCase):
    def test_reviews_local_outputs_without_following_links_or_mutating_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            project = home / 'Desktop/development/editor'
            scratch = project / 'talkhead/.render-tmp'
            composite = project / 'talkhead/work/episode/composite'
            backup = home / '.codex/worktrees/feature/state-before-release'
            trailer = home / '.codex/worktrees/feature/game/media/trailer-test/generated'
            excluded = home / 'Desktop/development/excluded/.render-tmp'
            linked_parent = home / 'Desktop/development/linked'
            protected = home / 'Desktop/development/裁判/.render-tmp'
            for folder in (scratch, composite, backup, trailer, excluded, protected):
                folder.mkdir(parents=True)
                (folder / 'sample').write_bytes(b'example')
            linked_parent.symlink_to(project / 'talkhead', target_is_directory=True)
            (home / '.devpurgerc').write_text('exclude=~/Desktop/development/excluded\n')
            game_row = {'id': 'BC0001', 'tier': 'review', 'deletable': False, 'bytes': 0}
            scan = {'items': [game_row, {'id': 'D1', 'tier': 'dev'}]}

            with (scratch.parent / '.render-bundle.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                result = review(Studio(home), scan)
                items = {row['path']: row for row in result['items']}
                self.assertEqual(items.keys(), {str(p) for p in (scratch, composite, backup, trailer)})
                self.assertEqual(items[str(scratch)]['render_lock'], 'in-use')
                self.assertTrue(all(row['action'] == 'review' for row in items.values()))
                self.assertEqual(result['game_builds']['rows'], [game_row])
                self.assertTrue(all((p / 'sample').is_file() for p in (scratch, composite, backup, trailer)))
            unlocked = review(Studio(home), scan)
            self.assertEqual(next(row['render_lock'] for row in unlocked['items']
                                  if row['path'] == str(scratch)), 'unlocked')


if __name__ == '__main__':
    unittest.main()
