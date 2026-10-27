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
import quarantine_adapters as qa


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

    def test_unknown_provenance_format_is_not_reported_as_content_mismatch(self):
        self.target={'path':str(self.original),'contents':{'.':{'size':12,'sha256':'unknown'}}}
        qs.care.save(self.folder/'execution-plan.json',{'targets':[self.target]})
        with patch.object(self.q,'content_map',side_effect=AssertionError('unsupported records need no content read')):
            with self.assertRaisesRegex(ValueError,'検証形式に未対応'):self.q.verify(self.row)
        self.assertTrue(self.stored.exists())

    def adapter_record(self,original,stored,plan,receipt_name='movement-receipt.json'):
        self.original=original;self.stored=stored
        original.parent.mkdir(parents=True,exist_ok=True)
        (self.q.root/'manifest.tsv').write_text('Q101\t%s\t%s\t4\t%s\tfixture\n'%(self.epoch,original,stored))
        (self.folder/'movement-receipt.json').unlink(missing_ok=True)
        receipt={'id':'Q101','epoch':str(self.epoch),'original':str(original),'stored':str(stored)}
        qs.care.save(self.folder/receipt_name,receipt if receipt_name=='receipt.json' else [receipt])
        qs.care.save(self.folder/'execution-plan.json',plan)
        self.row=self.q.entries()[0]

    def audio_adapter(self):
        stored=self.q.root/'Q101-audio_processed.wav';stored.write_bytes(b'pcm fixture')
        original=self.project/'work/audio_processed.wav'
        self.anchor=self.project/'premiere/camera.mov';self.anchor.parent.mkdir();self.anchor.write_bytes(b'retained mov fixture')
        target={'path':str(original),'contents':{'.':{'size':stored.stat().st_size,'sha256':self.q.hash_file(stored)}}}
        self.adapter_record(original,stored,{'targets':[target],'retained':{str(self.anchor):{'sha256':self.q.hash_file(self.anchor)}}})
        self.audio={'sha256':'SHA256='+'a'*64,'codec':'pcm_s24le','rate':'48000','channels':2,'streams':1}
        qs.care.save(self.folder/'media-stream-proof.json',{'streams':{'intermediate_audio':{'path':str(original),'hash':self.audio['sha256']},'retained_premiere_audio':{'path':str(self.anchor),'hash':self.audio['sha256']}}})

    def test_legacy_audio_rechecks_pcm_and_retained_file(self):
        self.audio_adapter()
        with patch.object(qa,'audio_fingerprint',return_value=self.audio):
            self.assertEqual(self.q.verify(self.row)['kind'],'quarantine')
            self.anchor.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'保持元が記録時'):self.q.verify(self.row)

    def test_pcm_mismatch_or_extra_staging_stream_is_held(self):
        self.audio_adapter()
        with patch.object(qa,'audio_fingerprint',side_effect=[self.audio,{**self.audio,'sha256':'SHA256='+'b'*64}]):
            with self.assertRaisesRegex(ValueError,'PCM音声'):self.q.verify(self.row)
        with patch.object(qa,'audio_fingerprint',return_value={**self.audio,'streams':2}):
            with self.assertRaisesRegex(ValueError,'PCM音声'):self.q.verify(self.row)

    def alias_adapter(self):
        original=self.project/'assets';original.mkdir()
        stored=self.q.root/'Q101-assets';stored.mkdir();(stored/'one.mp4').write_bytes(b'media')
        self.anchor=self.project/'public/one.mp4';self.anchor.parent.mkdir();self.anchor.write_bytes(b'media')
        (original/'one.mp4').symlink_to('../public/one.mp4')
        item={'copy':str(original/'one.mp4'),'retained':str(self.anchor),'bytes':5,'mode':420,'sha256':self.q.hash_file(self.anchor)}
        self.adapter_record(original,stored,{'proofs':[item]},'receipt.json')

    def test_single_receipt_aliases_and_apply_preserve_originals(self):
        self.alias_adapter();proof=self.q.verify(self.row)
        self.assertEqual(self.q.external_records(),[])
        row={**self.row,'ready':True,'proof':proof}
        assistant=cleanup_assistant.Assistant(self.s)
        qs.care.save(assistant.state/'report.json',{'at':time.time(),'rows':[row],'review':{'status':'reviewed'}})
        plan=assistant.plan([row['id']]);result=assistant.apply(plan['id'])
        self.assertEqual(result['status'],'completed');self.assertFalse(self.stored.exists())
        self.assertEqual(self.anchor.read_bytes(),b'media')
        self.assertEqual((self.original/'one.mp4').read_bytes(),b'media')
        self.assertEqual(self.q.external_records(),[],'completed deletion is history, not unbound debt')

    def test_alias_changed_unknown_file_and_changed_original_are_held(self):
        self.alias_adapter();(self.stored/'unique').write_text('unique')
        with self.assertRaisesRegex(ValueError,'記録にない'):self.q.verify(self.row)
        (self.stored/'unique').unlink();alias=self.original/'one.mp4';alias.unlink();alias.symlink_to('../missing.mp4')
        with self.assertRaisesRegex(ValueError,'切り替わっていない'):self.q.verify(self.row)
        alias.unlink();alias.symlink_to('../public/one.mp4');self.anchor.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'保持元が記録時'):self.q.verify(self.row)

    def test_duplicate_receipt_formats_cannot_grant_authority(self):
        self.alias_adapter()
        qs.care.save(self.folder/'receipts.json',[self.q.read_json(self.folder/'receipt.json')])
        with self.assertRaisesRegex(ValueError,'重複'):self.q.verify(self.row)

    def test_plural_receipt_and_string_epoch_bind_but_worktrees_stay_held(self):
        stored=self.q.root/'Q101-checkout';stored.mkdir();(stored/'.git').write_text('gitdir: retained git metadata')
        self.adapter_record(self.project/'checkout',stored,{'targets':[{'path':str(self.project/'checkout')}]},'receipts.json')
        self.assertEqual(self.q.binding(self.row)[0],self.folder)
        self.assertEqual(self.q.external_records(),[])
        with self.assertRaisesRegex(ValueError,'Git作業コピー'):self.q.verify(self.row)

    def cache_adapter(self):
        original=self.project/'old/remotion/node_modules/.cache';stored=self.q.root/'Q101-.cache'
        cache=stored/'webpack/remotion-production-4.0.409/abc/index.pack';cache.parent.mkdir(parents=True);cache.write_bytes(b'pack')
        source=self.project/'retained';source.mkdir();(source/'src').mkdir();(source/'src/index.ts').write_text('entry')
        (source/'package.json').write_text(json.dumps({'dependencies':{'remotion':'4.0.409'}}));(source/'package-lock.json').write_text('{}')
        target={'path':str(original),'contents':{'webpack/remotion-production-4.0.409/abc/index.pack':{'size':4,'sha256':self.q.hash_file(cache)}}}
        retained={str(source/name):{'sha256':self.q.hash_file(source/name)} for name in ('package.json','package-lock.json')}
        self.adapter_record(original,stored,{'targets':[target],'retained':retained})
        return source

    def test_legacy_pack_cache_uses_retained_checkout_and_requires_sources(self):
        source=self.cache_adapter();self.assertEqual(self.q.verify(self.row)['kind'],'quarantine')
        (source/'src/index.ts').unlink()
        with self.assertRaises(OSError):self.q.verify(self.row)

    def test_cache_unknown_file_and_active_quarantine_are_held(self):
        self.cache_adapter()
        with patch.object(self.q,'idle',side_effect=ValueError('active')):
            with self.assertRaisesRegex(ValueError,'active'):self.q.verify(self.row)
        (self.stored/'unique').write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError,'一致しない'):self.q.verify(self.row)

    def duplicate_file(self):
        self.original=self.project/'old.mp4';self.stored=self.q.root/'Q101-old.mp4'
        self.stored.write_bytes(b'same retained media');self.anchor=self.project/'primary.mp4';self.anchor.write_bytes(self.stored.read_bytes())
        (self.q.root/'manifest.tsv').write_text('Q101\t%s\t%s\t4\t%s\tduplicate\n'%(self.epoch,self.original,self.stored))
        self.row=self.q.entries()[0]
        target={'path':str(self.original),'kind':'verified_duplicate','contents':self.q.content_map(self.stored)[0],'retained_path':str(self.anchor)}
        qs.care.save(self.folder/'execution-plan.json',{'root':str(self.project),'targets':[target]})
        qs.care.save(self.folder/'movement-receipt.json',[{'id':'Q101','original':str(self.original),'stored':str(self.stored),'content_verified':True}])

    def test_timestamp_less_file_receipt_requires_current_identical_original(self):
        self.duplicate_file()
        self.assertEqual(self.q.verify(self.row)['kind'],'quarantine')
        self.anchor.write_bytes(b'changed original')
        with self.assertRaises(ValueError):self.q.verify(self.row)
        self.assertTrue(self.stored.exists())

    def test_timestamp_mismatch_still_rejected(self):
        self.duplicate_file()
        path=self.folder/'movement-receipt.json';data=self.q.read_json(path);data[0]['epoch']=self.epoch+1;qs.care.save(path,data)
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_file_deletion_keeps_original_and_receipt(self):
        self.duplicate_file();self.test_final_ticket_required_and_audit_retained_after_deletion()
        self.assertEqual(self.anchor.read_bytes(),b'same retained media')

    def new_build(self,kind):
        name='dist' if kind=='obsolete_generated_build' else 'webpack'
        self.original=self.project/name if name=='dist' else self.project/'node_modules/.cache/webpack'
        self.original.parent.mkdir(parents=True,exist_ok=True)
        dest=self.q.root/('Q100-'+name);self.stored.rename(dest);self.stored=dest
        (self.project/'package.json').write_text(json.dumps({'scripts':{'build':'vite build'},'dependencies':{'vite':'1','remotion':'1'}}))
        (self.project/'.gitignore').write_text('dist/\nnode_modules/\n')
        if name=='dist':
            (dest/'generated').rename(dest/'index.html')
            (self.project/'index.html').write_text('source template')
            (self.project/'vite.config.ts').write_text('fixture build config')
        target={'path':str(self.original),'kind':kind,'repo':str(self.project),'contents':self.q.content_map(dest)[0]}
        sources={str(p):self.q.content_map(p)[0]['.'] for p in [self.project/n for n in ('package.json','package-lock.json','index.html','vite.config.ts')] if p.exists()}
        qs.care.save(self.folder/'execution-plan.json',{'targets':[target],'retained_sources':sources})
        qs.care.save(self.folder/'movement-receipt.json',[{'id':'Q100','original':str(self.original),'stored':str(dest)}])
        (self.q.root/'manifest.tsv').write_text('\t'.join(['Q100',str(self.epoch),str(self.original),'4',str(dest),'fixture'])+'\n')
        self.row=self.q.entries()[0]

    def test_webpack_receipt_rechecks_contents_and_source(self):
        self.new_build('regenerable_webpack_cache');self.q.verify(self.row)
        (self.stored/'generated').write_text('different')
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_vite_build_holds_changed_source(self):
        self.new_build('obsolete_generated_build');self.q.verify(self.row)
        (self.project/'package-lock.json').write_text('new environment')
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_vite_unknown_original_is_held_even_when_in_receipt(self):
        self.new_build('obsolete_generated_build');(self.stored/'unique.mp4').write_bytes(b'original')
        path=self.folder/'execution-plan.json';plan=self.q.read_json(path)
        plan['targets'][0]['contents']=self.q.content_map(self.stored)[0];qs.care.save(path,plan)
        with self.assertRaises(ValueError):self.q.verify(self.row)

    def test_external_receipts_are_visible_without_delete_authority(self):
        other=self.q.audits/'other';other.mkdir()
        qs.care.save(other/'movement-receipt.json',[{'id':'T1','original':'/original','stored':'/arbitrary','bytes':123}])
        self.assertEqual(self.q.external_records()[0]['path'],'/arbitrary')
        with self.assertRaises(ValueError):self.q.entry('T1')

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
