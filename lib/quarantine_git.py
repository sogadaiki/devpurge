"""Read-only evidence for quarantined worktrees. Never authorizes rmtree."""
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import time


def git(path, *args):
    result=subprocess.run(['git','--no-replace-objects','-c','core.fsmonitor=false','-C',str(path),*args],
        env={**os.environ,'GIT_OPTIONAL_LOCKS':'0'},capture_output=True,timeout=60)
    if result.returncode:raise ValueError('Gitの所在・復元データを検証できないため保持')
    return result.stdout


def inspect(q,row):
    """Verify the retained branch/bundle and actual checkout, not just clean status.

    Even a verified result remains review-only: usage/reference checks, explicit
    disposal approval and git worktree remove (without force) are separate.
    """
    started=time.monotonic()
    original,stored=q.paths(row)
    if not (stored/'.git').is_file() or (stored/'.git').is_symlink():
        raise ValueError('登録されたGit作業コピーの形式ではないため保持')
    folder,target=q.binding(row)
    common=Path(os.fsdecode(git(stored,'rev-parse','--path-format=absolute','--git-common-dir')).strip())
    q.s.physical(common.parent)
    if common!=common.resolve() or not common.is_dir() or common.name!='.git' or not common.is_relative_to(q.s.home/'Desktop/development') or common.is_relative_to(q.root):
        raise ValueError('保持するGit本体の所在が不明なため保持')
    repo=common.parent
    records=git(repo,'worktree','list','--porcelain','-z').split(b'\0\0')
    matching=[r.split(b'\0') for r in records if r.startswith(b'worktree '+os.fsencode(stored)+b'\0')]
    if len(matching)!=1 or any(x.startswith((b'locked',b'prunable')) for x in matching[0]):
        raise ValueError('Git登録が不一致・ロック中のため保持')
    head=os.fsdecode(git(stored,'rev-parse','HEAD')).strip()
    branch=os.fsdecode(git(stored,'symbolic-ref','HEAD')).strip()
    state=target.get('state',target)
    if head!=state.get('head') or branch!=state.get('branch'):
        raise ValueError('隔離時からGitのHEAD・ブランチが変化したため保持')
    if os.fsdecode(git(repo,'rev-parse',branch)).strip()!=head:
        raise ValueError('復元用のローカルブランチが一致しないため保持')
    if git(stored,'status','--porcelain=v1','--untracked-files=all','--ignore-submodules=none').strip():
        raise ValueError('未コミット・未追跡のデータがあるため保持')
    patches=git(repo,'cherry','origin/main',head).decode().splitlines()
    if any(not x.startswith('- ') for x in patches):
        raise ValueError('現在の本体に未反映の変更があるため保持')
    bundle=target.get('bundle',target.get('recovery_bundle',{}))
    if not bundle.get('path'):raise ValueError('復元用bundleの記録がないため保持')
    bp=q.s.physical(Path(bundle.get('path','')))
    if not bp.is_relative_to(folder) or q.hash_file(bp)!=bundle.get('sha256'):
        raise ValueError('復元用bundleの内容が一致しないため保持')
    git(repo,'bundle','verify',str(bp))
    if head+' '+branch not in git(repo,'bundle','list-heads',str(bp)).decode().splitlines():
        raise ValueError('復元用bundleに対象ブランチがないため保持')
    flags=git(stored,'ls-files','-v','-z').split(b'\0')
    if any(x and x[:1]!=b'H' for x in flags):
        raise ValueError('Gitの変更検知を省略したファイルがあるため保持')
    entries=[x for x in git(stored,'ls-files','--stage','-z').split(b'\0') if x]
    if len(entries)>100000:raise ValueError('Git内容照合の上限のため保持')
    # Reject protected names before opening any checkout contents.
    for entry in entries:
        p=stored/os.fsdecode(entry.split(b'\t',1)[1])
        if q.s.blocked(p) or p.name.lower() in ('credentials','id_rsa','id_ed25519') or p.suffix.lower() in ('.key','.pem','.p12','.pfx'):
            raise ValueError('保護・機密ファイルを含むため保持')
    names=set();digest=hashlib.sha256();allocated=0;seen=set()
    for entry in entries:
        if time.monotonic()-started>120:raise ValueError('Git内容照合の時間上限のため保持')
        meta,raw=entry.split(b'\t',1);mode,blob,stage=meta.split()
        rel=Path(os.fsdecode(raw))
        if rel.is_absolute() or '..' in rel.parts or stage!=b'0' or mode not in (b'100644',b'100755',b'120000'):
            raise ValueError('未対応のGit項目があるため保持')
        p=stored/rel;names.add(str(rel))
        q.s.physical(p.parent)
        st=p.lstat()
        if mode==b'120000':
            if not stat.S_ISLNK(st.st_mode):raise ValueError('Gitリンクの形式が変化したため保持')
            data=os.fsencode(os.readlink(p));h=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data)
        else:
            fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
            with os.fdopen(fd,'rb') as f:
                before=os.fstat(f.fileno())
                if not stat.S_ISREG(before.st_mode):raise ValueError('Git通常ファイルではないため保持')
                h=hashlib.sha1(b'blob '+str(before.st_size).encode()+b'\0')
                for chunk in iter(lambda:f.read(1048576),b''):
                    h.update(chunk)
                    if time.monotonic()-started>120:raise ValueError('Git内容照合の時間上限のため保持')
                after=os.fstat(f.fileno())
                if (before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):
                    raise ValueError('照合中にファイルが変化したため保持')
        if h.hexdigest().encode()!=blob:raise ValueError('Gitの保存内容と実ファイルが一致しないため保持')
        digest.update(entry+b'\0')
        if (st.st_dev,st.st_ino) not in seen:allocated+=st.st_blocks*512;seen.add((st.st_dev,st.st_ino))
    ignored=[os.fsdecode(x) for x in git(stored,'ls-files','--others','--ignored','--exclude-standard','-z').split(b'\0') if x]
    for name in ignored:
        p=stored/name
        match=re.fullmatch(r'(.+)\.cpython-\d+(?:\.opt-\d+)?\.pyc',p.name)
        source=p.parent.parent/(match[1]+'.py') if match else None
        if p.parent.name!='__pycache__' or not source or str(source.relative_to(stored)) not in names or p.is_symlink() or not p.is_file():
            raise ValueError('Git管理外の固有データがあるため保持')
        q.s.physical(p);allocated+=p.stat().st_blocks*512
    return {'status':'verified-review-only','repo':str(repo),'path':str(stored),'original':str(original),
        'head':head,'branch':branch,'bundle':str(bp),'bundle_sha256':bundle['sha256'],
        'tracked_files':len(entries),'tracked_digest':digest.hexdigest(),'ignored_regenerable':ignored,
        'bytes':allocated,'patches':patches,
        'reason':'本体への反映・全追跡ファイル・復元bundleを照合済み。利用確認と本人承認後にGit専用操作で回収。通常の完全削除には含めません。'}
