"""Codex proposes; local allowlists and revalidation alone grant authority."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import time
import render_care as care
import expanded_scope
import concurrent.futures

POLICY = ('You help organize disk storage. Do not use any tools or inspect files. '
          'Only classify the supplied metadata. Return exactly one decision per id, with a concise Japanese reason. '
          'cleanup is permitted only when local_verified=true, regenerable=true, active=false. '
          'Otherwise keep; review if uncertain. Never suggest deleting original media, histories, '
          'models or environments. Do not produce commands. Large bytes alone never justify deletion.')


class Assistant:
    def __init__(self, studio):
        self.studio = studio
        self.state = studio.home / 'Library/Application Support/devpurge/assistant'

    @contextlib.contextmanager
    def lock(self):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.state.resolve() != self.state:
            raise ValueError('State path must not be a link')
        fd = os.open(self.state / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    def local_check(self, item):
        s = self.studio
        p = s.physical(Path(item['path']))
        if not p.is_dir() or p.stat().st_uid != os.getuid():
            raise ValueError('所有者・フォルダを確認できないため保持')
        fixed = {str(path): action for path, _, _, _, action in s.targets()}
        kind, manifest = 'download-cache', None
        extra = None
        if fixed.get(str(p)) != 'trash':
            # Only ignored Next build outputs with retained build instructions.
            if p.name not in ('.next', '.open-next'):
                extra = expanded_scope.evidence(s,p)
                tree=s.tree(p);s.idle(p,tree['newest'])
                return {**extra,'tree':tree,'identity':care.identity(p)}
            if not expanded_scope.in_projects(p,s.home):raise ValueError('対応範囲外のため保持')
            package = s.physical(p.parent / 'package.json')
            if not package.is_file() or package.stat().st_size > 1048576:
                raise ValueError('再生成元の設定を確認できないため保持')
            raw = package.read_bytes()
            data = json.loads(raw)
            deps = {**data.get('dependencies', {}), **data.get('devDependencies', {})}
            if 'next' not in deps or 'build' not in data.get('scripts', {}):
                raise ValueError('Nextの再生成手順を確認できないため保持')
            for argv, wanted in ((['git', '-C', str(p.parent), 'check-ignore', '-q', '--', p.name], 0),
                                 (['git', '-C', str(p.parent), 'ls-files', '--', p.name], 0)):
                result = care.run(argv)
                if result.returncode != wanted or result.stdout.strip() or result.stderr.strip():
                    raise ValueError('Gitで管理されたデータ、または除外未確認のため保持')
            observed = care.activity([str(p.parent)])
            if observed['renderers'] or care.open_under(p.parent, observed):
                raise ValueError('プロジェクトを使用中の処理があるため保持')
            manifest = {'path': str(package), 'sha256': hashlib.sha256(raw).hexdigest()}
            kind = 'next-build'
        tree = s.tree(p)
        s.idle(p, tree['newest'])
        return {'tree': tree, 'kind': kind, 'manifest': manifest, 'identity':care.identity(p)}

    def render_engine(self):
        return care.Care(state=self.studio.home / 'Library/Application Support/devpurge/render-care')

    def render_scan(self):
        config = care.load(self.studio.home / 'Library/Application Support/devpurge/render-care/config.json', {})
        if not config.get('sources'):
            return None
        engine = self.render_engine()
        with engine.locked():
            return engine.scan(verify=True)

    def prepare(self, primary='sol', reviewer='terra'):
        if primary not in care.MODELS or reviewer not in care.MODELS:
            raise ValueError('モデルを選択してください')
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        previous = care.load(self.state / 'report.json', {'rows':[]})
        for row in previous.get('rows', []):
            row['ready'] = False
        previous['review'] = {'status':'pending','runs':[]}
        care.save(self.state / 'report.json', previous)
        care.save(self.state / 'plan.json', {})
        scan = self.studio.scan()
        with self.studio.lock:
            s = self.studio
            s.progress.update(running=True, message='隠し作業フォルダ・開発ツール・アプリ別キャッシュまで調べています', done=0, total=0)
            try:
                specs=expanded_scope.fixed_specs(s)+expanded_scope.discover(s)
                # Overlapping parent storage totals remain informational only;
                # child candidates are separately verified, never summed twice.
                items={x['path']:x for x in scan['items']}
                with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                    for item in pool.map(s.measure,specs):
                        if item:
                            previous=items.get(item['path'])
                            if previous and item['action']=='review':continue
                            item['delta']=(previous or {}).get('delta')
                            items[item['path']]=item
                for item in scan.get('landscape',[]):
                    if item['path'] not in items:
                        items[item['path']]={**item,'delta':None}
                s.progress.update(message='削除可能性と作業中のデータを確認しています',done=0,total=len(items))
                rows = []
                for item in items.values():
                    row = {k: item.get(k) for k in ('id', 'path', 'title', 'category', 'bytes', 'delta', 'reason')}
                    row.update(ready=False, local_verified=False)
                    # Only supported deletion grammars need expensive checks.
                    if item.get('action') in ('trash','expanded') or (item.get('category') == 'build' and Path(item['path']).name in ('.next', '.open-next')):
                        try:
                            row['proof'] = self.local_check(item)
                            row.update(local_verified=True, reason='再生成でき、使用中ではないことを確認。'+item.get('reason',''))
                        except (ValueError, OSError, subprocess.SubprocessError) as e:
                            row['reason'] = str(e)
                    rows.append(row)
                    s.progress['done'] += 1
                render_error = None
                try:
                    s.progress['message'] = 'レンダリングの一時コピーと元素材を照合しています'
                    renders = self.render_scan()
                    if renders:
                        temp = care.user_temp()
                        for item in renders['items']:
                            verified = item['status'] == 'verified'
                            rows.append({'id':item['id'], 'path':str(temp/item['name']), 'title':item['name'],
                                         'category':'intermediate', 'kind':'render-copy', 'delta':item.get('delta'),
                                         'bytes':item.get('reclaimable_bytes') if verified else item.get('bytes'),
                                         'reason':'元素材と一致する一時コピー。異なる内容は保持' if verified else item['reason'],
                                         'ready':False, 'local_verified':verified,
                                         'proof':{'tree':{'bytes':item.get('reclaimable_bytes',0)}, 'render':item} if verified else None})
                except (OSError, ValueError, subprocess.SubprocessError) as e:
                    render_error = str(e)
                # All locally eligible candidates plus largest retained categories.
                chosen = sorted(rows, key=lambda x: (not x['local_verified'], -(x['bytes'] or 0)))[:80]
                facts = [{'id': x['id'], 'category': x['category'], 'bytes': x['bytes'],
                          'growth_bytes': x['delta'], 'local_verified': x['local_verified'],
                          'regenerable': x['local_verified'], 'active': not x['local_verified']} for x in chosen]
                review = {'runs': [], 'status': 'not-needed'}
                if facts:
                    try:
                        s.progress['message'] = 'Codexが整理案を作成しています。ファイル内容は送信しません'
                        first = care.model_review(facts, primary, self.state, policy=POLICY)
                        decisions = {x['id']: x for x in first['decisions']}
                        review['runs'].append(first['model'])
                        # Every deletion recommendation receives an independent review.
                        second_facts = [x for x in facts if x['local_verified'] and decisions[x['id']]['decision'] in ('cleanup', 'review')]
                        if second_facts:
                            s.progress['message'] = '別のモデルで削除候補を再確認しています'
                            second = care.model_review(second_facts, reviewer, self.state, policy=POLICY)
                            decisions.update({x['id']: x for x in second['decisions']})
                            review['runs'].append(second['model'])
                        for row in rows:
                            decision = decisions.get(row['id'], {})
                            row['ai_reason'] = decision.get('reason', 'ローカル保持条件に従い保持')
                            row['ready'] = row['local_verified'] and decision.get('decision') == 'cleanup'
                        review['status'] = 'reviewed'
                    except (ValueError, OSError, subprocess.SubprocessError) as e:
                        review.update(status='unavailable', error=str(e))
                        for row in rows:
                            row['ready'] = False
                report = {'at': time.time(), 'scan_at': scan['at'], 'free': shutil.disk_usage(s.home).free,
                          'rows': rows, 'review': review, 'primary': primary, 'reviewer': reviewer,
                          'render_error':render_error,
                          'scope': '開発フォルダ9階層、Codex/Claudeの隠しworktree内、開発ツールとアプリのキャッシュ、大容量の保存場所。原本・履歴は保持。親子の容量は重複するため合算しません。',
                          'locations':len(rows),'ai_locations':len(facts),
                          'large_locations':sorted(scan.get('landscape',[]),key=lambda x:x.get('bytes') or 0,reverse=True)[:12],
                          'discovery_limited': scan['discovery_limited'] or getattr(s,'expanded_limited',False)}
                care.save(self.state / 'report.json', report)
                return report
            finally:
                s.progress.update(running=False, message='整理案の確認が完了しました')

    def plan(self, ids):
        if not isinstance(ids, list) or not ids or len(ids) > 80 or any(not isinstance(x, str) for x in ids) or len(set(ids)) != len(ids):
            raise ValueError('1〜80項目を確認してください')
        report = care.load(self.state / 'report.json', {})
        if not 0 <= time.time() - report.get('at', 0) < 1800 or report.get('review', {}).get('status') != 'reviewed':
            raise ValueError('AI整理案を再作成してください（有効期限30分）')
        rows = {x['id']: x for x in report.get('rows', [])}
        entries = []
        renders = self.render_scan() if any(rows.get(id_,{}).get('kind')=='render-copy' for id_ in ids) else None
        render_items = {x['id']:x for x in (renders or {}).get('items',[])}
        for id_ in ids:
            row = rows.get(id_)
            if not row or not row['ready']:
                raise ValueError('対象が変化した、使用中、または削除許可がないため保持')
            if row.get('kind')=='render-copy':
                current = render_items.get(id_,{})
                if current.get('status')!='verified' or current.get('proof')!=row['proof']['render']['proof']:
                    raise ValueError('一時コピーの内容・使用状況が変わったため保持')
            elif self.local_check(row) != row['proof']:
                raise ValueError('対象が変化したため保持')
            entries.append(row)
        plan = {'id': secrets.token_hex(16), 'at': time.time(), 'entries': entries,
                'bytes': sum(x['proof']['tree']['bytes'] for x in entries), 'permanent': True, 'renders':renders}
        care.save(self.state / 'plan.json', plan)
        return {k:v for k,v in {**plan, 'entries': [{k:v for k,v in x.items() if k != 'proof'} for x in entries]}.items() if k!='renders'}

    def apply(self, ticket):
        plan = care.load(self.state / 'plan.json', {})
        if not isinstance(ticket, str) or ticket != plan.get('id') or not 0 <= time.time() - plan.get('at', 0) < 300:
            raise ValueError('確認の有効期限が切れました。対象を再確認してください')
        if not shutil.rmtree.avoids_symlink_attacks:
            raise ValueError('安全な削除に対応するPythonが必要です')
        # Consume the plan even on a later failure.
        care.save(self.state / 'plan.json', {})
        receipt = {'id':ticket, 'at':time.time(), 'before_free':shutil.disk_usage(self.studio.home).free,
                   'items':[], 'status':'running', 'removed_bytes':0}
        path = self.state / 'receipts' / (ticket+'.json')
        care.save(path, receipt)
        for row in plan['entries']:
            if row.get('kind')=='render-copy':
                continue
            entry = {'title':row['title'], 'path':row['path'], 'status':'kept'}
            receipt['items'].append(entry)
            try:
                if self.local_check(row) != row['proof']:
                    raise ValueError('直前に内容が変化したため保持')
                p = Path(row['path'])
                # Open every ancestor without following links, pinning the parent.
                fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
                try:
                    for part in p.parent.parts[1:]:
                        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                        os.close(fd); fd = child
                    st = os.stat(p.name, dir_fd=fd, follow_symlinks=False)
                    identity = [st.st_dev, st.st_ino, st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns]
                    if identity != row['proof']['identity']:
                        raise ValueError('対象が入れ替わったため保持')
                    entry['status'] = 'deleting'
                    care.save(path, receipt)
                    shutil.rmtree(p.name, dir_fd=fd)
                finally:
                    os.close(fd)
                entry.update(status='removed', bytes=row['proof']['tree']['bytes'])
                receipt['removed_bytes'] += entry['bytes']
            except (OSError, ValueError, TypeError, subprocess.SubprocessError) as e:
                entry.update(status='kept-or-partial', reason=str(e))
            care.save(path, receipt)
        render_rows = [x for x in plan['entries'] if x.get('kind')=='render-copy']
        if render_rows:
            try:
                engine = self.render_engine()
                decisions = {'decisions':[{'id':x['id'],'decision':'cleanup','reason':'local verification and dual Codex review'} for x in render_rows]}
                with engine.locked():
                    result = engine.apply(plan['renders'], decisions)
                by_name = {x['name']:x for x in result['items']}
                for row in render_rows:
                    item = by_name.get(row['title'],{})
                    removed = item.get('status') in ('removed','trimmed')
                    receipt['items'].append({'title':row['title'],'path':row['path'],'status':'removed' if removed else 'kept-or-partial',
                                             'bytes':item.get('bytes',0) if removed else 0,'reason':item.get('error','')})
                receipt['removed_bytes'] += result['removed_bytes']
            except (ValueError, OSError, subprocess.SubprocessError) as e:
                receipt['items'].extend({'title':x['title'],'path':x['path'],'status':'kept-or-partial','reason':str(e)} for x in render_rows)
        receipt['status'] = 'completed' if all(x['status']=='removed' for x in receipt['items']) else 'partial'
        receipt['after_free'] = shutil.disk_usage(self.studio.home).free
        receipt['free_delta'] = receipt['after_free'] - receipt['before_free']
        care.save(path, receipt)
        care.save(self.state / 'receipt.json', receipt)
        report = care.load(self.state / 'report.json', {})
        for row in report.get('rows', []):
            row['ready'] = False
        care.save(self.state / 'report.json', report)
        return receipt

    def status(self):
        report = care.load(self.state / 'report.json', {'rows':[]})
        report['rows'] = [{k:v for k,v in x.items() if k != 'proof'} for x in report['rows']]
        operation = care.load(self.state/'operation.json', {})
        if operation.get('running') and operation.get('owner') != self.studio.assistant_owner:
            operation = {**operation, 'running':False, 'error':'前回の確認は中断されました。AIで片付けるを押して再確認できます。'}
        return {'report':report, 'receipt':care.load(self.state/'receipt.json', {}), 'operation':operation}
