#!/usr/bin/env python3
"""A local, read-only inventory of project outputs missed by the usual scan."""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess

from build_care import BuildCare
from studio import Studio, atomic_json


def physical_directory(studio, path):
    try:
        return stat.S_ISDIR(studio.physical(path).stat().st_mode)
    except (FileNotFoundError, NotADirectoryError, RuntimeError, ValueError):
        return False
    except OSError as error:
        studio.read_errors[str(path)] = str(error)
        return False


def children(studio, root):
    if not physical_directory(studio, root):
        return []
    try:
        return [p for p in studio.directory(root, limit=1000, dirs_only=True)
                if not p.name.startswith('.git') and physical_directory(studio, p)]
    except OSError:
        return []


def render_lock_state(folder):
    """Observe the wrapper lock without creating a lock file or waiting."""
    try:
        fd = os.open(folder.parent / '.render-bundle.lock', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return 'unknown'
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            return 'unlocked'
        finally:
            os.close(fd)
    except BlockingIOError:
        return 'in-use'
    except OSError:
        return 'unknown'


def local_candidates(studio):
    development = studio.home / 'Desktop/development'
    checkouts = set(children(studio, development))
    checkouts.discard(development / '.worktrees')
    for root in (development / '.worktrees', studio.home / '.codex/worktrees',
                 studio.home / '.worktrees'):
        for lane in children(studio, root):
            if lane.name.startswith('state-before-'):
                yield lane, 'rollback-folder', 'Check the retained deployment and QA record.'
                continue
            checkouts.add(lane)
            # A task container may hold multiple repositories and rollback folders.
            if not (lane / '.git').exists():
                for child in children(studio, lane):
                    if child.name.startswith('state-before-'):
                        yield child, 'rollback-folder', 'Check the retained deployment and QA record.'
                    else:
                        checkouts.add(child)

    for checkout in sorted(checkouts):
        talkhead = checkout / 'talkhead'
        for folder in (checkout / '.render-tmp', talkhead / '.render-tmp'):
            if physical_directory(studio, folder):
                yield folder, 'render-workspace', 'Check the render lock and the job before cleanup.'
        for case in children(studio, talkhead / 'work'):
            composite = case / 'composite'
            if physical_directory(studio, composite):
                yield composite, 'video-intermediates', 'Check the adopted output and the inputs for rebuilding it.'
        for trailer in children(studio, checkout / 'media'):
            generated = trailer / 'generated'
            if trailer.name.startswith('trailer-') and physical_directory(studio, generated):
                yield generated, 'trailer-intermediates', 'Check retained source archives and the adopted trailer.'


def game_review(studio, scan):
    if scan is not None:
        rows = [row for row in scan['items']
                if row.get('tier') == 'review' and row.get('id', '').startswith('BC')]
        return {
            'status': 'incomplete' if any(row['id'] == 'BCERR' for row in rows) else 'weekly-scan',
            'rows': rows,
        }

    try:
        result = BuildCare(studio.home).scan()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        return {'status': 'incomplete', 'reason': str(error), 'rows': []}
    result['status'] = 'measured'
    result['rows'] = [{key: value for key, value in row.items() if key != 'proof'}
                      for row in result['rows']]
    return result


def review(studio, scan=None):
    items = []
    for path, kind, reason in local_candidates(studio):
        row = studio.measure((path, kind, path.name, reason, 'review'))
        if row is None:
            continue
        if kind == 'render-workspace':
            row['render_lock'] = render_lock_state(path)
        items.append(row)
    return {
        'at': datetime.now(timezone.utc).isoformat(),
        'items': sorted(items, key=lambda row: (row['bytes'] is None, -(row['bytes'] or 0), row['path'])),
        'game_builds': game_review(studio, scan),
        'discovery_limited': bool(getattr(studio, 'discovery_limited', False) or studio.read_errors),
        'unreadable_directories': sorted(studio.read_errors),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scan-json', type=Path, help='Reuse game build rows from devpurge --json')
    parser.add_argument('--output', type=Path, help='Write the private report to a local file')
    args = parser.parse_args()
    studio = Studio()
    scan = json.loads(args.scan_json.read_text()) if args.scan_json is not None else None
    result = review(studio, scan)
    if args.output is None:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        path = args.output.absolute()
        studio.physical(path.parent)
        atomic_json(path, result)


if __name__ == '__main__':
    main()
