"""Bounded discovery and evidence for additional regenerable storage classes."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import time
from collections import deque
import render_care as care

XCODE_PROCESSES = ('xcode', 'swift-frontend', 'clang', 'dsymutil', 'lldb', 'debugserver', 'devicectl', 'ios-deploy')
CACHES = {
    'Library/Caches/Google/Chrome': ('Chromeの表示キャッシュ', ('google chrome','chrome_crashpad')),
    'Library/Caches/Adobe/CCX Welcome': ('Adobeの紹介・学習コンテンツキャッシュ', ('adobe','ccxprocess')),
    'Library/Caches/node-gyp': ('Nodeビルド用ヘッダーのキャッシュ', ('node','npm','node-gyp')),
    'Library/Caches/next-swc': ('Nextコンパイラーのダウンロードキャッシュ', ('node','npm')),
    'Library/Caches/Yarn': ('Yarnのパッケージキャッシュ', ('node','yarn')),
    '.cache/go-build': ('Goのビルドキャッシュ', ('go','compile')),
    '.cargo/registry/cache': ('Cargoのダウンロード済みパッケージ', ('cargo','rustc')),
    'Library/Caches/com.microsoft.VSCode.ShipIt': ('VS Codeの更新用キャッシュ', ('code','shipit')),
    'Library/Caches/notion.id.ShipIt': ('Notionの更新用キャッシュ', ('notion','shipit')),
    'Library/Caches/notion-updater': ('Notionの更新ダウンロード', ('notion','shipit')),
}


def roots(home):
    return (home/'Desktop/development', home/'.codex/worktrees')


def in_projects(p, home):
    return any(p.is_relative_to(root) for root in roots(home))


def fixed_specs(studio):
    h=studio.home
    result=[(h/path,'cache',title,'再取得できます。関連アプリの実行中は保持します。','expanded') for path,(title,_) in CACHES.items()]
    devices=h/'Library/Developer/Xcode/iOS DeviceSupport'
    try:
        for p in studio.directory(devices,100):
            if p.is_dir() and not p.is_symlink():
                result.append((p,'cache','iOSデバッグ用シンボル / '+p.name,'OSシンボルのキャッシュ。次の実機接続・デバッグ時に再取得が必要です。','expanded'))
    except OSError:
        pass
    # Broader visibility does not grant deletion authority.
    for relative,category in (('Library/Caches','cache'),('Library/Developer/Xcode','other'),('Library/Application Support/devpurge/quarantine','other')):
        base=h/relative
        try:
            for p in studio.directory(base,200):
                if not p.is_symlink() and not studio.blocked(p):
                    result.append((p,category,p.name,'保管場所を調査。用途・再生成元を確認できないものは保持。','review'))
        except OSError:
            pass
    return result


def discover(studio):
    """Include hidden worktree containers without reading session/config stores."""
    q=deque((p,0) for p in roots(studio.home)); seen=set(); result=[]
    start=time.monotonic(); count=0; limited=False
    while q:
        if count>=20000 or time.monotonic()-start>120:
            limited=True;break
        root,depth=q.popleft()
        if root in seen or studio.blocked(root) or root.is_symlink():continue
        seen.add(root)
        try:
            entries=studio.directory(root,dirs_only=True)
        except OSError:
            continue
        for p in sorted(entries):
            count+=1
            if studio.blocked(p) or p.is_symlink():continue
            if p.name in ('.next','.open-next'):
                result.append((p,'build',p.parent.name+' / '+p.name,'再生成元と使用状況を確認するビルド生成物。','expanded'))
            elif p.name=='.godot':
                shader=p/'shader_cache'
                if shader.is_dir():result.append((shader,'build',p.parent.parent.name+' / Godot shader cache','GPUシェーダーを再コンパイルできます。プロジェクトと編集状態は保持。','expanded'))
                imported=p/'imported'
                if imported.is_dir():result.append((imported,'build',p.parent.name+' / Godot imported','インポート元を確認できるまで保持。','review'))
            elif p.name=='ModuleCache.noindex' or (p.name=='Intermediates.noindex' and p.parent.name=='Build'):
                result.append((p,'build',p.parent.parent.name+' / '+p.name,'Xcodeのコンパイル中間物。元のワークスペースが残る場合のみ候補化。','expanded'))
            elif p.name=='.claude':
                q.append((p/'worktrees',0))
            elif p.name in ('.worktrees','worktrees') and (p.name=='.worktrees' or root==studio.home/'.codex'):
                q.append((p,0))
            elif not p.name.startswith('.') and p.name not in ('node_modules','vendor','assets','art','images','screenshots','references','__pycache__','target','dist') and depth<9:
                q.append((p,depth+1))
            elif depth>=9:
                limited=True
    studio.expanded_limited=limited
    return result


def process_guard(tokens):
    p=care.run(['/bin/ps','-axo','comm=']);p.check_returncode()
    if p.stderr.strip():raise ValueError('プロセス一覧が不完全なため保持')
    names=[Path(x.strip()).name.lower() for x in p.stdout.splitlines()]
    exact={'go','compile','node','npm','yarn','cargo','rustc','code'}
    if any((name==token if token in exact else token in name) for name in names for token in tokens):
        raise ValueError('関連アプリ・ビルド・デバッグ処理が実行中のため保持')


def manifest(studio, path):
    p=studio.physical(path)
    if not p.is_file() or p.stat().st_size>1048576:raise ValueError('再生成元の設定を確認できないため保持')
    data=p.read_bytes()
    return data,{'path':str(p),'sha256':hashlib.sha256(data).hexdigest()}


def evidence(studio, p):
    """Return evidence only for exact supported path grammars, never row labels."""
    h=studio.home
    for relative,(_,tokens) in CACHES.items():
        if p==h/relative:
            process_guard(tokens)
            return {'kind':'app-cache','manifest':None}
    device_root=h/'Library/Developer/Xcode/iOS DeviceSupport'
    if p.parent==device_root:
        if not re.fullmatch(r'i(?:Phone|Pad|Pod)\d+,\d+ \d+(?:\.\d+)* \([A-Za-z0-9]+\)',p.name):
            raise ValueError('不明な端末シンボル形式のため保持')
        if not (p/'Symbols').is_dir() and not (p/'arm64e/Symbols').is_dir():
            raise ValueError('OSシンボルの構造を確認できないため保持')
        allowed={'Symbols','arm64e','.copying_lock','.finalized','Info.plist','.DS_Store'}
        if any(x.name not in allowed and not x.name.startswith('.processed_dyld_shared_cache') for x in p.iterdir()):
            raise ValueError('シンボル以外のファイルがあるため保持')
        process_guard(XCODE_PROCESSES)
        return {'kind':'device-symbol-cache','manifest':None}
    if not in_projects(p,h):raise ValueError('対応範囲外のため保持')
    if p.name=='shader_cache' and p.parent.name=='.godot':
        project=p.parent.parent
        _,proof=manifest(studio,project/'project.godot')
        process_guard(('godot',))
        observed=care.activity([str(project)])
        if care.open_under(project,observed):raise ValueError('Godotプロジェクトを使用中のため保持')
        result=care.run(['git','-C',str(project),'check-ignore','-q','--','.godot/shader_cache'])
        tracked=care.run(['git','-C',str(project),'ls-files','--','.godot/shader_cache'])
        if result.returncode or tracked.returncode or tracked.stdout.strip() or result.stderr or tracked.stderr:
            raise ValueError('Git管理対象または除外未確認のため保持')
        return {'kind':'godot-shader-cache','manifest':proof}
    derived=p.parent if p.name=='ModuleCache.noindex' else p.parent.parent if p.name=='Intermediates.noindex' and p.parent.name=='Build' else None
    if derived:
        raw,proof=manifest(studio,derived/'info.plist')
        try:
            info=plistlib.loads(raw)
        except (plistlib.InvalidFileException, ValueError, TypeError):
            raise ValueError('Xcodeの設定を読み取れないため保持')
        if not isinstance(info,dict) or not isinstance(info.get('WorkspacePath'),str):
            raise ValueError('Xcodeの再生成元が不明なため保持')
        workspace=studio.physical(Path(info.get('WorkspacePath','')))
        if not workspace.exists() or workspace.suffix not in ('.xcodeproj','.xcworkspace') or not in_projects(workspace,h):
            raise ValueError('保持するXcodeワークスペースを確認できないため保持')
        ignored=care.run(['git','-C',str(p.parent),'check-ignore','-q','--',str(p)])
        tracked=care.run(['git','-C',str(p.parent),'ls-files','--',str(p)])
        if ignored.returncode or tracked.returncode or tracked.stdout.strip() or ignored.stderr or tracked.stderr:
            raise ValueError('Git管理対象または除外未確認のため保持')
        process_guard(XCODE_PROCESSES)
        observed=care.activity([str(workspace.parent)])
        if care.open_under(workspace.parent,observed):raise ValueError('Xcodeプロジェクトを使用中のため保持')
        return {'kind':'xcode-build-cache','manifest':proof,'workspace_identity':care.identity(workspace)}
    raise ValueError('原本・履歴・環境・用途不明のデータは保持')
