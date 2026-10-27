#!/usr/bin/env python3
"""Prepare or explicitly install the user-level 10-minute render care job."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys

LABEL = 'com.sadame.devpurge-render-care'
ROOT = Path(__file__).resolve().parents[1]


def definition(root=ROOT):
    # No shell, login shell, remote webhook, force termination or elevated user.
    state = Path.home() / 'Library/Application Support/devpurge/render-care'
    return {'Label': LABEL, 'ProgramArguments': [str(Path(sys.executable).resolve()), str(root / 'lib/render_care.py'), 'watch'],
            'StartInterval': 600, 'RunAtLoad': True, 'ProcessType': 'Background',
            'EnvironmentVariables': {'PATH': '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
            'StandardOutPath': str(state / 'service.log'), 'StandardErrorPath': str(state / 'service-error.log')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true', help='Explicitly register and start the prepared job')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.geteuid() == 0:
        parser.error('Use your normal macOS account')
    root = args.root.absolute()
    if root != root.resolve() or not (root / 'lib/render_care.py').is_file():
        parser.error('Expected an installed physical devpurge checkout')
    if '/.codex/worktrees/' in str(root) or '/.worktrees/' in str(root):
        parser.error('Use the durable primary checkout, never a temporary worktree')
    state = Path.home() / 'Library/Application Support/devpurge/render-care'
    state.mkdir(parents=True, mode=0o700, exist_ok=True)
    prepared = state / (LABEL + '.plist')
    if state != state.resolve() or prepared.is_symlink():
        parser.error('Symlink state refused')
    prepared.write_bytes(plistlib.dumps(definition(root)))
    print('Prepared:', prepared)
    if args.install:
        target = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
        if target.exists() or target.is_symlink():
            parser.error('Existing job preserved; inspect before replacing')
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.parent != target.parent.resolve():
            parser.error('LaunchAgents symlink refused')
        target.write_bytes(prepared.read_bytes())
        domain = 'gui/' + str(os.getuid())
        p = subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(target)], capture_output=True, text=True)
        if p.returncode:
            target.unlink()  # exact file just created by this operation
            parser.exit(1, p.stderr)
        subprocess.run(['/bin/launchctl', 'print', domain + '/' + LABEL], check=True)
        print('Installed:', target)


if __name__ == '__main__':
    main()
