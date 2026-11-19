#!/usr/bin/env python3
"""Build the standalone menu bar application using the installed macOS SDK."""
import argparse
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def bundle_workspace_backend(repo, contents):
    # Studio provides the same protection rules and ~/.devpurgerc policy as the CLI.
    # Its Python dependencies are needed at import time, even for a read-only scan.
    modules = (
        "workspaces", "workspace_branch", "workspace_compare", "workspace_folders",
        "workspace_git", "workspace_retire", "studio", "bounded_fs", "cleanup_assistant",
        "expanded_scope", "job_recovery", "quarantine_adapters", "quarantine_git",
        "quarantine_store", "render_care",
    )
    library = contents / "Resources/devpurge/lib"
    library.mkdir(parents=True)
    for name in modules:
        filename = name + ".py"
        shutil.copyfile(repo / "lib" / filename, library / filename)
    # Use the Finder-launched app's interpreter and only its packaged modules.
    subprocess.run([
        "/usr/bin/python3", "-I", "-B", "-S", "-c",
        "import sys; sys.path.insert(0, sys.argv[1]); "
        "import workspaces, workspace_branch, workspace_compare, workspace_retire",
        str(library.resolve()),
    ], cwd=contents, check=True)


def install(destination):
    source = Path(__file__).resolve().parent
    identifier = "jp.devpurge.headroom"
    destination.mkdir(parents=True, exist_ok=True)
    installed = destination / "余白.app"
    if installed.is_symlink():
        raise SystemExit(f"リンク先を上書きできません: {installed}")
    if installed.exists():
        with (installed / "Contents/Info.plist").open("rb") as handle:
            if plistlib.load(handle).get("CFBundleIdentifier") != identifier:
                raise SystemExit(f"同じ名前の別アプリがあります: {installed}")
    with tempfile.TemporaryDirectory(prefix=".headroom-build-", dir=destination) as temp:
        stage = Path(temp) / installed.name
        contents = stage / "Contents"
        executable = contents / "MacOS/Headroom"
        executable.parent.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump({
                "CFBundleDevelopmentRegion": "ja",
                "CFBundleIdentifier": identifier,
                "CFBundleName": "余白",
                "CFBundleDisplayName": "余白",
                "CFBundleExecutable": "Headroom",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.2",
                "CFBundleVersion": "2",
                "NSDesktopFolderUsageDescription": "登録した開発案件の作業コピー、Gitブランチ、保管フォルダを確認するために使います。",
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
                "NSHighResolutionCapable": True,
            }, handle)
        bundle_workspace_backend(source.parent, contents)
        subprocess.run(["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-O",
                        "-target", f"{platform.machine()}-apple-macos13.0",
                        *sorted(source.glob("*.swift")), "-o", executable], check=True)
        subprocess.run(["/usr/bin/codesign", "--sign", "-", "--force", stage], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", stage], check=True)
        backup = Path(temp) / "previous.app"
        if installed.exists():
            installed.rename(backup)
        try:
            stage.rename(installed)
        except OSError:
            if backup.exists():
                backup.rename(installed)
            raise
    return installed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications")
    print(os.fspath(install(parser.parse_args().destination)))
