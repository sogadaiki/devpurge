# Storage Studio

## Start

Run `devpurge studio` (or `./bin/devpurge studio` from this checkout). A local
browser UI opens. Keep that process running; Ctrl+C stops it. Python 3.9+ and
macOS are required. No npm install, cloud account, telemetry or background job.
`--no-open` prints the local URL; `--port 8766` selects a port.
For the native Mac application, run `python3 scripts/install-studio-app.py`.
It builds `~/Applications/devpurge Studio.app` with an AppKit window, Dock icon,
standard keyboard shortcuts and a Help menu. Open it directly from Finder or
Spotlight. The UI uses macOS WebKit; an external browser or terminal is unnecessary.
The app bundles the UI and diagnostic source, so it works independently of this
checkout. It uses the existing Python executable selected during installation;
if that interpreter is moved or removed, reinstall the app. Building requires
Xcode/Command Line Tools and macOS12+; using the built app does not require Xcode.
No npm dependencies, bundled Chromium or Python environment are installed.

The installer compiles and verifies an ad-hoc signature before replacing an
existing devpurge bundle. Other apps, symlink destinations and a running native
app are refused. A failed installation rename restores the prior app. Temporary
compiler outputs and the superseded bundle are removed after successful installation.
This is a local personal build, not a notarized distribution for other Macs.
`--output /absolute/path/Studio.app` selects a separate build destination.

Opening again activates the existing window. Closing the last window or Cmd+Q
ends its engine after accepted operations finish, without sending termination
signals. Existing CLI engines are reused and left running when the app exits.
An authenticated local handshake rejects stale URLs and redirects; native
navigation stays on the exact local origin. WebKit uses an ephemeral data store.
No launchd job or automatic login item is installed. Diagnostic records and
receipts remain in Application Support across app restarts and updates.
`devpurge diagnose` writes the same diagnostic JSON to stdout and saves the local
baseline/history. It never deletes user files. It does write diagnostic state;
the existing `devpurge -n` / archive dry-run semantics are unchanged.

## The five workflows

### 毎日の使い方

- 普段は「今日のお手入れ」でスキャンし、一つだけ確認。残す判断でも完了です。
- 急に容量が減ったら「リフレッシュ」で測定。作業を保存して関連アプリを終了し、再測定します。スワップの即時解放や再起動と同じ回復量は保証しません。
- 制作が終わったら「制作を完了する」。完成品と再編集に必要な素材を先に残し、中間物を確認します。
- 取り消したいときは「整理と復元の履歴」。ゴミ箱への移動だけでは空き容量は増えません。

このガイドはアプリの「ヘルプ」メニューからも読めます。

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
4. **Refresh:** a quick check independent of the folder scan measures free space,
   used/reserved swap, VM volume allocation, RAM, boot time, physical memory
   footprint and deleted files still held open by processes. Native users can
   inspect an app, confirm saved work and request its normal exit. Before/after
   checks detect reboot and compare actual free space and swap allocation.
   Official `uv cache prune` is available through a
   separate explicit review. It is permanent, not Trash/restore; reclaimed bytes
   are unknown before execution. No force, no `--ci`, no network, no reboot,
   forced termination, swap unlinking or snapshot thinning.
5. **Restore:** journaled same-volume Trash moves, with refusal to overwrite a
   recreated source. Moving to Trash does not free disk space. Emptying Trash is
   deliberately left to Finder and removes the ability to restore.

## Safety boundaries

- Loopback IPv4 only, ephemeral token, strict Host and Origin validation, no CORS,
  CSP, no file serving outside explicitly allowlisted UI assets. Requests without the token
  cannot read filesystem metadata. The URL capability is moved into sessionStorage.
- One CLI/UI instance per state directory. An in-process lock serializes scans,
  plans, completion records, application and restoration.
- Cleanup allowlist is deliberately narrower than the legacy CLI: pip downloads,
  npm content cache and Homebrew downloads only. uv uses its official tool.
- Per-path configuration exclusions, archive opt-in root, protected names,
  `.env*`, `.git`, `.devpurge-keep`, links and special files are retained.
  Only official uv pruning permits internal cache links and `bin/python*` links
  to uv-managed or Python.org macOS framework executables, without traversing the target. Other external
  links and protected targets still block the plan.
  Trash and intermediate cleanup continue to reject every link.
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
- [Apple normal application termination](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate())

## Safe refresh — 2026-10-23

Native v0.10.0 adds **ひとつずつ、休ませる**. A native-only, main-frame,
exact-origin WebKit bridge lists ordinary GUI applications. It accepts opaque
five-minute tickets, never a caller-supplied PID/path/command. PID, launch date,
bundle ID and bundle URL are checked again after the native confirmation and
immediately before the quit request. Finder, Studio, Codex/ChatGPT, Claude,
terminals and known development editors are protected. Background processes and
CLI jobs are not termination targets. Protection is checked by native code,
not just by hiding a button.

The user must confirm that work is saved and jobs/exports/uploads have ended.
Normal quit affects every window of that app; some apps do not ask to save.
`NSRunningApplication.terminate()` only sends a normal request. Its Boolean is
not treated as proof of exit: Studio observes `isTerminated`, waits up to15s,
then leaves pending/refused apps intact. **終了したか確認する** observes only;
it never repeats termination or escalates to force. If Studio restarts, an old
pending record remains unverified. No bulk close or automatic restart is offered.

A measurement and private write-ahead receipt must succeed before requesting
exit. A completed receipt requires observed exit and a second measurement.
`native-refresh-history.json` keeps60 receipts with before/after free bytes,
swap and VM allocation. No savings are promised; concurrent activity can make
the net change negative. A cancelled save dialog is not success. The source and
manual acceptance instructions for a disposable GUI fixture are in
`test/RefreshFixture.swift`; it retains an original and saves a note while holding
a128MiB unlinked file. It is never included in the installed app.

The optional **見守り** switch samples about every5min while the page remains
open (other views may be used). Busy scans/actions are skipped; sleep or WebKit
timer throttling can delay samples. It defaults off and stops on window close or
reload. It installs no launchd job. `pressure-history.json` retains up to2,048
samples, including five memory leaders, so a later check across reboot can
compare measured values. Calling the `pressure` API alone does not start a timer.
Two bounded `du` probes also record the user's OS temporary directory and
`/private/tmp` (five seconds each). Partial access stays unknown; these working
folders are never deletion targets. Other users' temporary data is not covered.

VM allocation (`df` on the VM volume), swap used/reserved (`sysctl`) and logical
open-deleted file lengths overlap and are never added as reclaimable capacity.
Physical footprint is obtained through Darwin `proc_pid_rusage` metadata; unknown
permissions remain unknown. Descendants are grouped under GUI apps for a reference
memory total; reparented helpers may be missing. Memory is not disk savings.
No memory contents, process arguments, user-file contents or privileged data are
read by these probes. A previous reboot's200GB recovery cannot be reconstructed
from current sizes or cumulative write counts alone.

## Daily care experience — 2026-10-23

The opening screen is a small daily ritual: scan, decide on one item, then receive
one stamp. Keeping an item is a valid decision. Deletion volume never earns points,
missed days never erase history, and scans alone do not award completion. Successful
cleanup stamps require a matching receipt from today. Records remain local in
`daily.json`; repeat completion is idempotent.

Reference: [Forest](https://www.forestapp.cc/), visually inspected for the warm
plant-centered atmosphere, generous space and welcoming primary action. Adopt the
calm daily ritual; omit countdown pressure and streak penalties. The original
mint cleaning companion in `ui/assets/companion.png` was generated for this project
with imagegen on 2026-10-23, then copied without visual modification. It is not a
Forest asset. The user requested enjoyable, game-like interaction; acceptance of
this implementation remains open.

Controls have pressed-state motion, the companion responds to touch, real scan
progress animates the scene, and completion has a short sparkle celebration.
Optional synthesized sound defaults off. Reduced-motion preferences disable
animation. Browser QA verified scan-to-decision on the real read-only scan and
completion/reload persistence in an isolated disposable fixture home; no real
user data was deleted and no real daily completion was recorded by QA.

## Verify

```
python3 test/test_studio.py
python3 test/test_native.py
bash test/run_tests.sh
python3 test/test_archive.py
python3 test/test_triage_report.py
node --check ui/app.js
node --check ui/daily.js
node --check ui/refresh.js
```

Studio tests use temporary fake homes and mock external tools for mutation tests.
They verify actual fixture movement/restoration, collision protection, stale plans,
file changes, secret/protected names, symlinks, incomplete measurement, retained-file
hashes, lsof failure, uv command construction, and Host/Origin/token guards.
Real-user scan and browser QA are separate from these tests. No real cleanup is
performed as a test.
Native lifecycle tests use isolated fake homes: authenticated handshake, reuse of
an existing engine, shutdown on pipe EOF, refusal of new operations during close,
and completion of an already accepted operation before exit. Installer tests
verify failed-build preservation, identity/running/link guards and rollback.

Native APIs: [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)
and [AppKit window-close lifecycle](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminateafterlastwindowclosed(_:)).

## Quick refresh diagnosis — 2026-10-23

`POST /api/pressure` performs a bounded, read-only process/volume check and saves
`pressure.json` plus up to120 compact samples in `pressure-history.json`.
No background job or automatic termination is installed. The display follows the
existing accepted daily-care direction: a calm tactile check button, three clear
measurements, and save/quit/recheck instructions with a comparison after checking.

`lsof -nP +L1 -F pcftsiDk` requests metadata only: no filenames, arguments or file
contents. Device+inode deduplication prevents counting repeated descriptors.
Shared files appear under each owner, so per-process rows are non-additive.
Sizes are logical and limited to the ordinary account's visibility, not guaranteed
APFS reclamation. Warnings, incomplete fields and timeouts produce partial/unknown
instead of a misleading zero. A zero result never proves the whole Mac is clear.

No measurements can attribute a historical reboot recovery before the first
sample. Swap is OS-managed; this feature never removes VM files or invokes purge.
Official references: [Apple Activity Monitor memory](https://support.apple.com/en-euro/guide/activity-monitor/actmntr1004/mac)
and [lsof documentation](https://lsof.readthedocs.io/en/latest/manpage/).
uv cache links (including build-environment references to retained managed/framework Python)
are supported while retaining stale-plan,24-hour recency, process
activity and exclusion guards. Running package managers may legitimately block
refresh. Never use force to work around this. Centralized environments inside the
cache may be recreated; working project environments and models are not targets.
