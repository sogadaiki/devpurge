#!/usr/bin/env python3
"""Build/install the native Mac app without launchd, npm or a bundled browser."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'local.devpurge.studio'


def validate_destination(app):
    if app.suffix != '.app' or app != app.resolve():
        raise ValueError('Use a physical .app path, not a symlink.')
    if not app.exists():
        return
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != 'studio':
        raise ValueError('Destination is not a devpurge Studio app; nothing replaced.')
    binary = app / 'Contents/MacOS/studio'
    result = subprocess.run(['/bin/ps', '-axo', 'comm='], capture_output=True, text=True, check=True)
    if str(binary) in result.stdout.splitlines():
        raise ValueError('Quit devpurge Studio before installing this update.')


def build(app, root, python):
    contents = app / 'Contents'
    macos, resources = contents / 'MacOS', contents / 'Resources'
    macos.mkdir(parents=True)
    engine = resources / 'engine'
    (engine / 'lib').mkdir(parents=True)
    shutil.copy2(root / 'lib/studio.py', engine / 'lib/studio.py')
    shutil.copytree(root / 'ui', engine / 'ui')
    info = {'CFBundleName': 'devpurge Studio', 'CFBundleDisplayName': 'devpurge Studio',
            'CFBundleIdentifier': BUNDLE_ID, 'CFBundleVersion': '3',
            'CFBundleShortVersionString': '0.10.0', 'CFBundleExecutable': 'studio',
            'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '12.0',
            'CFBundleIconFile': 'engine/ui/assets/companion.png',
            'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
            'StudioPython': str(python),
            'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    architecture = os.uname().machine
    if architecture not in ('arm64', 'x86_64'):
        raise ValueError('Unsupported Mac architecture: ' + architecture)
    subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', '-swift-version', '5',
                    '-target', architecture + '-apple-macosx12.0',
                    '-module-cache-path', str(app.parent / 'module-cache'),
                    '-framework', 'Cocoa', '-framework', 'WebKit',
                    '-o', str(macos / 'studio'), *map(str, sorted((root / 'native').glob('*.swift')))],
                   check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)


def install(app, root=ROOT, python=None):
    python = Path(python or sys.executable).resolve()
    app = Path(app).absolute()
    if sys.version_info < (3, 9):
        raise ValueError('Python 3.9 or newer is required.')
    app.parent.mkdir(parents=True, exist_ok=True)
    validate_destination(app)
    # Build completely before replacing. Retain the former app until the new
    # rename succeeds, then remove only our redundant staging copy.
    with tempfile.TemporaryDirectory(prefix='.devpurge-install-', dir=app.parent) as staging:
        stage = Path(staging)
        built = stage / 'devpurge Studio.app'
        build(built, root, python)
        validate_destination(app)
        previous = stage / 'previous.app'
        if app.exists():
            app.rename(previous)
        try:
            built.rename(app)
        except OSError:
            if previous.exists():
                previous.rename(app)
            raise
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path.home() / 'Applications/devpurge Studio.app',
                        help='Build and install to this .app path (default: ~/Applications/devpurge Studio.app)')
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.geteuid() == 0:
        parser.error('Run on macOS as your ordinary user, without sudo.')
    try:
        app = install(args.output)
    except (OSError, ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        parser.exit(1, str(error) + '\n')
    print(str(app))
    print('Installed: open this app in Finder. No browser, terminal or checkout is needed to use it.')
    print('Engine: existing Python at ' + str(Path(sys.executable).resolve()))


if __name__ == '__main__':
    main()
