"""Disposable build roots only. No actual user releases or privileged operations."""
import json
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'lib'))
import build_care as bc


class BuildCareTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name).resolve();self.engine=bc.BuildCare(self.home)
        self.repo=self.home/'Desktop/development/game';self.root=self.repo/'build';self.root.mkdir(parents=True)
        subprocess.run(['git','init','-q',str(self.repo)],check=True)
        (self.repo/'.gitignore').write_text('build/\n')
        for n in range(1,5):self.fixture(n)
        self.anchor=self.b(4)/'RentalLegend.xcframework'
        self.config=self.engine.configure([self.root],[],self.anchor,True)
        self.idle=patch.object(self.engine,'idle');self.idle.start();self.addCleanup(self.idle.stop)

    def b(self,n):return self.root/('ios-testflight-build'+str(n)+'-fixture')

    def fixture(self,n):
        b=self.b(n);(b/'export').mkdir(parents=True)
        ipa=b/'export/RentalLegend.ipa'
        with zipfile.ZipFile(ipa,'w') as z:
            z.writestr('Payload/Game.app/game.pck',b'packed');z.writestr('Payload/Game.app/Info.plist',b'info')
        (b/'RentalLegend.xcarchive').mkdir();(b/'RentalLegend.xcarchive/archive').write_text('signed fixture')
        (b/'ipa-validation.json').write_text(json.dumps({'ipa_sha256':self.engine.q.hash_file(ipa),'distribution_signature_valid':True,'build':str(n)}))
        (b/'RentalLegend.pck').write_bytes(b'packed')
        (b/'ipa-verified/Payload/Game.app').mkdir(parents=True);(b/'ipa-verified/Payload/Game.app/game.pck').write_bytes(b'packed')
        (b/'RentalLegend.xcframework').mkdir();(b/'RentalLegend.xcframework/engine.a').write_bytes(b'engine')

    def verified(self):return [r for r in self.engine.scan()['rows'] if r['status']=='verified']

    def test_read_only_and_latest_two_and_pins(self):
        rows=self.verified();self.assertEqual(len(rows),6)
        self.assertEqual({Path(x['build']).name for x in rows},{self.b(1).name,self.b(2).name})
        self.assertTrue(all(Path(x['path']).exists() for x in rows))
        self.assertFalse((self.engine.state/'receipts').exists())
        self.engine.configure([self.root],[2],self.anchor,True)
        self.assertEqual(len(self.verified()),3)

    def test_disabled_policy_never_deletes(self):
        self.engine.configure([self.root],[],self.anchor,False)
        self.assertEqual(self.engine.run()['status'],'disabled');self.assertTrue((self.b(1)/'RentalLegend.pck').exists())

    def test_apply_preserves_all_releases_sources_and_latest(self):
        before={str(p):p.read_bytes() for n in range(1,5) for p in (self.b(n)/'export/RentalLegend.ipa',self.b(n)/'RentalLegend.xcarchive/archive')}
        result=self.engine.run();self.assertEqual(result['status'],'completed');self.assertEqual(len(result['items']),6)
        self.assertFalse((self.b(1)/'RentalLegend.pck').exists())
        self.assertTrue((self.b(3)/'RentalLegend.pck').exists());self.assertTrue(self.anchor.exists())
        self.assertTrue(all(Path(p).read_bytes()==data for p,data in before.items()))
        self.assertFalse((self.engine.q.root/'.operation-lock').exists())
        self.assertEqual(self.engine.run()['removed_bytes'],0)

    def test_changed_or_extra_data_and_framework_are_held(self):
        (self.b(1)/'RentalLegend.pck').write_bytes(b'unique')
        (self.b(1)/'ipa-verified/unique').write_text('unique')
        (self.b(1)/'RentalLegend.xcframework/unique').write_text('unique')
        self.assertFalse(any(r['build']==str(self.b(1)) for r in self.verified()))

    def test_missing_archive_or_changed_ipa_blocks_entire_build(self):
        (self.b(1)/'RentalLegend.xcarchive/archive').unlink()
        (self.b(2)/'export/RentalLegend.ipa').write_bytes(b'changed')
        self.assertEqual(self.verified(),[])

    def test_symlinks_protected_names_keep_marker_and_tracked_data(self):
        p=self.b(1)/'RentalLegend.pck';p.unlink();p.symlink_to(self.b(3)/'RentalLegend.pck')
        (self.b(1)/'RentalLegend.xcframework/.env.local').write_text('do not read')
        (self.b(2)/'.devpurge-keep').write_text('keep')
        rows=self.verified();self.assertEqual(len(rows),1)
        subprocess.run(['git','-C',str(self.repo),'add','-f',str(self.b(1)/'ipa-verified')],check=True)
        self.assertEqual(self.verified(),[])

    def test_use_check_unknown_holds_all(self):
        self.idle.stop()
        with patch.object(self.engine,'idle',side_effect=ValueError('usage unknown')):self.assertEqual(self.verified(),[])
        self.idle.start()

    def test_real_use_guard_holds_build_cwd_and_arguments(self):
        self.idle.stop()
        for observed in ({'open_paths':[str(self.b(1))],'arguments':[]},
                         {'open_paths':[],'arguments':['xcodebuild -derivedDataPath '+str(self.b(1)/'derived')] }):
            with patch.object(bc.care,'activity',return_value=observed):
                with self.assertRaisesRegex(ValueError,'in use'):self.engine.idle(self.b(1),self.b(1)/'RentalLegend.pck')
        with patch.object(bc.care,'activity',return_value={'open_paths':[],'arguments':['uv run unrelated-project']}):
            self.engine.idle(self.b(1),self.b(1)/'RentalLegend.pck')
        self.idle.start()

    def test_new_build_and_policy_change_before_deletion(self):
        original=self.engine.proof;count=0
        def changed(*args,**kwargs):
            nonlocal count
            proof=original(*args,**kwargs);count+=1
            if count==6:self.engine.configure([self.root],[1,2],self.anchor,True)
            return proof
        with patch.object(self.engine,'proof',side_effect=changed):r=self.engine.run()
        self.assertTrue(all(x['status']!='removed' for x in r['items']))

    def test_generated_import_cache_requires_every_source_and_mapping(self):
        b=self.b(1);source=b/'source-final/godot-r1';(source/'assets').mkdir(parents=True)
        (source/'project.godot').write_text('config_version=5')
        (source/'assets/a.png').write_bytes(b'input')
        name='a.png-'+'a'*32+'.s3tc.ctex';(source/'assets/a.png.import').write_text('path="res://.godot/imported/'+name+'"')
        imported=source/'.godot/imported';imported.mkdir(parents=True);(imported/name).write_bytes(b'compiled')
        (imported/('a.png-'+'a'*32+'.md5')).write_text('generated checksums')
        (b/'tracked-source.tar').write_bytes(b'source fixture')
        (b/'source.json').write_text(json.dumps({'archive_sha256':self.engine.q.hash_file(b/'tracked-source.tar'),'tracked_source_only':True}))
        (b/'RentalLegend.xcodeproj').mkdir();(b/'RentalLegend.xcodeproj/project.pbxproj').write_text('fixture')
        modules=b/'derived/ModuleCache.noindex';(modules/'ABC').mkdir(parents=True)
        (modules/'ABC/Foundation-123.pcm').write_bytes(b'compiled')
        self.assertTrue(any(r['path']==str(modules) for r in self.verified()))
        (modules/'unique-save.db').write_bytes(b'important')
        self.assertFalse(any(r['path']==str(modules) for r in self.verified()))
        self.assertTrue(any(r['path']==str(imported) for r in self.verified()))
        (imported/'unique').write_text('unique')
        self.assertFalse(any(r['path']==str(imported) for r in self.verified()))
        (imported/'unique').unlink();(source/'assets/a.png').unlink()
        self.assertFalse(any(r['path']==str(imported) for r in self.verified()))

    def test_unregistered_or_linked_root_rejected(self):
        link=self.repo/'linked';link.symlink_to(self.root,target_is_directory=True)
        with self.assertRaises(ValueError):self.engine.configure([link],[],self.anchor,True)
        with self.assertRaises(ValueError):self.engine.proof(self.b(1),self.b(1)/'export',self.config)

    def test_cli_exclusions_are_forwarded_to_policy_checks(self):
        out=io.StringIO()
        with patch.object(bc,'BuildCare',return_value=self.engine),patch.object(sys,'argv',['build-care','scan','--exclude',str(self.b(1))]),contextlib.redirect_stdout(out):
            bc.main()
        rows=json.loads(out.getvalue())['rows']
        self.assertFalse(any(r['build']==str(self.b(1)) for r in rows))


if __name__=='__main__':unittest.main()
