"""Opt-in lifecycle for completed Godot/iOS build copies; originals never expire."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time
import zipfile
import studio
import quarantine_store
import render_care as care

NAME=re.compile(r'ios-testflight-build(\d+)[A-Za-z0-9-]*')
CACHES=('ModuleCache.noindex','SDKStatCaches.noindex','SDKExplicitPrecompiledModules','CompilationCache.noindex')


class BuildCare:
    def __init__(self,home=None):
        self.s=studio.Studio(home);self.q=quarantine_store.Quarantine(self.s)
        self.state=self.s.home/'Library/Application Support/devpurge/build-care'

    def config(self):
        return self.q.read_json(self.state/'policy.json',{'version':1,'enabled':False,'roots':[],'pins':[],'anchor':None})

    def configure(self,roots,pins,anchor,enabled=False):
        # Configuration is a deliberate operation, never inferred by a scan.
        if not roots or len(roots)>16:raise ValueError('Register 1–16 exact build roots')
        for root in roots:
            root=self.s.physical(Path(root))
            if any(c in str(root) for c in ('|','\n','\r')):raise ValueError('Unsupported path characters')
            if root.name!='build' or not root.is_relative_to(self.s.home/'Desktop/development') or not root.is_dir():raise ValueError('Invalid build root')
        anchor=self.s.physical(Path(anchor))
        if anchor.name!='RentalLegend.xcframework' or not any(anchor.is_relative_to(Path(r)) for r in roots):raise ValueError('Anchor must remain in registered roots')
        self.q.content_map(anchor)
        if any(int(n)<1 for n in pins):raise ValueError('Invalid pinned build')
        policy={'version':1,'enabled':bool(enabled),'roots':list(map(str,roots)),'pins':sorted(set(map(int,pins))),'anchor':str(anchor)}
        self.s.physical(self.state);care.save(self.state/'policy.json',policy)
        return policy

    def builds(self,config):
        if config.get('version')!=1:raise ValueError('Unsupported policy version')
        roots=config['roots'];found=[]
        if len(roots)>16:raise ValueError('Build root limit')
        for root in roots:
            root=self.s.physical(Path(root))
            if root.name!='build' or not root.is_relative_to(self.s.home/'Desktop/development'):raise ValueError('Invalid build root')
            for p in self.s.directory(root,500,dirs_only=True):
                m=NAME.fullmatch(p.name)
                if m and not p.is_symlink() and not self.s.blocked(p):found.append((p,int(m[1])))
        return sorted(set(found))

    def originals(self,build):
        ipa=build/'export/RentalLegend.ipa';archive=build/'RentalLegend.xcarchive'
        record=self.q.read_json(build/'ipa-validation.json',{})
        digest=self.q.hash_file(ipa)
        if record.get('ipa_sha256')!=digest or record.get('distribution_signature_valid') is not True:
            raise ValueError('Completed distribution validation is missing or changed')
        if str(record.get('build'))!=NAME.fullmatch(build.name)[1]:raise ValueError('Build number mismatch')
        archived,_=self.q.content_map(archive)
        if not archived:raise ValueError('Retained signed archive is empty')
        return {'ipa':str(ipa),'ipa_sha256':digest,'archive_digest':self.digest(archived),
                'validation_sha256':self.q.hash_file(build/'ipa-validation.json')}

    @staticmethod
    def digest(value):
        import hashlib
        return hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()

    @staticmethod
    def equal(a,b):
        return {k:(v['bytes'],v['sha256']) for k,v in a.items()}=={k:(v['bytes'],v['sha256']) for k,v in b.items()}

    def idle(self,build,target):
        # These are isolated completed outputs, not shared package caches.
        # Inspect the owning build, including cwd, rather than blocking on an
        # unrelated long-lived uv process elsewhere on the machine.
        observed=care.activity([str(build)])
        if care.open_under(build,observed) or any(str(build) in x for x in observed.get('arguments',[])):
            raise ValueError('Build is in use')

    def proof(self,build,target,config,originals=None):
        started=time.monotonic()
        self.s.physical(target);self.s.physical(build)
        if str(build.parent) not in config['roots'] or not NAME.fullmatch(build.name):raise ValueError('Unregistered build')
        if any((p/'.devpurge-keep').exists() or (p/'.devpurge-keep').is_symlink() for p in [build,build.parent]):raise ValueError('Explicit keep marker')
        tracked=care.run(['git','-C',str(build),'ls-files','--',str(target)])
        ignored=care.run(['git','-C',str(build),'check-ignore','-q','--',str(target)])
        if tracked.returncode or tracked.stdout.strip() or tracked.stderr.strip() or ignored.returncode or ignored.stderr.strip():
            raise ValueError('Git-tracked or unverified build output is retained')
        originals=originals or self.originals(build)
        before=care.identity(target);contents,allocated=self.q.content_map(target)
        if not contents:raise ValueError('Empty target')
        if target==build/'ipa-verified' or target==build/'RentalLegend.pck':
            with zipfile.ZipFile(originals['ipa']) as z:
                members={x.filename:x for x in z.infolist() if not x.is_dir()}
                if len(members)>250000:raise ValueError('IPA entry limit')
                if target.is_file():
                    matching=[n for n,x in members.items() if n.endswith('.pck') and x.file_size==contents['.']['bytes']]
                    if len(matching)!=1:raise ValueError('No unique PCK member')
                    pairs={'.':matching[0]}
                else:pairs={name:name for name in contents}
                for name,member in pairs.items():
                    if member not in members or members[member].file_size!=contents[name]['bytes']:raise ValueError('Unknown or changed extraction file')
                    if members[member].file_size>8*2**30:raise ValueError('IPA member size limit')
                    import hashlib
                    h=hashlib.sha256()
                    with z.open(member) as f:
                        for chunk in iter(lambda:f.read(1048576),b''):
                            h.update(chunk)
                            if time.monotonic()-started>120:raise ValueError('Copy verification time limit')
                    if h.hexdigest()!=contents[name]['sha256']:raise ValueError('IPA content mismatch')
            retained={'kind':'ipa-copy','path':originals['ipa']}
        elif target==build/'RentalLegend.xcframework':
            anchor=self.s.physical(Path(config['anchor']))
            if anchor.is_relative_to(target):raise ValueError('Cannot remove the retained framework')
            kept,_=self.q.content_map(anchor)
            if not self.equal(contents,kept):raise ValueError('Framework differs from retained copy')
            retained={'kind':'framework-copy','path':str(anchor),'digest':self.digest(kept)}
        elif target==build/'source-final/godot-r1/.godot/imported' or target in [build/'derived'/n for n in CACHES]:
            source=build/'source-final/godot-r1';project=source/'project.godot'
            record=self.q.read_json(build/'source.json',{})
            source_hash=self.q.hash_file(build/'tracked-source.tar')
            if source_hash!=record.get('archive_sha256') or record.get('tracked_source_only') is not True:raise ValueError('Source archive proof missing')
            # Keep all source and plugin inputs; never delete dependency checkouts.
            if not (source/'assets').is_dir():raise ValueError('Source assets missing')
            project_hash=self.q.hash_file(project)
            xcode=build/'RentalLegend.xcodeproj/project.pbxproj'
            retained={'kind':'generated-cache','source_sha256':source_hash,'project_sha256':project_hash,
                      'xcode_sha256':self.q.hash_file(xcode)}
            patterns={
                'ModuleCache.noindex':r'(?:Session\.modulevalidation|modules\.timestamp|[A-Z0-9]+/[A-Za-z0-9_]+-[A-Z0-9]+\.(?:pcm|swiftmodule))',
                'SDKStatCaches.noindex':r'[^/]+\.sdkstatcache',
                'SDKExplicitPrecompiledModules':r'[A-Za-z0-9_]+-[A-Z0-9]+\.(?:pcm|swiftmodule)',
                'CompilationCache.noindex':r'generic/(?:lock|v1\.\d+/(?:index|data|actions)\.v\d+(?:\.shared)?)'}
            if target.name in patterns and any(not re.fullmatch(patterns[target.name],name) for name in contents):
                raise ValueError('Unknown compile-cache content is retained')
            if target.name=='imported':
                allowed=set();imports={}
                for d,dirs,files in os.walk(source,followlinks=False):
                    dirs[:]=[n for n in dirs if n not in ('.godot','.git') and not (Path(d)/n).is_symlink()]
                    for name in files:
                        if not name.endswith('.import'):continue
                        meta=self.s.physical(Path(d)/name)
                        if meta.stat().st_size>65536:raise ValueError('Import metadata limit')
                        if len(imports)>25000:raise ValueError('Import file limit')
                        raw=meta.read_text();imports[str(meta)]=self.q.hash_file(meta)
                        original=self.s.physical(meta.with_suffix(''))
                        imports[str(original)]=self.q.hash_file(original)
                        for dest in re.findall(r'res://\.godot/imported/([^"\s]+)',raw):
                            if '/' in dest or '..' in dest:raise ValueError('Import path outside cache')
                            allowed.add(dest)
                            stem=re.match(r'^(.+-[a-f0-9]{32})(?:\..*)?$',dest)
                            if stem:allowed.add(stem[1]+'.md5')
                if not set(contents)<=allowed:raise ValueError('Unmapped imported data is retained')
                retained['imports_digest']=self.digest(imports)
        else:raise ValueError('Unsupported target grammar')
        self.q.references(build.parent,target)
        self.idle(build,target)
        if care.identity(target)!=before:raise ValueError('Target changed during verification')
        return {'identity':before,'contents_digest':self.digest(contents),'bytes':allocated,'originals':originals,'retained':retained}

    def scan(self,config=None):
        config=config or self.config();builds=self.builds(config)
        newest=set(sorted({n for _,n in builds},reverse=True)[:2]);protected=newest|set(config.get('pins',[]))
        anchor=Path(config['anchor']) if config.get('anchor') else None
        result={'at':time.time(),'enabled':bool(config.get('enabled')),'protected_builds':sorted(protected),'rows':[]}
        for build,n in builds:
            if n in protected or (anchor and anchor.is_relative_to(build)) or any((p/'.devpurge-keep').exists() or (p/'.devpurge-keep').is_symlink() for p in [build,build.parent]):
                result['rows'].append({'build':str(build),'status':'kept','reason':'Newest two, pinned release or retained framework'});continue
            candidates=[build/'ipa-verified',build/'RentalLegend.pck',build/'RentalLegend.xcframework',build/'source-final/godot-r1/.godot/imported']+[build/'derived'/x for x in CACHES]
            present=[x for x in candidates if x.exists() or x.is_symlink()]
            if not present:continue
            try:originals=self.originals(build)
            except (ValueError,OSError,RuntimeError,subprocess.SubprocessError) as e:
                result['rows'].append({'build':str(build),'status':'kept','reason':str(e)});continue
            for p in present:
                row={'path':str(p),'build':str(build),'status':'kept'}
                try:
                    row['proof']=self.proof(build,p,config,originals);row.update(status='verified',bytes=row['proof']['bytes'])
                except (ValueError,OSError,RuntimeError,zipfile.BadZipFile,subprocess.SubprocessError) as e:row['reason']=str(e)
                result['rows'].append(row)
        return result

    def run(self):
        config=self.config()
        if config.get('enabled') is not True:return {'status':'disabled','removed_bytes':0}
        if sys.version_info<(3,11) or not shutil.rmtree.avoids_symlink_attacks:raise ValueError('Safe build cleanup requires Python3.11+ with descriptor-based deletion')
        with self.q.locked():
            report=self.scan(config);receipt={'at':time.time(),'status':'running','before_free':shutil.disk_usage(self.s.home).free,'items':[],'removed_bytes':0,
                'held':[x for x in report['rows'] if x['status']!='verified']}
            path=self.state/'receipts'/('run-'+str(time.time_ns())+'.json');care.save(path,receipt)
            for row in report['rows']:
                if row['status']!='verified':continue
                entry={'path':row['path'],'status':'kept'};receipt['items'].append(entry)
                try:
                    # Re-evaluate newest/pinned builds immediately before each mutation.
                    if self.config()!=config:raise ValueError('Policy changed')
                    current=self.builds(config);newest=set(sorted({n for _,n in current},reverse=True)[:2])|set(config['pins'])
                    build=Path(row['build']);target=Path(row['path'])
                    if int(NAME.fullmatch(build.name)[1]) in newest:raise ValueError('Build now protected')
                    if self.proof(build,target,config)!=row['proof']:raise ValueError('Evidence changed')
                    fd=self.q.open_directory(target.parent)
                    try:
                        st=os.stat(target.name,dir_fd=fd,follow_symlinks=False)
                        if [st.st_dev,st.st_ino,st.st_mode,st.st_size,st.st_mtime_ns,st.st_ctime_ns]!=row['proof']['identity']:raise ValueError('Target replaced')
                        entry['status']='deleting';care.save(path,receipt)
                        if stat.S_ISREG(st.st_mode):os.unlink(target.name,dir_fd=fd)
                        else:shutil.rmtree(target.name,dir_fd=fd)
                    finally:os.close(fd)
                    entry.update(status='removed',bytes=row['proof']['bytes']);receipt['removed_bytes']+=entry['bytes']
                except (ValueError,OSError,RuntimeError,zipfile.BadZipFile,subprocess.SubprocessError) as e:entry.update(status='kept-or-partial',reason=str(e))
                care.save(path,receipt)
            receipt.update(status='completed' if all(x['status']=='removed' for x in receipt['items']) else 'partial',after_free=shutil.disk_usage(self.s.home).free)
            care.save(path,receipt);return receipt


def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='action',required=True)
    scan=sub.add_parser('scan');scan.add_argument('--rows',action='store_true',help='Read-only review rows for the standard CLI scan')
    run=sub.add_parser('run')
    for command in (scan,run):command.add_argument('--exclude',action='append',type=Path,default=[])
    configure=sub.add_parser('configure');configure.add_argument('--root',action='append',type=Path,required=True)
    configure.add_argument('--pin',action='append',type=int,default=[]);configure.add_argument('--anchor',type=Path,required=True)
    configure.add_argument('--auto',action='store_true',help='Explicitly authorize permanent cleanup under this exact policy')
    args=parser.parse_args()
    if os.geteuid()==0:parser.error('Run as the owning user, never sudo')
    engine=BuildCare()
    engine.s.excluded.extend(p.expanduser().absolute() for p in getattr(args,'exclude',[]))
    try:
        if args.action=='configure':result=engine.configure(args.root,args.pin,args.anchor,args.auto)
        elif args.action=='scan':result=engine.scan()
        else:result=engine.run()
        if args.action=='scan' and args.rows:
            for index,row in enumerate(result['rows']):
                p=row.get('path',row['build'])
                if any(c in p for c in ('|','\n','\r')):continue
                size=row.get('bytes',0)
                desc='Build copy: '+Path(row['build']).name+' / '+Path(p).name
                if row['status']!='verified':desc+=' (held)'
                print('BC%04d|%s|review|%s|%.1fM|%d|'%(index,p,desc,size/1048576,size))
        else:print(json.dumps(result,ensure_ascii=False,indent=2))
    except (ValueError,OSError,RuntimeError,zipfile.BadZipFile,subprocess.SubprocessError) as e:
        if args.action=='scan' and args.rows:
            print('BCERR|%s|review|Build copy scan incomplete (held)|unknown|0|'%engine.state)
        parser.exit(1,str(e)+'\n')


if __name__=='__main__':main()
