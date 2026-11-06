# System Data investigation and recovery (Studio 0.20 / CLI 0.8.1)

macOS System Data is a storage category, not a directory of disposable files.
Directory totals can identify contributors but cannot reproduce Apple's category
calculation. Report allocated target bytes and observed free-space change
separately. Moving files into quarantine does not reclaim disk capacity.

## Newly visible locations

- Known Electron apps: direct disk caches and `Partitions/<partition>/Cache`,
  `Code Cache`, `GPUCache` and Dawn variants. Both Studio's ordinary scan and
  its cleanup assistant discover these locations. Unknown app layouts, links,
  cookies, sessions, IndexedDB, Service Worker and offline storage are excluded.
- Studio checks owner processes and ordinary cache activity/age before cleanup.
  CLI nested partition entries are always **review**, including unattended runs.
- Installer and updater stores under Application Support are visible as review
  locations. Names or extensions never establish that they are disposable.

## Quarantine evidence

- A missing stored path contributes zero candidate bytes; an unreadable path is
  unknown. Preserve the manifest and historical `recorded_bytes`: absence does
  not prove who removed the data or that devpurge reclaimed it. The UI labels
  these states and disables unavailable restoration. Present manifest sizes
  remain explicitly historical until content verification measures the target.
- `verified_duplicate_tree` records contain the complete content inventory and
  a `retained_files` mapping for every relative filename. Every kept file is
  freshly hashed outside quarantine/Trash; extra, changed, missing, protected
  or linked data fails closed. Parent permission probes are shared only within
  a single verification; hashes and identities are never reused across actions.
- Older cleanup receipts stored under `logs/` are not executable instructions
  or deletion authority. Reconcile exact manifest IDs, original and stored
  paths, then save a normalized audit under `audits/` after current content and
  keeper verification. Preserve the original receipt pointer. Unmatched files
  remain held; descriptive regeneration claims do not suffice.
- `quarantine_git.py` provides **read-only review evidence** for registered
  worktrees: audit binding, retained repository/branch, clean status, current
  patch equivalence, verified recovery bundle and full tracked blob comparison.
  Protected names, unique ignored files, omitted change detection, orphaned Git
  metadata and missing bundles stay held. The only ignored exception is Python
  bytecode with a tracked source. The generic delete path always refuses Git
  worktrees, even after successful review. Dedicated Git removal needs separate
  current-use checks and authority; never use recursive file deletion for them.

## Validation

Fixtures exercise partition discovery without private stores, active-app holds,
review-only CLI classification, missing/unreadable quarantine, duplicate trees
with changed keepers or added files, and Git cases including protected data,
assume-unchanged files, unique ignored files and altered bundles. Native packaging
includes the new verifier. UI checks cover truthful presence and disabled restore.

Real cleanup receipts, exact local paths and retained-file hashes belong in the
machine's local audit/handoff, not this repository. Histories, models, original
assets, releases, legal/client records and live application data remain protected.
