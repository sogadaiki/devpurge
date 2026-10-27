"""Read-only directory listing in a disposable, deadline-limited child.

The child has no mutation/AI capability. A timeout only stops that child;
unreadable locations must remain held by the caller.
"""
import json
import os
from pathlib import Path
import subprocess
import sys


def listing(path,limit=15000,timeout=4,dirs_only=False):
    try:
        result=subprocess.run([sys.executable,'-I','-B',__file__,str(path),str(limit),str(int(dirs_only))],
                              capture_output=True,text=True,timeout=timeout)
    except subprocess.TimeoutExpired as e:
        raise OSError('フォルダの読み取りが時間内に完了しないため保持') from e
    if result.returncode:
        raise OSError('フォルダを読み取れないため保持（権限・接続状態を確認してください）')
    data=json.loads(result.stdout)
    return [Path(path)/name for name in data['names']],data['limited']


def main():
    path=Path(sys.argv[1]);limit=int(sys.argv[2]);dirs_only=bool(int(sys.argv[3]))
    if not path.is_absolute() or path.is_symlink() or path!=path.resolve() or not 0<limit<=15000:
        raise ValueError('Invalid listing request')
    names=[];limited=False
    with os.scandir(path) as iterator:
        for index,entry in enumerate(iterator):
            if index>=limit:limited=True;break
            if not entry.is_symlink() and (not dirs_only or entry.is_dir(follow_symlinks=False)):
                names.append(entry.name)
    print(json.dumps({'names':sorted(names),'limited':limited}))


if __name__=='__main__':
    try:main()
    except FileNotFoundError:print(json.dumps({'names':[],'limited':False}))
