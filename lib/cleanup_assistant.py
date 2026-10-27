"""Codex proposes; local allowlists and revalidation alone grant authority."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import stat
import subprocess
import time
import render_care as care
import expanded_scope
import quarantine_store
import concurrent.futures

POLICY = ('You help organize disk storage. Do not use any tools or inspect files. '
          'Each id represents all locations with identical local safety facts, not a sample. '
          'Only classify the supplied metadata. Return exactly one decision per id, with a concise Japanese reason. '
          'cleanup is permitted only when local_verified=true, regenerable=true, active=false. '
          'Otherwise keep; review if uncertain. Never suggest deleting original media, histories, '
          'models or environments. Do not produce commands. Large bytes alone never justify deletion.')


class Assistant:
    def __init__(self, studio):
        self.studio = studio
        self.state = studio.home / 'Library/Application Support/devpurge/assistant'
        self.quarantine = quarantine_store.Quarantine(studio)

    @contextlib.contextmanager
    def lock(self):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.state.resolve() != self.state:
            raise ValueError('State path must not be a link')
        fd = os.open(self.state / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.quarantine.locked():
                yield
        finally:
            os.close(fd)

    def local_check(self, item):
        if item.get('kind')=='quarantine':
            return self.quarantine.verify(item)
        s = self.studio
        p = s.physical(Path(item['path']))
        if any(p.is_relative_to(Path(root)) for root in s.read_errors):
            raise ValueError('フォルダの読み取り未完了のため保持')
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

    def review_all(self, rows, primary, reviewer):
        """Review every row in bounded requests; no partial-run deletion authority."""
        # Identical safety facts share one decision, not one sampled file.
        # Every row remains mapped to exactly one group; size never grants authority.
        groups={}
        for row in rows:
            key=(row['category'],row['local_verified'],(row.get('proof') or {}).get('kind',row.get('kind','unverified')))
            groups.setdefault(key,[]).append(row)
        members={};ordered=[]
        for index,(key,items) in enumerate(groups.items()):
            group=dict(items[0],id='g'+str(index),bytes=sum(x['bytes'] or 0 for x in items),count=len(items))
            members[group['id']]=items;ordered.append(group)
        ordered.sort(key=lambda x:(not x['local_verified'],-x['bytes']))
        review={'runs':[],'status':'not-needed','completed':0,'total':len(rows),'batches':[]}
        review['groups']=len(ordered)
        for row in rows:
            row.update(ready=False,ai_reviewed=False)
        for offset in range(0,len(ordered),12):
            batch=ordered[offset:offset+12]
            facts=[{'id':x['id'],'category':x['category'],'bytes':x['bytes'],
                    'locations':x['count'],
                    'growth_bytes':x.get('delta'),'local_verified':x['local_verified'],
                    'regenerable':x['local_verified'],'active':False if x['local_verified'] else None,
                    'verified_kind':(x.get('proof') or {}).get('kind',x.get('kind','unverified'))} for x in batch]
            record={'offset':offset,'count':len(batch),'status':'pending'}
            review['batches'].append(record)
            self.studio.progress.update(message='Codexが全件を確認中：同じ検証条件をまとめて判定（%sか所）' % len(rows),done=review['completed'],total=len(rows))
            try:
                first=self.review_request(facts,primary)
                decisions={x['id']:x for x in first['decisions']}
                review['runs'].append(first['model'])
                for group in batch:
                    for row in members[group['id']]:
                        row.update(ai_reviewed=True,ai_reason=decisions[group['id']]['reason'])
                review['completed']+=sum(x['count'] for x in batch)
                second_facts=[x for x in facts if x['local_verified'] and decisions[x['id']]['decision'] in ('cleanup','review')]
                if second_facts:
                    self.studio.progress['message']='別のモデルで削除候補を再確認しています（全件調査を継続中）'
                    second=self.review_request(second_facts,reviewer)
                    decisions.update({x['id']:x for x in second['decisions']})
                    review['runs'].append(second['model'])
                for group in batch:
                    for row in members[group['id']]:
                        row['ai_reason']=decisions[group['id']]['reason']
                        row['ready']=row['local_verified'] and decisions[group['id']]['decision']=='cleanup'
                record['status']='reviewed'
            except (ValueError,OSError,subprocess.SubprocessError) as e:
                record.update(status='unavailable',error=str(e))
            # Preserve coverage evidence even if a later request or app run fails.
            care.save(self.state/'review-progress.json',review)
        review['runs']=list(dict.fromkeys(review['runs']))
        if any(x['status']!='reviewed' for x in review['batches']):
            review.update(status='unavailable',error='一部のAI確認に失敗しました。全候補を保持しました。再実行してください。')
            for row in rows:row['ready']=False
        elif rows:
            review['status']='reviewed'
        return review

    def review_request(self,facts,model):
        for attempt in range(2):
            try:return care.model_review(facts,model,self.state,policy=POLICY)
            except (subprocess.TimeoutExpired,ValueError) as e:
                retryable=isinstance(e,(subprocess.TimeoutExpired,json.JSONDecodeError)) or 'IDs' in str(e) or 'Invalid model' in str(e)
                if not retryable:raise
                if attempt:raise ValueError('AIの応答を再試行しても検証できなかったため保持') from e
                self.studio.progress['message']='AIの応答を再試行しています。削除は行いません。'

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
                for item in self.quarantine.entries():
                    items[item['path']]={**item,'action':'quarantine'}
                for item in items.values():
                    if item.get('kind')=='quarantine':s.progress['message']='隔離記録と保持元を照合しています：'+item['qid']
                    row = {k: item.get(k) for k in ('id', 'path', 'title', 'category', 'bytes', 'delta', 'reason','kind','original','qid','review_after')}
                    row.update(ready=False, local_verified=False)
                    # Only supported deletion grammars need expensive checks.
                    if item.get('action') in ('trash','expanded','quarantine') or (item.get('category') == 'build' and Path(item['path']).name in ('.next', '.open-next')):
                        try:
                            row['proof'] = self.local_check(item)
                            row.update(local_verified=True, reason='再生成でき、使用中ではないことを確認。'+item.get('reason',''))
                            if item.get('kind')=='quarantine':
                                row['bytes']=row['proof']['tree']['bytes']
                                row['reason']='隔離時の内容と保持元を再検証。'+row['proof']['reconstruction']
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
                review=self.review_all(rows,primary,reviewer)
                report = {'at': time.time(), 'scan_at': scan['at'], 'free': shutil.disk_usage(s.home).free,
                          'rows': rows, 'review': review, 'primary': primary, 'reviewer': reviewer,
                          'render_error':render_error,
                          'scope': '開発フォルダ9階層、Codex/Claudeの隠しworktree内、開発ツールとアプリのキャッシュ、大容量の保存場所。原本・履歴は保持。親子の容量は重複するため合算しません。',
                          'locations':len(rows),'ai_locations':review['completed'],
                          'unreadable_locations':s.read_errors,
                          'large_locations':sorted(scan.get('landscape',[]),key=lambda x:x.get('bytes') or 0,reverse=True)[:12],
                          'discovery_limited': scan['discovery_limited'] or getattr(s,'expanded_limited',False)}
                care.save(self.state / 'report.json', report)
                return report
            finally:
                s.progress.update(running=False, message='整理案の確認が完了しました')

    def plan(self, ids):
        if not isinstance(ids, list) or not ids or len(ids) > 20000 or any(not isinstance(x, str) for x in ids) or len(set(ids)) != len(ids):
            raise ValueError('有効な候補を重複なく確認してください')
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
                    if row.get('kind')=='quarantine':self.quarantine.mark(row['proof']['record'],'deleting')
                    if row.get('kind')=='quarantine' and stat.S_ISREG(st.st_mode):os.unlink(p.name,dir_fd=fd)
                    else:shutil.rmtree(p.name, dir_fd=fd)
                finally:
                    os.close(fd)
                entry.update(status='removed', bytes=row['proof']['tree']['bytes'])
                receipt['removed_bytes'] += entry['bytes']
                if row.get('kind')=='quarantine':
                    self.quarantine.mark(row['proof']['record'],'deleted')
                    self.quarantine.drop(row['proof']['record'])
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
