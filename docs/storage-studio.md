# Storage Studio

## Start

Run `devpurge studio` (or `./bin/devpurge studio` from this checkout). A local
browser UI opens. Keep that process running; Ctrl+C stops it. Python 3.9+ and
macOS are required. No npm install, cloud account, telemetry or background job.
`--no-open` prints the local URL; `--port 8766` selects a port.
For a Finder/Spotlight launcher, run `python3 scripts/install-studio-app.py` from
the permanent installed checkout. It creates `~/Applications/devpurge Studio.app`
without replacing an existing application or registering a background job. The
interface remains a browser UI; this is not a native SwiftUI application. Opening
the launcher again reuses the existing Studio instance. The launcher depends on
that checkout and the Python executable used during installation.
`devpurge diagnose` writes the same diagnostic JSON to stdout and saves the local
baseline/history. It never deletes user files. It does write diagnostic state;
the existing `devpurge -n` / archive dry-run semantics are unchanged.

## The five workflows

1. **Overview:** actual volume free space, non-overlapping targeted inventory,
   incomplete measurements, growth since the last scan. A separate large-location
   inventory includes project roots, application data and Downloads. These views
   overlap and must not be added together.
2. **Explore:** category/search/growth filters, impact explanations, Finder reveal,
   bounded folder drill-down. Unknown does not mean zero. Review-only items cannot
   be passed to the cleanup API by changing a checkbox or forging an ID.
3. **Finish production:** explicitly name retained final/source files and
   disposable intermediate directories. SHA-256 fingerprints of retained files
   are verified both when planning and applying. The user declares that required
   editing inputs are kept: the tool cannot prove that an MP4 preserves a Premiere
   project, voice stems, source assets or all future editing capability.
4. **Refresh:** RSS process list, swap usage, user temporary area, snapshot names,
   actual free-space timeline. Official `uv cache prune` is available through a
   separate explicit review. It is permanent, not Trash/restore; reclaimed bytes
   are unknown before execution. No force, no `--ci`, no network, no reboot,
   process termination, swap unlinking or snapshot thinning.
5. **Restore:** journaled same-volume Trash moves, with refusal to overwrite a
   recreated source. Moving to Trash does not free disk space. Emptying Trash is
   deliberately left to Finder and removes the ability to restore.

## Safety boundaries

- Loopback IPv4 only, ephemeral token, strict Host and Origin validation, no CORS,
  CSP, no file serving outside the three UI assets. Requests without the token
  cannot read filesystem metadata. The URL capability is moved into sessionStorage.
- One CLI/UI instance per state directory. An in-process lock serializes scans,
  plans, completion records, application and restoration.
- Cleanup allowlist is deliberately narrower than the legacy CLI: pip downloads,
  npm content cache and Homebrew downloads only. uv uses its official tool.
- Per-path configuration exclusions, archive opt-in root, protected names,
  `.env*`, `.git`, `.devpurge-keep`, links and special files are retained.
- Plans expire after five minutes and are single-use. Metadata identity is checked
  again before moving. Newest nested modification must be at least 24 hours old;
  lsof must positively complete with no open files and no warnings; known active
  package managers cause refusal. These checks reduce risk but cannot atomically
  prevent another application from opening a file immediately afterward. Close
  related applications before cleanup.
- Plans never infer production completion from file age or a `final` suffix.
  Intermediate cleanup requires an explicit completion record, a known intermediate
  directory name under Desktop/development, and retained-file verification.
- A write-ahead receipt is fsynced before every rename and updated after it.
  Partial failures remain visible and already-moved entries remain recoverable.
- No filesystem content is read by scanning; retained-file hashing is an explicit
  action. Secret-name/path guards apply before hashing.

State is private to the local account under
`~/Library/Application Support/devpurge/studio/`: latest measurement, 90 history
points, completion declarations, movement receipts and refresh receipts. These
contain local file paths and must not be committed or uploaded. Scan errors and
partial coverage are shown; scanners have time/item/depth budgets. APFS clones,
hardlinks, snapshots and concurrent writes prevent exact recovery predictions.

## Legacy CLI policy correction

The following identifiers now have structural `review` protection: A04 (uv cache),
A08 (Codeium data), A10 (Kiro data), A11 (Codex runtimes), A12 (Gemini history),
A13 (Claude plugins), D11 (Simulator device data), D14 (Xcode release archives),
D18–D20 (browser offline/IndexedDB data). Existing cleanup rejects review entries.
uv's documentation explicitly disallows direct cache modification; use its CLI.
No launchd schedule or existing archive-retention configuration changes.

## Design decision — 2026-10-23

Reference: [CleanMyMac Space Lens results](https://macpaw.com/support/cleanmymac/knowledgebase/space-lens-results),
including the live linked application screenshot, visually inspected before UI work.
Adopt: persistent navigation, capacity visual paired with an actionable list,
review before removal. Change: explain by development/production role, add growth,
completion evidence and restoration, use readable proportional rectangles instead
of spatial bubble navigation. Omit: blanket optimization scores and guaranteed
recovery promises. Forest green, warm paper and restrained lime distinguish action,
context and capacity. The user has not yet accepted the design.

Technical references:
- [uv cache safety and pruning](https://docs.astral.sh/uv/concepts/cache/)
- [Apple storage guidance](https://support.apple.com/en-gb/102624)

## Verify

```
python3 test/test_studio.py
bash test/run_tests.sh
python3 test/test_archive.py
python3 test/test_triage_report.py
node --check ui/app.js
```

Studio tests use temporary fake homes and mock external tools for mutation tests.
They verify actual fixture movement/restoration, collision protection, stale plans,
file changes, secret/protected names, symlinks, incomplete measurement, retained-file
hashes, lsof failure, uv command construction, and Host/Origin/token guards.
Real-user scan and browser QA are separate from these tests. No real cleanup is
performed as a test.
