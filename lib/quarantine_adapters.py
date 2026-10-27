"""Normalize audited records; adapters never turn descriptive text into authority."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import render_care as care


def receipts(q,folder):
    result=[]
    for name in ('movement-receipt.json','receipts.json','receipt.json'):
        value=q.read_json(folder/name,[])
        if name=='receipt.json' and isinstance(value,dict):value=[value]
        if isinstance(value,list):result.extend(x for x in value if isinstance(x,dict))
    return result


def targets(plan,row):
    original=Path(row['original'])
    found=[x for x in plan.get('targets',[]) if isinstance(x,dict) and x.get('path')==str(original)]
    for i,x in enumerate(found):
        if 'kind' not in x and isinstance(x.get('contents'),dict):
            found[i]={**x,'adapter':'legacy-media'}
    # The alias-copy format has no targets array. Every proof must belong to
    # this exact directory; receipt ID/path binding is still mandatory.
    proofs=plan.get('proofs')
    if not found and isinstance(proofs,list) and proofs and all(isinstance(x,dict) and isinstance(x.get('copy'),str) and Path(x['copy']).parent==original for x in proofs):
        found=[{'path':str(original),'adapter':'alias-copies','proofs':proofs}]
    return found


def retained_file(q,path,expected):
    path=q.s.physical(Path(path))
    if not path.is_relative_to(q.s.home) or path.is_relative_to(q.root) or path.is_relative_to(q.s.home/'.Trash'):
        raise ValueError('保持元が原本の保存範囲外のため保持')
    if not isinstance(expected,dict) or not re.fullmatch(r'[a-f0-9]{64}',str(expected.get('sha256',''))):
        raise ValueError('保持元のハッシュ記録が不足しています')
    q.s.directory(path.parent,1)
    if q.hash_file(path)!=expected['sha256']:raise ValueError('保持元が記録時から変化したため保持')
    return {'path':str(path),'sha256':expected['sha256'],'identity':care.identity(path)}


def audio_fingerprint(q,path):
    """Read local WAV/MOV only, copy exact PCM packets; no decode/rounding loss."""
    q.s.physical(path)
    before=care.identity(path)
    binaries=[]
    for name in ('ffprobe','ffmpeg'):
        binary=shutil.which(name) or next((str(p/name) for p in (Path('/opt/homebrew/bin'),Path('/usr/local/bin')) if (p/name).is_file()),None)
        if not binary:raise ValueError('音声照合用のffmpeg/ffprobeがないため保持')
        binaries.append(binary)
    flags=['-v','error','-protocol_whitelist','file,pipe','-format_whitelist','wav,mov']
    probe=subprocess.run([binaries[0],*flags,'-show_streams','-of','json',str(path)],capture_output=True,text=True,timeout=30,check=True)
    streams=json.loads(probe.stdout)['streams'];audio=[x for x in streams if x.get('codec_type')=='audio']
    if len(audio)!=1 or audio[0].get('codec_name')!='pcm_s24le':raise ValueError('対応する無圧縮PCM音声ではないため保持')
    stream=audio[0]
    result=subprocess.run([binaries[1],'-nostdin',*flags,'-i',str(path),'-map','0:a:0','-c:a','copy','-f','hash','-hash','sha256','-'],capture_output=True,text=True,timeout=90,check=True)
    digest=result.stdout.strip()
    if result.stderr.strip() or not re.fullmatch(r'SHA256=[a-f0-9]{64}',digest) or care.identity(path)!=before:
        raise ValueError('音声照合が不完全、または検証中に変更されたため保持')
    return {'sha256':digest,'codec':stream['codec_name'],'rate':stream.get('sample_rate'),'channels':stream.get('channels'),'streams':len(streams)}


def verify(q,row,original,stored,folder,target,identity):
    plan=q.read_json(folder/'execution-plan.json')
    retained={}
    if target['adapter']=='alias-copies':
        current,allocated=q.content_map(stored)
        proofs=target['proofs'];names=[Path(x['copy']).name for x in proofs]
        if len(set(names))!=len(names) or set(current)!=set(names):raise ValueError('重複素材の記録にない内容があるため保持')
        for item in proofs:
            name=Path(item['copy']).name;record=current[name]
            if record['bytes']!=item.get('bytes') or record['sha256']!=item.get('sha256') or record['mode']!=item.get('mode'):
                raise ValueError('隔離した重複素材が記録時と異なるため保持')
            anchor=Path(item.get('retained',''))
            if not anchor.is_relative_to(original.parent) or anchor.is_relative_to(original):raise ValueError('重複素材の保持先が不正です')
            kept=retained_file(q,anchor,item)
            alias=original/name
            if not alias.is_symlink() or alias.resolve()!=anchor:raise ValueError('元の素材参照が保持元へ切り替わっていないため保持')
            retained[name]={**kept,'alias':os.readlink(alias),'alias_identity':care.identity(alias)}
        reconstruction='元の素材参照は保持した同一内容の原本を使用。隔離コピーだけを削除'
    else:
        expected=target.get('contents',{})
        if not expected or any(not isinstance(v,dict) or set(v)!={'size','sha256'} for v in expected.values()):
            raise ValueError('中間物の内容記録形式が未対応のため保持')
        # These two movies are not identical to the retained final. Their
        # scripts live in another checkout without the recorded relative input.
        # Do not infer reproducibility from a filename or an audit description.
        if original.name in ('video_30fps.mp4','render_before_audio_sync.mp4'):
            raise ValueError('完成ファイル全体の一致と元動画からの再生成を検証できないため保持')
        if not (original.name=='audio_processed.wav' and original.parent.name=='work' and stored.is_file()) and not (original.parts[-2:]==('node_modules','.cache') and stored.is_dir()):
            raise ValueError('隔離記録の再生成・保持元の検証形式に未対応のため保持')
        current,allocated=q.content_map(stored)
        if {k:{'size':v['bytes'],'sha256':v['sha256']} for k,v in current.items()}!=expected:
            raise ValueError('隔離時のファイル内容と一致しないため保持')
        if original.name=='audio_processed.wav' and original.parent.name=='work' and stored.is_file():
            evidence=q.read_json(folder/'media-stream-proof.json',{}).get('streams',{})
            source=evidence.get('intermediate_audio',{});anchor_record=evidence.get('retained_premiere_audio',{})
            anchor=Path(anchor_record.get('path',''))
            if source.get('path')!=str(original) or not anchor.is_relative_to(original.parent.parent) or anchor==original:
                raise ValueError('音声の保持元との対応が不明なため保持')
            retained['audio']=retained_file(q,anchor,plan.get('retained',{}).get(str(anchor)))
            a=audio_fingerprint(q,stored);b=audio_fingerprint(q,anchor)
            if a['streams']!=1 or any(a[k]!=b[k] for k in ('sha256','codec','rate','channels')):
                raise ValueError('保持元とPCM音声が完全一致しないため保持')
            if a['sha256']!=source.get('hash') or b['sha256']!=anchor_record.get('hash'):
                raise ValueError('隔離時の音声照合記録と一致しないため保持')
            retained['pcm']={k:v for k,v in a.items() if k!='streams'}
            reconstruction='保持したPremiere用MOVから同一のPCM音声を無劣化で取り出せます：'+str(anchor)
        elif original.parts[-2:]==('node_modules','.cache') and stored.is_dir():
            if any(not re.fullmatch(r'webpack/remotion-production-[0-9.]+/[a-f0-9]+/(?:index|[0-9]+)\.pack(?:\.old)?',key) for key in current):
                raise ValueError('webpack pack以外の固有データがあるため保持')
            recorded=plan.get('retained',{})
            pairs=[Path(p).parent for p in recorded if Path(p).name=='package.json' and str(Path(p).parent/'package-lock.json') in recorded]
            if len(pairs)!=1:raise ValueError('保持したビルド設定とlockfileを特定できないため保持')
            project=pairs[0]
            for name in ('package.json','package-lock.json'):
                retained[name]=retained_file(q,project/name,recorded[str(project/name)])
            package=q.read_json(project/'package.json',{})
            deps={**package.get('dependencies',{}),**package.get('devDependencies',{})}
            version=deps.get('remotion',deps.get('@remotion/cli'))
            if not version or any(key.split('/')[1]!='remotion-production-'+version for key in current):raise ValueError('Remotionの生成環境とキャッシュの版が一致しないため保持')
            entry=project/'src/index.ts'
            retained['entry']={'path':str(entry),'sha256':q.hash_file(entry),'identity':care.identity(entry)}
            reconstruction='保持したRemotionプロジェクトの次回ビルドでwebpackキャッシュを再生成：'+str(project)
        else:raise ValueError('対応する同一内容・キャッシュの証明がないため保持')
    q.idle(stored)
    if care.identity(stored)!=identity:raise ValueError('検証中に隔離物が変化しました')
    return {'kind':'quarantine','tree':{'bytes':allocated,'contents_digest':hashlib.sha256(json.dumps(current,sort_keys=True).encode()).hexdigest()},
            'identity':identity,'record':row,'audit':str(folder),'retained':retained,'reconstruction':reconstruction}
