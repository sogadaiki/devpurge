#!/usr/bin/env python3
"""Destructive guards tested only against disposable fixtures."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('care', Path(__file__).resolve().parents[1] / 'lib/render_care.py')
care = importlib.util.module_from_spec(spec)
spec.loader.exec_module(care)


class Guards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.temp = self.root / 'T'
        self.temp.mkdir()
        self.source = self.root / 'source'
        (self.source / 'public').mkdir(parents=True)
        (self.source / 'public/a.mp4').write_bytes(b'original')
        self.bundle = self.temp / 'remotion-webpack-bundle-123abc'
        (self.bundle / 'public').mkdir(parents=True)
        (self.bundle / 'public/a.mp4').write_bytes(b'original')
        (self.bundle / 'index.html').write_text('generated')
        (self.bundle / 'bundle.js').write_text('generated')
        for p in sorted(self.bundle.rglob('*'), reverse=True):
            os.utime(p, (time.time() - 7200, time.time() - 7200))
        os.utime(self.bundle, (time.time() - 7200, time.time() - 7200))
        self.observed = {'renderers': [], 'open_paths': [], 'arguments': []}
        self.engine = care.Care(self.root / 'state', self.temp, lambda: self.observed)
        care.save(self.engine.state / 'config.json', dict(sources=[str(self.source)], primary='luna', reviewer='terra', enabled=True))

    def tearDown(self):
        self.tmp.cleanup()

    def plan(self):
        plan = self.engine.scan(verify=True)
        row = plan['items'][0]
        self.assertEqual(row['status'], 'verified', row['reason'])
        return plan, {'status': 'reviewed', 'decisions': [{'id': row['id'], 'decision': 'cleanup', 'reason': 'verified'}], 'runs': []}

    def test_verified_copy_removed_original_unchanged(self):
        plan, ai = self.plan()
        result = self.engine.apply(plan, ai)
        self.assertEqual(result['items'][0]['status'], 'removed')
        self.assertFalse(self.bundle.exists())
        self.assertEqual((self.source / 'public/a.mp4').read_bytes(), b'original')

    def test_changed_original_refuses_removal(self):
        plan, ai = self.plan()
        (self.source / 'public/a.mp4').write_bytes(b'changed!')
        self.assertEqual(self.engine.apply(plan, ai)['items'][0]['status'], 'kept-or-partial')
        self.assertTrue(self.bundle.exists())

    def test_active_renderer_after_review_refuses(self):
        plan, ai = self.plan()
        self.observed['renderers'] = [{'pid': 123, 'started': time.time() - 60}]
        self.assertEqual(self.engine.apply(plan, ai)['items'][0]['status'], 'kept-or-partial')
        self.assertTrue(self.bundle.exists())

    def test_open_file_and_arguments_protect_old_bundle(self):
        for evidence in [{'open_paths': [str(self.bundle / 'public/a.mp4')]}, {'arguments': [str(self.bundle)]}]:
            observed = {**self.observed, **evidence}
            self.assertTrue(care.active_bundle(self.bundle, observed))

    def test_stale_and_ai_veto(self):
        plan, ai = self.plan()
        ai['decisions'][0]['decision'] = 'keep'
        self.assertEqual(self.engine.apply(plan, ai)['items'], [])
        plan['at'] -= 601
        with self.assertRaisesRegex(ValueError, 'expired'):
            self.engine.apply(plan, ai)

    def test_copied_link_unlinks_only_copy(self):
        destination = self.root / 'assets'
        destination.mkdir()
        (destination / 'retained').write_text('keep')
        for root in [self.source, self.bundle]:
            (root / 'public/assets').symlink_to(destination)
        # Direct proof/apply bypasses only the fixture's age, never the guards.
        proof = care.inspect_bundle(self.bundle, self.source / 'public', {})
        row = dict(id='fixture', name=self.bundle.name, status='verified', bytes=proof['bytes'], proof=proof)
        self.engine.apply({'at': time.time(), 'items': [row]}, {'decisions': [{'id': 'fixture', 'decision': 'cleanup'}]})
        self.assertFalse(self.bundle.exists())
        self.assertEqual((destination / 'retained').read_text(), 'keep')

    def test_unknown_file_secret_and_replaced_root_refused(self):
        for name in ['unique.mov', '.env', '証拠.txt']:
            p = self.bundle / name
            p.write_text('keep')
            with self.assertRaises(ValueError):
                care.inspect_bundle(self.bundle, self.source / 'public', {})
            p.unlink()
        os.utime(self.bundle, (time.time() - 7200, time.time() - 7200))
        plan, ai = self.plan()
        self.bundle.rename(self.temp / 'retained')
        self.bundle.symlink_to(self.temp / 'retained')
        self.engine.apply(plan, ai)
        self.assertTrue((self.temp / 'retained/public/a.mp4').exists())

    def test_failed_model_never_deletes(self):
        with patch.object(self.engine, 'classify', side_effect=ValueError('offline')):
            result = self.engine.cycle(apply=True)
        self.assertEqual(result['ai']['status'], 'unavailable')
        self.assertTrue(self.bundle.exists())

    def test_unknown_render_intermediate_kept(self):
        (self.temp / 'react-motion-render123').mkdir()
        plan = self.engine.scan(verify=True)
        self.assertEqual(next(x for x in plan['items'] if x['kind'] != 'bundle')['status'], 'keep')

    def test_partial_copies_reclaimed_differing_edit_retained(self):
        (self.bundle / 'public/edit.json').write_text('old unique edit')
        (self.source / 'public/edit.json').write_text('current edit')
        for p in [self.bundle / 'public/edit.json', self.bundle / 'public', self.bundle]:
            os.utime(p, (time.time() - 7200, time.time() - 7200))
        plan, ai = self.plan()
        receipt = self.engine.apply(plan, ai)
        self.assertEqual(receipt['items'][0]['status'], 'trimmed')
        self.assertEqual((self.bundle / 'public/edit.json').read_text(), 'old unique edit')
        self.assertFalse((self.bundle / 'public/a.mp4').exists())
        self.assertEqual((self.source / 'public/a.mp4').read_bytes(), b'original')

    def test_model_cannot_invent_target(self):
        def fake(argv, timeout):
            output = Path(argv[argv.index('-o') + 1])
            output.write_text(json.dumps({'decisions': [{'id': '../../unique', 'decision': 'cleanup', 'reason': 'x'}]}))
            return subprocess.CompletedProcess(argv, 0)
        with patch.object(care.shutil, 'which', return_value='/bin/false'), patch.object(care, 'resolve_model', return_value='fixture'):
            with self.assertRaisesRegex(ValueError, 'IDs'):
                care.model_review([{'id': 'real'}], 'luna', self.engine.state, runner=fake)

    def test_classifier_routes_review_to_terra_and_respects_keep(self):
        plan, _ = self.plan()
        rid = plan['items'][0]['id']
        responses = [dict(model='luna', decisions=[dict(id=rid, decision='review', reason='uncertain')]),
                     dict(model='terra', decisions=[dict(id=rid, decision='keep', reason='keep')])]
        with patch.object(care, 'model_review', side_effect=responses) as model:
            result = self.engine.classify(plan)
            self.assertEqual(model.call_args_list[1].args[1], 'terra')
            self.assertEqual(result['decisions'][0]['decision'], 'keep')

    def test_large_batch_requires_reviewer_and_outage_falls_back(self):
        plan, _ = self.plan()
        plan['items'][0]['reclaimable_bytes'] = 11 * 2**30
        rid = plan['items'][0]['id']
        responses = [dict(model='luna', decisions=[dict(id=rid, decision='cleanup', reason='match')]),
                     dict(model='terra', decisions=[dict(id=rid, decision='keep', reason='veto')])]
        with patch.object(care, 'model_review', side_effect=responses):
            self.assertEqual(self.engine.classify(plan)['decisions'][0]['decision'], 'keep')
        plan['items'][0]['reclaimable_bytes'] = 100
        with patch.object(care, 'model_review', side_effect=[ValueError('offline'), responses[1]]):
            result = self.engine.classify(plan)
            self.assertEqual(result['fallback_from'], 'luna')
            self.assertEqual(result['decisions'][0]['decision'], 'keep')

    def test_exclusions_and_lock(self):
        self.engine.excluded.append(self.bundle)
        self.assertEqual(self.engine.scan(verify=True)['items'][0]['status'], 'keep')
        with self.engine.locked():
            with self.assertRaises(BlockingIOError):
                with self.engine.locked():
                    self.fail('concurrent cleanup acquired lock')

    def test_incomplete_measurement_is_not_zero(self):
        with patch.object(care, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'permission denied')):
            scan = self.engine.scan()
            self.assertIsNone(scan['temp_bytes'])
            self.assertIsNone(scan['growth_bytes'])

    def test_unreadable_tree_is_not_verified(self):
        def bad_walk(path, followlinks, onerror):
            onerror(PermissionError('unreadable'))
            return iter([])
        with patch.object(care.os, 'walk', side_effect=bad_walk):
            with self.assertRaises(PermissionError):
                care.inspect_bundle(self.bundle, self.source / 'public', {})


if __name__ == '__main__':
    unittest.main()
