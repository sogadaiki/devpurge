#!/usr/bin/env python3
"""Install a small user-local macOS launcher; no privileges or launchd changes."""
import os
from pathlib import Path
import plistlib
import shlex
import sys

root = Path(__file__).resolve().parents[1]
app = Path.home() / 'Applications/devpurge Studio.app'
if app.exists():
    raise SystemExit('Launcher already exists; retain it and inspect before replacing: ' + str(app))
contents = app / 'Contents'
macos = contents / 'MacOS'
macos.mkdir(parents=True)
info = {'CFBundleName':'devpurge Studio', 'CFBundleDisplayName':'devpurge Studio',
        'CFBundleIdentifier':'local.devpurge.studio', 'CFBundleVersion':'1',
        'CFBundleShortVersionString':'0.8.0', 'CFBundleExecutable':'studio',
        'CFBundlePackageType':'APPL', 'LSUIElement':True}
with (contents/'Info.plist').open('wb') as f:
    plistlib.dump(info,f)
launcher = macos/'studio'
launcher.write_text('#!/bin/sh\nexport PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"\nexec '+shlex.quote(sys.executable)+' '+shlex.quote(str(root/'lib/studio.py'))+' studio >/dev/null 2>&1\n')
os.chmod(launcher,0o755)
print(app)
