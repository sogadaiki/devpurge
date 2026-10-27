"""Project quarantine: audited evidence, shared mutation lock, no automatic expiry."""
import contextlib
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid
import render_care as care


class Quarantine:
    def __init__(self, studio):
        self.s=studio
        self.root=studio.home/'Library/Application Support/devpurge/quarantine'
        self.audits=self.root.parent/'audits'

    @contextlib.contextmanager
    def locked(self):
        self.s.physical(self.root)
        self.root.mkdir(parents=True,exist_ok=True)
        lock=self.root/'.operation-lock'
        try:lock.mkdir(mode=0o700)
        except FileExistsError:raise ValueError('隔離データを別の処理が操作中、または前回中断のロックが残っています')
        try:yield
        finally:lock.rmdir()

    def read_json(self,path,default=None):
        self.s.physical(path)
        if not path.exists():return default
        if path.stat().st_size>32*2**20:raise ValueError('監査記録が検証上限を超えています')
        return json.loads(path.read_text())

    def catalog(self):
        return self.read_json(self.root/'catalog.json',{'version':1,'entries':{}})

    def save_catalog(self,data):
        self.s.physical(self.root/'catalog.json')
        care.save(self.root/'catalog.json',data)

    def entries(self):
        manifest=self.s.physical(self.root/'manifest.tsv')
        if not manifest.exists():return []
        if manifest.stat().st_size>8*2**20:raise ValueError('隔離台帳が大きすぎるため保持')
        with manifest.open() as f:raw=list(csv.reader(f,delimiter='\t'))
        ids=[x[0] for x in raw if x]
        result=[];catalog=self.catalog()
        for x in raw:
            if not x:continue
            if len(x)!=6 or not re.fullmatch(r'Q\d+',x[0]) or ids.count(x[0])!=1:
                raise ValueError('隔離台帳の形式・ID重複を確認してください')
            qid,epoch,original,kb,stored,reason=x
            epoch=int(epoch);size=int(kb)*1024
            if epoch<0 or size<0:raise ValueError('隔離記録の日時・容量が不正です')
            key=str(uuid.uuid5(uuid.NAMESPACE_URL,json.dumps([qid,epoch,original,stored])))
            meta=catalog['entries'].get(key,{})
            try:
                parts=Path(original).relative_to(self.s.home/'Desktop/development').parts
                project=parts[1] if parts[0]=='.worktrees' else parts[0]
            except (ValueError,IndexError):project='その他の作業コピー'
            result.append({'id':'quarantine-'+key,'uuid':key,'qid':qid,'epoch':epoch,
                'original':original,'path':stored,'bytes':size,'category':'intermediate',
                'title':qid+' / '+Path(original).name,'reason':reason,'kind':'quarantine',
                'project':project,
                'review_after':meta.get('review_after',epoch+30*86400),'status':meta.get('status','held')})
        return result

    def entry(self,key):
        rows=[x for x in self.entries() if x['id']==key]
        if len(rows)!=1:raise ValueError('隔離項目が変更・復元・削除されました')
        return rows[0]

    def paths(self,row):
        original=self.s.physical(Path(row['original']))
        stored=self.s.physical(Path(row['path']))
        if not original.is_relative_to(self.s.home) or original.is_relative_to(self.root):
            raise ValueError('元パスが対応範囲外です')
        if stored.parent!=self.root or stored.name!=row['qid']+'-'+original.name or not stored.is_dir():
            raise ValueError('隔離先の所在・形式を確認できません')
        if stored.stat().st_uid!=os.getuid():raise ValueError('隔離物の所有者が異なります')
        return original,stored

    def hash_file(self,path):
        self.s.physical(path)
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
        return self.hash_descriptor(fd)

    @staticmethod
    def hash_descriptor(fd):
        with os.fdopen(fd,'rb') as f:
            before=os.fstat(f.fileno())
            if not stat.S_ISREG(before.st_mode):raise ValueError('通常ファイル以外は保持')
            h=hashlib.sha256()
            for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
            after=os.fstat(f.fileno())
            if (before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):
                raise ValueError('検証中に内容が変化しました')
        return h.hexdigest()

    def inventory(self,path,contents=False,packages=False):
        """Compatible with local audit v1; never follow directory/file links."""
        self.s.physical(path)
        rows=[];allocated=0;allocated_ids=set();start=time.monotonic()
        def fail(error):raise error
        rootfd=self.open_directory(path)
        try:
            for base,dirs,files,fd in os.fwalk('.',dir_fd=rootfd,follow_symlinks=False,onerror=fail):
                if packages and base=='.':dirs[:]=[d for d in dirs if d not in ('.cache','.mf')]
                for name in sorted(dirs+files):
                    p=path/base/name;rel=str(p.relative_to(path));st=os.stat(name,dir_fd=fd,follow_symlinks=False)
                    if self.s.blocked(p) or name.lower() in ('id_rsa','id_ed25519','credentials','export_credentials.cfg') or name.lower().endswith(('.pem','.key','.p12','.pfx')):
                        raise ValueError('保護・機密ファイルを含むため保持')
                    if len(rows)>250000 or time.monotonic()-start>120:raise ValueError('隔離物の検証上限のため保持')
                    inode=(st.st_dev,st.st_ino)
                    if inode not in allocated_ids:
                        allocated_ids.add(inode);allocated+=st.st_blocks*512
                    mode=stat.S_IMODE(st.st_mode)
                    if stat.S_ISLNK(st.st_mode):
                        if not p.resolve().is_relative_to(path):raise ValueError('隔離物の外を参照するリンクがあるため保持')
                        rows.append([rel,'link',os.readlink(name,dir_fd=fd),mode])
                    elif stat.S_ISDIR(st.st_mode):rows.append([rel,'dir',mode])
                    elif stat.S_ISREG(st.st_mode):
                        digest=self.hash_descriptor(os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)) if contents else st.st_mtime_ns
                        rows.append([rel,'file',st.st_size,digest,mode])
                    else:raise ValueError('特殊ファイルを含むため保持')
        finally:os.close(rootfd)
        rows.sort(key=lambda x:x[0])
        return {'digest':hashlib.sha256(json.dumps(rows,ensure_ascii=False).encode()).hexdigest(),
                'files':sum(x[1]=='file' for x in rows),'entries':len(rows),
                'logical_bytes':sum(x[2] for x in rows if x[1]=='file')},allocated

    def binding(self,row):
        found=[]
        if not self.audits.exists():raise ValueError('隔離時の検証記録がありません')
        folders=list(self.audits.iterdir())
        if len(folders)>500:raise ValueError('監査記録の探索上限です')
        for folder in folders:
            if folder.is_symlink() or not folder.is_dir():continue
            receipt=self.read_json(folder/'movement-receipt.json',[])
            if not isinstance(receipt,list):continue
            matching=[r for r in receipt if r.get('id')==row['qid'] and r.get('stored')==row['path'] and r.get('original')==row['original'] and r.get('epoch')==row['epoch']]
            if not matching:continue
            plan=self.read_json(folder/'execution-plan.json',{})
            targets=[x for x in plan.get('targets',[]) if x.get('path')==row['original']]
            if len(matching)!=1 or len(targets)!=1:raise ValueError('監査記録が重複・不足しています')
            found.append((folder,targets[0]))
        if len(found)!=1:raise ValueError('一意な監査記録と生成元を確認できないため保持')
        return found[0]

    def idle(self,path):
        # Freshly moved quarantine has new ctime. Age is not a permission gate;
        # audit equality and present use checks replace the ordinary 24h wait.
        self.s.idle(path,0)
        observed=care.activity()
        if care.open_under(path,observed) or any(str(path) in x for x in observed.get('arguments',[])):
            raise ValueError('隔離物を使用・参照する処理があるため保持')

    def references(self,root,stored):
        """Check the recorded source project for links back to quarantine."""
        self.s.physical(root)
        count=0;start=time.monotonic()
        def fail(error):raise error
        for base,dirs,files in os.walk(root,followlinks=False,onerror=fail):
            dirs[:]=[x for x in dirs if x!='.git']
            for name in dirs+files:
                count+=1
                if count>300000 or time.monotonic()-start>30:raise ValueError('元プロジェクトの参照確認が未完了のため保持')
                p=Path(base)/name
                if p.is_symlink() and p.resolve().is_relative_to(stored):
                    raise ValueError('元プロジェクトから隔離物への参照があるため保持')

    def verify(self,row):
        row=self.entry(row['id'])
        # Probe in a read-only child before touching protected project folders.
        self.s.directory(Path(row['original']).parent,1)
        original,stored=self.paths(row)
        meta=self.catalog()['entries'].get(row['uuid'],{})
        if meta.get('review_after',0)>time.time():raise ValueError('保持期間を延長したため保持')
        folder,target=self.binding(row)
        initial_identity=care.identity(stored)
        root=self.s.physical(Path(target.get('root',str(original.parent))))
        if not root.is_relative_to(self.s.home) or not original.is_relative_to(root):
            raise ValueError('記録した元プロジェクトの範囲が不正です')
        self.references(root,stored)
        inventory,allocated=self.inventory(stored)
        if inventory!=target.get('inventory'):raise ValueError('隔離時の内容と一致しないため保持')
        proof=target.get('proof',{})
        for key,filename in (('package','package.json'),('lock','package-lock.json')):
            p=original.parent/filename
            if proof.get(key)!=str(p) or self.hash_file(p)!=proof.get(key+'_sha256'):
                raise ValueError('保持した生成元・lockfileが変わったため保持')
        package=json.loads((original.parent/'package.json').read_text())
        if original.name in ('.next','.open-next') and target.get('kind')=='regenerable_build':
            deps={**package.get('dependencies',{}),**package.get('devDependencies',{})}
            ignored=care.run(['git','-C',str(original.parent),'check-ignore','-q','--',original.name+'/'])
            tracked=care.run(['git','-C',str(original.parent),'ls-files','--',original.name])
            if 'next' not in deps or ignored.returncode or tracked.returncode or ignored.stderr or tracked.stderr or tracked.stdout.strip():
                raise ValueError('Next生成物・Git除外を確認できないため保持')
            script='build' if original.name=='.next' else 'build_cf'
            name='build' if script=='build' else 'build:cf'
            if not proof.get(script) or package.get('scripts',{}).get(name)!=proof[script]:
                raise ValueError('再生成手順が残っていないため保持')
            reconstruction='保持したプロジェクトで npm ci → npm run '+name
            retained={}
        elif original.name=='node_modules' and target.get('kind')=='identical_dependency_packages':
            anchor=self.s.physical(Path(target.get('retained','')))
            if anchor.name!='node_modules' or not anchor.is_relative_to(self.s.home/'Desktop/development') or anchor.is_relative_to(self.root):
                raise ValueError('保持する依存環境の所在を確認できません')
            if self.hash_file(anchor.parent/'package-lock.json')!=proof['lock_sha256']:
                raise ValueError('保持側のlockfileが変化しました')
            a,_=self.inventory(stored,contents=True,packages=True)
            b,_=self.inventory(anchor,contents=True,packages=True)
            if a!=b or a!=target.get('packages_inventory'):raise ValueError('保持側の依存パッケージと一致しません')
            metadata=target.get('retained_metadata',[])
            expected={p.name for p in stored.iterdir() if p.name in ('.cache','.mf')}
            if {Path(x['original']).name for x in metadata}!=expected:raise ValueError('固有メタデータの保持記録が不足しています')
            for item in metadata:
                name=Path(item['original']).name
                dest=self.s.physical(Path(item['retained']))
                if not dest.is_relative_to(folder/'retained-dependency-metadata'):raise ValueError('保持メタデータの所在が不正です')
                if self.inventory(stored/name,True)[0]!=item['content_inventory'] or self.inventory(dest,True)[0]!=item['content_inventory']:
                    raise ValueError('固有メタデータの保持内容が一致しません')
            retained={'anchor':str(anchor),'packages':a}
            reconstruction='保持した同一依存環境あり。npm ciと監査記録の固有メタデータから再構築可能'
        else:raise ValueError('対応する再生成・同一コピーの証明がないため保持')
        self.idle(stored)
        if care.identity(stored)!=initial_identity:raise ValueError('検証中に隔離物が変化しました')
        return {'kind':'quarantine','tree':{'bytes':allocated,'inventory':inventory},'identity':initial_identity,
                'record':row,'audit':str(folder),'source':proof,'retained':retained,'reconstruction':reconstruction}

    def mark(self,row,status,**values):
        data=self.catalog();data['entries'][row['uuid']]={**data['entries'].get(row['uuid'],{}),
            'qid':row['qid'],'original':row['original'],'path':row['path'],'status':status,'at':time.time(),**values}
        self.save_catalog(data)

    def drop(self,row):
        path=self.s.physical(self.root/'manifest.tsv')
        lines=path.read_text().splitlines(keepends=True)
        matching=[x for x in lines if x.split('\t')[0]==row['qid']]
        if len(matching)!=1:raise ValueError('隔離台帳が変化しました')
        counter=self.s.physical(self.root/'last-id')
        maximum=max(int(x.split('\t')[0][1:]) for x in lines if x.strip())
        if counter.exists():maximum=max(maximum,int(counter.read_text()))
        counter.write_text(str(maximum)+'\n')
        tmp=self.root/('.manifest-'+uuid.uuid4().hex)
        with tmp.open('x') as f:f.writelines(x for x in lines if x not in matching)
        os.replace(tmp,path)

    def hold(self,key):
        row=self.entry(key);self.paths(row)
        self.mark(row,'held',review_after=time.time()+30*86400)
        return {'status':'held'}

    def restore(self,key):
        row=self.entry(key);original,stored=self.paths(row)
        if original.exists() or original.is_symlink():raise ValueError('元の場所が存在するため上書きしません')
        # Existing physical parent only; do not recreate missing project trees.
        if not original.parent.is_dir():raise ValueError('復元先の親フォルダを確認してください')
        expected=care.identity(stored)
        self.idle(stored)
        self.mark(row,'restoring')
        # renameatx_np RENAME_EXCL prevents replacing a concurrently created path.
        import ctypes
        libc=ctypes.CDLL(None,use_errno=True)
        source=self.open_directory(self.root)
        try:
            dest=self.open_directory(original.parent)
            try:
                st=os.stat(stored.name,dir_fd=source,follow_symlinks=False)
                if [st.st_dev,st.st_ino,st.st_mode,st.st_size,st.st_mtime_ns,st.st_ctime_ns]!=expected:
                    raise ValueError('復元対象が変化しました')
                result=libc.renameatx_np(source,os.fsencode(stored.name),dest,os.fsencode(original.name),4)
                if result:raise OSError(ctypes.get_errno(),'復元先が変化、または復元に失敗しました')
            finally:os.close(dest)
        finally:os.close(source)
        self.mark(row,'restored');self.drop(row)
        return {'status':'restored'}

    @staticmethod
    def open_directory(path):
        fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
        try:
            for part in path.parts[1:]:
                child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                os.close(fd);fd=child
            return fd
        except Exception:
            os.close(fd);raise
