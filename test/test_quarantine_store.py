"""Disposable project quarantine; never touch the real user's data."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib'))
import studio
import quarantine_store as qs
import cleanup_assistant


class QuarantineTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.home=Path(self.temp.name).resolve();self.s=studio.Studio(self.home)
        self.q=qs.Quarantine(self.s);self.q.root.mkdir(parents=True)
        self.project=self.home/'Desktop/development/project';self.project.mkdir(parents=True)
        self.original=self.project/'.next';self.stored=self.q.root/'Q100-.next';self.stored.mkdir()
        (self.stored/'generated').write_text('compiled fixture')
        subprocess.run(['git','init','-q',str(self.project)],check=True)
        (self.project/'.gitignore').write_text('.next/\n')
        (self.project/'package.json').write_text(json.dumps({'scripts':{'build':'next build'},'dependencies':{'next':'fixture'}}))
        (self.project/'package-lock.json').write_text('{}')
        self.epoch=int(time.time())
        (self.q.root/'manifest.tsv').write_text('\t'.join(['Q100',str(self.epoch),str(self.original),'4',str(self.stored),'fixture'])+'\n')
        self.folder=self.q.audits/'fixture';self.folder.mkdir(parents=True)
        self.target={'path':str(self.original),'kind':'regenerable_build','inventory':self.q.inventory(self.stored)[0],
            'proof':{'package':str(self.project/'package.json'),'package_sha256':self.q.hash_file(self.project/'package.json'),
                'lock':str(self.project/'package-lock.json'),'lock_sha256':self.q.hash_file(self.project/'package-lock.json'),'build':'next build'}}
        qs.care.save(self.folder/'execution-plan.json',{'targets':[self.target]})
        qs.care.save(self.folder/'movement-receipt.json',[{'id':'Q100','original':str(self.original),'stored':str(self.stored),'epoch':self.epoch}])
        self.row=self.q.entries()[0]
        self.idle=patch.object(self.s,'idle');self.idle.start();self.addCleanup(self.idle.stop)
        self.activity=patch.object(qs.care,'activity',return_value={'open_paths':[],'arguments':[]});self.activity.start();self.addCleanup(self.activity.stop)

    def test_verified_build_is_not_deleted_by_inspection(self):
        self.assertEqual(self.q.verify(self.row)['kind'],'quarantine');self.assertTrue(self.stored.exists())

    def test_changed_source_or_target_kept(self):
        (self.project/'package-lock.json').write_text('changed')
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_changed_inventory_kept(self):
        (self.stored/'new-original').write_text('unique')
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_missing_audit_kept(self):
        (self.folder/'movement-receipt.json').unlink()
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_duplicate_manifest_refused(self):
        p=self.q.root/'manifest.tsv';p.write_text(p.read_text()*2)
        with self.assertRaises(ValueError):self.q.entries()

    def test_external_symlink_kept(self):
        (self.stored/'link').symlink_to(self.project)
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_active_reference_kept(self):
        with patch.object(qs.care,'activity',return_value={'open_paths':[str(self.stored/'generated')],'arguments':[]}):
            with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_project_link_to_quarantine_kept(self):
        (self.project/'still-used').symlink_to(self.stored,target_is_directory=True)
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_build_must_still_be_git_ignored(self):
        (self.project/'.gitignore').unlink()
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def dependency_fixture(self):
        old=self.stored;self.original=self.project/'node_modules';self.stored=self.q.root/'Q100-node_modules';old.rename(self.stored)
        anchor=self.project/'retained/node_modules';anchor.mkdir(parents=True)
        (anchor/'generated').write_text('compiled fixture')
        (anchor.parent/'package-lock.json').write_text('{}')
        self.target.update(path=str(self.original),kind='identical_dependency_packages',retained=str(anchor),
            inventory=self.q.inventory(self.stored)[0],packages_inventory=self.q.inventory(self.stored,True,True)[0],retained_metadata=[])
        (self.q.root/'manifest.tsv').write_text('\t'.join(['Q100',str(self.epoch),str(self.original),'4',str(self.stored),'fixture'])+'\n')
        qs.care.save(self.folder/'execution-plan.json',{'targets':[self.target]})
        qs.care.save(self.folder/'movement-receipt.json',[{'id':'Q100','original':str(self.original),'stored':str(self.stored),'epoch':self.epoch}])
        self.row=self.q.entries()[0]
        return anchor

    def test_dependencies_require_actual_content_equality(self):
        anchor=self.dependency_fixture();self.q.verify(self.row)
        (anchor/'generated').write_text('different retained file')
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_dependency_unique_metadata_must_have_retained_copy(self):
        self.dependency_fixture();(self.stored/'.cache').mkdir();(self.stored/'.cache/unique').write_text('unique')
        self.target['inventory']=self.q.inventory(self.stored)[0]
        qs.care.save(self.folder/'execution-plan.json',{'targets':[self.target]})
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_hold_excludes_candidate_without_changing_epoch(self):
        self.q.hold(self.row['id'])
        self.assertEqual(self.q.entries()[0]['epoch'],self.epoch)
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_shared_lock_blocks_second_mutation(self):
        with self.q.locked():
            with self.assertRaises(ValueError):
                with self.q.locked():pass

    def test_restore_conflict_keeps_both(self):
        self.original.mkdir();(self.original/'current').write_text('current')
        with self.assertRaises(ValueError):self.q.restore(self.row['id'])
        self.assertTrue((self.original/'current').exists());self.assertTrue(self.stored.exists())

    @unittest.skipUnless(sys.platform=='darwin','macOS exclusive rename')
    def test_restore_preserves_receipt_and_does_not_reuse_id(self):
        self.q.restore(self.row['id'])
        self.assertTrue((self.original/'generated').exists());self.assertFalse(self.stored.exists())
        self.assertEqual(self.q.entries(),[]);self.assertTrue((self.folder/'movement-receipt.json').exists())
        self.assertEqual((self.q.root/'last-id').read_text().strip(),'100')

    def test_final_ticket_required_and_audit_retained_after_deletion(self):
        a=cleanup_assistant.Assistant(self.s)
        proof=self.q.verify(self.row)
        row={**self.row,'ready':True,'proof':proof}
        qs.care.save(a.state/'report.json',{'at':time.time(),'review':{'status':'reviewed'},'rows':[row]})
        with a.lock():
            plan=a.plan([row['id']]);self.assertTrue(self.stored.exists())
            with self.assertRaises(ValueError):a.apply('wrong-ticket')
            result=a.apply(plan['id'])
            self.assertEqual(result['status'],'completed')
            with self.assertRaises(ValueError):a.apply(plan['id'])
        self.assertFalse(self.stored.exists());self.assertTrue((self.folder/'execution-plan.json').exists())
        self.assertEqual(self.q.entries(),[])


if __name__=='__main__':unittest.main()
