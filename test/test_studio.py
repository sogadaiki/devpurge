#!/usr/bin/env python3
"""All mutations use disposable fixtures. Never scan or clean the real HOME."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('studio', Path(__file__).resolve().parents[1] / 'lib/studio.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StudioTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name).resolve()
        self.s = module.Studio(self.home, self.home / 'state')
        self.cache = self.home / 'Library/Caches/pip'
        self.cache.mkdir(parents=True)
        (self.cache / 'wheel').write_text('fixture package')
        self.old(self.cache)
        self.item = {'id': 'pip', 'path': str(self.cache), 'action': 'trash', 'bytes': 20, 'title': 'pip'}
        self.s.result = {'items': [self.item]}

    def tearDown(self):
        self.temp.cleanup()

    def old(self, root):
        for p in [*root.rglob('*'), root]:
            os.utime(p, (time.time()-172800, time.time()-172800))

    def make_plan(self):
        with patch.object(self.s, 'idle'):
            return self.s.plan(['pip'])

    def apply(self, plan):
        with patch.object(self.s, 'idle'):
            return self.s.apply(plan['id'])

    def test_move_and_restore(self):
        plan = self.make_plan()
        self.assertTrue(self.cache.exists(), 'plan must not mutate')
        r = self.apply(plan)
        self.assertEqual(r['status'], 'moved')
        self.assertFalse(self.cache.exists())
        dest = Path(r['entries'][0]['destination'])
        self.assertEqual((dest / 'wheel').read_text(), 'fixture package')
        self.s.restore(r['id'])
        self.assertEqual((self.cache / 'wheel').read_text(), 'fixture package')

    def test_recreated_source_not_overwritten(self):
        r = self.apply(self.make_plan())
        self.cache.mkdir()
        (self.cache / 'new').write_text('new package')
        with self.assertRaisesRegex(ValueError, '上書き'):
            self.s.restore(r['id'])
        self.assertTrue(Path(r['entries'][0]['destination']).exists())

    def test_changed_tree_refused(self):
        p = self.make_plan()
        (self.cache / 'wheel').write_text('changed')
        with self.assertRaisesRegex(ValueError, '変わり'):
            self.apply(p)
        self.assertTrue(self.cache.exists())

    def test_plan_one_use(self):
        p = self.make_plan()
        self.apply(p)
        with self.assertRaises(ValueError):
            self.apply(p)

    def test_expired_plan(self):
        p = self.make_plan()
        self.s.plans[p['id']]['created'] -= 301
        with self.assertRaises(ValueError):
            self.apply(p)

    def test_review_and_arbitrary_paths_refused(self):
        self.item['action'] = 'review'
        with self.assertRaises(ValueError):
            self.make_plan()
        self.item.update(action='trash', path=str(self.home))
        with self.assertRaises(ValueError):
            self.make_plan()

    def test_nested_secret_blocks_without_reading(self):
        (self.cache / '.env.production').write_text('synthetic fixture')
        with self.assertRaisesRegex(ValueError, '保護'):
            self.make_plan()

    def test_nested_protected_unicode(self):
        import unicodedata
        (self.cache / unicodedata.normalize('NFD', '弁護士.txt')).touch()
        with self.assertRaises(ValueError):
            self.make_plan()

    def test_symlink_inside_and_parent_refused(self):
        (self.cache / 'link').symlink_to(self.home)
        with self.assertRaisesRegex(ValueError, 'リンク'):
            self.make_plan()
        alias = self.home / 'alias'
        alias.symlink_to(self.cache.parent)
        with self.assertRaises(ValueError):
            self.s.physical(alias / 'pip')

    def test_custom_protection_and_exclusions(self):
        (self.home / '.devpurgerc').write_text('protect=hold-me\nexclude=~/Library/Caches/pip\narchive_root=~/archive\n')
        s = module.Studio(self.home)
        for path in [self.cache, self.home/'hold-me/output', self.home/'archive/a', self.home/'Desktop/development/sadame/foo']:
            self.assertTrue(s.blocked(path))

    def test_recent_changes_block(self):
        with self.assertRaisesRegex(ValueError, '24時間'):
            self.s.idle(self.cache, time.time())

    def test_lsof_fail_closed(self):
        for reply in [(0, 'open file', ''), (-1, '', 'timeout'), (1, '', 'permission denied')]:
            with patch.object(module, 'command', return_value=reply):
                with self.assertRaises(ValueError):
                    self.s.idle(self.cache, time.time()-172800)

    def test_idle_empty_lsof_and_package_manager(self):
        with patch.object(module, 'command', side_effect=[(1,'',''),(0,'/bin/zsh','')]):
            self.s.idle(self.cache, time.time()-172800)
        with patch.object(module, 'command', side_effect=[(1,'',''),(0,'/usr/local/bin/uv','')]):
            with self.assertRaisesRegex(ValueError, 'パッケージ'):
                self.s.idle(self.cache, time.time()-172800)

    def completion(self):
        output = self.home / 'Desktop/development/project/renders'
        output.mkdir(parents=True)
        (output / 'temp.mp4').write_text('intermediate')
        self.old(output)
        keeper = self.home / 'finished.mp4'
        keeper.write_text('retained final')
        record = self.s.complete({'title':'Test','keepers':[str(keeper)],'intermediates':[str(output)],'acknowledged':True})
        return output, keeper, record

    def test_completion_hash_and_retention(self):
        output, keeper, record = self.completion()
        self.assertTrue(output.exists())
        with patch.object(self.s, 'idle'):
            plan = self.s.completion_plan(record['id'])
        r = self.apply(plan)
        self.assertEqual(r['status'], 'moved')
        self.assertEqual(keeper.read_text(), 'retained final')
        self.s.restore(r['id'])
        self.assertEqual((output/'temp.mp4').read_text(), 'intermediate')

    def test_changed_keeper_blocks_at_apply(self):
        output, keeper, record = self.completion()
        with patch.object(self.s, 'idle'):
            plan = self.s.completion_plan(record['id'])
        keeper.write_text('changed final')
        with self.assertRaisesRegex(ValueError, '完成品'):
            self.apply(plan)
        self.assertTrue(output.exists())

    def test_keeper_inside_intermediate_refused(self):
        output, _, _ = self.completion()
        with self.assertRaisesRegex(ValueError, '中間フォルダの中'):
            self.s.complete({'title':'bad','keepers':[str(output/'temp.mp4')],'intermediates':[str(output)],'acknowledged':True})

    def test_credential_keeper_not_read(self):
        key = self.home/'example.pem'
        key.write_text('synthetic')
        with self.assertRaisesRegex(ValueError, '認証情報'):
            self.s.keeper_hash(key)

    def test_completion_requires_explicit_acknowledgement(self):
        with self.assertRaises(ValueError):
            self.s.complete({'title':'test','acknowledged':False})

    def test_du_error_is_unknown_not_zero(self):
        with patch.object(module,'command',return_value=(1,'1024\tfixture\n','permission')):
            item = self.s.measure((self.cache,'cache','pip','reason','trash'))
        self.assertIsNone(item['bytes'])
        self.assertEqual(item['observed_bytes'],1024*1024)
        self.assertEqual(item['action'],'review')

    def test_parent_child_not_double_counted_and_delta(self):
        parent = self.item | {'id':'parent','category':'cache','bytes':100}
        child = parent | {'id':'child','path':str(self.cache/'wheel'),'bytes':40}
        specs = [('parent',),('child',)]
        self.s.discovery_limited=False
        with patch.object(self.s,'discover',return_value=specs), patch.object(self.s,'measure',side_effect=[parent,child]), patch.object(self.s,'landscape',return_value=[]), patch.object(self.s,'system',return_value={'free':1,'swap_used':0}):
            # progress label requires a complete spec tuple
            specs[:]=[('parent','cache','parent'),('child','cache','child')]
            result = self.s.scan()
        self.assertEqual(len(result['items']),1)
        self.assertEqual(result['items'][0]['bytes'],100)

    def test_uv_prune_exact_command_and_no_shell(self):
        uv = self.home/'.cache/uv'
        uv.mkdir(parents=True)
        self.old(uv)
        with patch.object(module.shutil,'which',return_value='/usr/local/bin/uv'),patch.object(self.s,'idle'):
            p=self.s.refresh_plan()
        with patch.object(module,'command',return_value=(0,'pruned fixture','')) as cmd,patch.object(self.s,'idle'):
            r=self.s.apply(p['id'])
        self.assertEqual(r['status'],'completed')
        self.assertEqual(cmd.call_args.args[0],['/usr/local/bin/uv','cache','prune','--cache-dir',str(uv),'--offline','--no-config','--no-progress'])
        self.assertTrue(uv.exists())  # mocked tool, no real deletion

    def test_browse_uses_known_ids_and_hides_secrets(self):
        (self.cache/'.env').write_text('fixture only')
        with self.assertRaises(ValueError):
            self.s.browse('../../etc')
        data=self.s.browse('pip')
        self.assertEqual([i['title'] for i in data['items']],['wheel'])

    def test_legacy_sensitive_targets_are_review(self):
        source=(Path(__file__).resolve().parents[1]/'lib/paths.sh').read_text()
        for id_ in ['A04','A08','A10','A11','A12','A13','D11','D14','D18','D19','D20']:
            row=next(line for line in source.splitlines() if '"'+id_+'|' in line)
            self.assertIn('|review|',row)

    def test_host_origin_and_token_guards(self):
        server=module.Server(('127.0.0.1',0),module.handler(self.s,'test-token'))
        t=threading.Thread(target=server.serve_forever,daemon=True);t.start()
        url='http://127.0.0.1:'+str(server.server_port)
        try:
            for headers in [{},{'X-Studio-Token':'wrong'},{'X-Studio-Token':'test-token','Origin':'https://evil.example'},{'X-Studio-Token':'test-token','Host':'evil.example'}]:
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(urllib.request.Request(url+'/api/state',headers=headers))
                self.assertEqual(error.exception.code,403)
            r=urllib.request.urlopen(urllib.request.Request(url+'/api/state',headers={'X-Studio-Token':'test-token'}))
            self.assertEqual(r.status,200)
            self.assertIn("frame-ancestors 'none'",r.headers['Content-Security-Policy'])
        finally:
            server.shutdown();server.server_close();t.join()


if __name__=='__main__':
    unittest.main()
