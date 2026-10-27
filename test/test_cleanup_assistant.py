#!/usr/bin/env python3
"""Cleanup authority and Codex failure tests; disposable homes only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'lib'))
import studio
import cleanup_assistant as ai


class CleanupAssistantTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.home=Path(self.tmp.name).resolve()
        self.s=studio.Studio(self.home)
        self.a=ai.Assistant(self.s)
        self.cache=self.home/'Library/Caches/pip'
        self.cache.mkdir(parents=True)
        (self.cache/'cache').write_text('regenerable fixture')
        self.row=dict(id='cache',path=str(self.cache),title='pip',category='cache',bytes=4096,delta=0,reason='download',action='trash')
        self.scan=dict(items=[self.row],at='fixture',scope='fixture',discovery_limited=False)
        self.idle=patch.object(self.s,'idle');self.idle.start()
        self.addCleanup(self.idle.stop)
        self.addCleanup(self.tmp.cleanup)

    def review(self, decision='cleanup'):
        return {'model':'fixture','decisions':[{'id':'cache','decision':decision,'reason':'fixture'}]}

    def prepare(self):
        with patch.object(self.s,'scan',return_value=self.scan),patch.object(ai.care,'model_review',return_value=self.review()):
            return self.a.prepare()

    def plan(self):
        self.prepare()
        return self.a.plan(['cache'])

    def test_two_reviews_and_metadata_only(self):
        with patch.object(self.s,'scan',return_value=self.scan),patch.object(ai.care,'model_review',return_value=self.review()) as model:
            r=self.a.prepare()
            self.assertTrue(r['rows'][0]['ready'])
            self.assertEqual(model.call_count,2)
            self.assertNotIn(str(self.home),json.dumps(model.call_args.args[0]))
            self.assertNotIn('path',model.call_args.args[0][0])

    def test_primary_failure_keeps(self):
        with patch.object(self.s,'scan',return_value=self.scan),patch.object(ai.care,'model_review',side_effect=ValueError('unavailable')):
            r=self.a.prepare()
            self.assertFalse(r['rows'][0]['ready'])
            self.assertEqual(r['review']['status'],'unavailable')

    def test_reviewer_failure_keeps(self):
        with patch.object(self.s,'scan',return_value=self.scan),patch.object(ai.care,'model_review',side_effect=[self.review(),ValueError('failed')]):
            self.assertFalse(self.a.prepare()['rows'][0]['ready'])

    def test_primary_keep_not_overridden(self):
        with patch.object(self.s,'scan',return_value=self.scan),patch.object(ai.care,'model_review',return_value=self.review('keep')) as model:
            self.assertFalse(self.a.prepare()['rows'][0]['ready']);self.assertEqual(model.call_count,1)

    def test_unknown_original_cannot_become_candidate(self):
        self.row.update(path=str(self.home/'original'),action='review',category='other')
        (self.home/'original').mkdir()
        self.assertFalse(self.prepare()['rows'][0]['ready'])

    def test_live_or_changed_cache_keeps(self):
        with patch.object(self.s,'idle',side_effect=ValueError('active')):
            self.assertFalse(self.prepare()['rows'][0]['ready'])

    def test_explicit_plan_then_removal_with_receipt(self):
        plan=self.plan()
        self.assertTrue(self.cache.exists())
        result=self.a.apply(plan['id'])
        self.assertEqual(result['status'],'completed')
        self.assertFalse(self.cache.exists())
        self.assertIn('free_delta',result)
        with self.assertRaises(ValueError):self.a.apply(plan['id'])

    def test_changed_after_plan_not_deleted(self):
        plan=self.plan();(self.cache/'new').write_text('new work')
        self.assertEqual(self.a.apply(plan['id'])['status'],'partial')
        self.assertTrue((self.cache/'new').exists())

    def test_active_after_plan_not_deleted(self):
        plan=self.plan()
        with patch.object(self.s,'idle',side_effect=ValueError('active')):
            self.assertEqual(self.a.apply(plan['id'])['status'],'partial')
        self.assertTrue(self.cache.exists())

    def test_expired_and_unknown_tickets(self):
        plan=self.plan()
        for ticket in (None,'unknown'):
            with self.assertRaises(ValueError):self.a.apply(ticket)
        with patch.object(ai.time,'time',return_value=time.time()+301):
            with self.assertRaises(ValueError):self.a.apply(plan['id'])

    def test_protected_and_symlink_cache_keeps(self):
        (self.cache/'.devpurge-keep').write_text('keep')
        self.assertFalse(self.prepare()['rows'][0]['ready'])
        (self.cache/'.devpurge-keep').unlink()
        (self.cache/'link').symlink_to(self.home)
        self.assertFalse(self.prepare()['rows'][0]['ready'])

    def test_rescan_failure_invalidates_old_selection(self):
        self.plan()
        with patch.object(self.s,'scan',side_effect=ValueError('failed')):
            with self.assertRaises(ValueError):self.a.prepare()
        self.assertFalse(self.a.status()['report']['rows'][0]['ready'])
        self.assertEqual(ai.care.load(self.a.state/'plan.json',None),{})

    def test_unknown_selected_id(self):
        self.prepare()
        with self.assertRaises(ValueError):self.a.plan(['invented'])

    def test_render_copy_plan_preserves_existing_proof_boundary(self):
        render={'id':'render','name':'remotion-webpack-bundle-fixture','status':'verified','proof':{'reclaimable_bytes':4096,'keepers':['retained']},'reclaimable_bytes':4096}
        row={'id':'render','kind':'render-copy','path':'/fixture/render','title':render['name'],'ready':True,'proof':{'tree':{'bytes':4096},'render':render}}
        ai.care.save(self.a.state/'report.json',{'at':time.time(),'review':{'status':'reviewed'},'rows':[row]})
        with patch.object(self.a,'render_scan',return_value={'at':time.time(),'items':[render]}):
            plan=self.a.plan(['render'])
        self.assertNotIn('renders',plan)
        self.assertEqual(plan['bytes'],4096)
        with patch.object(self.a,'render_scan',return_value={'items':[{**render,'status':'keep'}]}):
            with self.assertRaises(ValueError):self.a.plan(['render'])

    def test_parent_symlink_after_plan_keeps(self):
        plan=self.plan()
        parent=self.cache.parent
        parent.rename(parent.with_name('retained'))
        parent.symlink_to(parent.with_name('retained'))
        self.assertEqual(self.a.apply(plan['id'])['status'],'partial')
        self.assertTrue(self.cache.exists())

    def test_ignored_next_build_requires_retained_manifest_and_idle_project(self):
        project=self.home/'Desktop/development/project';project.mkdir(parents=True)
        subprocess.run(['git','init','-q',str(project)],check=True)
        (project/'.gitignore').write_text('.next/\n')
        (project/'package.json').write_text(json.dumps({'dependencies':{'next':'fixture'},'scripts':{'build':'next build'}}))
        build=project/'.next';build.mkdir();(build/'bundle').write_text('generated')
        row={**self.row,'path':str(build)}
        observed={'renderers':[],'open_paths':[],'arguments':[]}
        with patch.object(ai.care,'activity',return_value=observed):
            self.assertEqual(self.a.local_check(row)['kind'],'next-build')
            observed['open_paths']=[str(project/'source.ts')]
            with self.assertRaises(ValueError):self.a.local_check(row)
            observed['open_paths']=[]
            (project/'.gitignore').unlink()
            with self.assertRaises(ValueError):self.a.local_check(row)


if __name__=='__main__':unittest.main()
