# Render storage care

`devpurge render-care` reclaims verified redundant Remotion temporary data,
measures actual free-space change, and records growth. Studio's **レンダリングの
片付け** uses the same engine. It permanently deletes verified copies rather
than moving them to Trash. Original files and differing versions remain.

## Configure and use

```sh
devpurge render-care configure --source /absolute/remotion-project --primary luna --reviewer terra --enable
devpurge render-care scan
devpurge render-care review
devpurge render-care apply
```

Register retained projects containing `public`, `src/index.ts` and `package.json`.
The paths must be physical, not symlinks. `scan` writes local measurements but
never deletes or calls a model. `review` hashes candidates and asks Codex without
deleting. `apply` repeats local verification and permanently reclaims approved
copies. `watch` does the same only with explicit `--enable`; otherwise it reviews.
Existing `devpurge -n` and archive read-only contracts are unchanged.

Model roles are `luna`, `terra`, `sol` and `astra`. The CLI's local advertised
model catalog determines the actual version; desktop model availability may
differ. The first model classifies verified facts. `review` decisions and cleanup
batches of at least10GiB receive a second review. A primary failure tries the
configured reviewer; unavailable/invalid responses keep everything. A `keep`
decision is never overridden. Authentication uses ChatGPT sign-in, not API keys.
Included plan usage and existing credits follow account policy; no purchase or
auto-reload setting is changed.

Only opaque IDs, type, bytes, local-verification and activity booleans are sent
to Codex. Paths, source contents and private documents are not supplied in the
classification prompt. `codex exec` runs in an isolated temporary cwd with a
read-only sandbox, ephemeral history and user config disabled. Global Codex
instructions can still load. Model responses are parsed as data and cannot
provide executable commands, target paths or new cleanup authority.

## Deletion boundary

The current automatic scope is `remotion-webpack-bundle-*` directly inside the
current user's Darwin temporary root. It is not a general temporary-folder
eraser. Unknown render frames/audio, downloads, model weights, session history,
worktrees and original projects are outside this deletion scope.

- Process inventory and open-file enumeration must succeed completely. All
  Remotion/compositor/headless-browser processes, Node/ffmpeg arguments referring
  to Remotion, and Node processes with a registered project cwd inform protection.
- Preserve bundles born within one hour before the oldest live renderer or any
  time afterward. This is based on the inspected Remotion bundler's fresh random
  directory per invocation. Explicit path arguments and open files protect older
  bundles too. A new renderer appearing after the plan invalidates removal.
- At least one hour since the newest nested change. Age alone is never enough.
- Every copied regular file must match a retained project file by SHA-256.
  A changed/missing original leaves that copy in place. When any copy differs,
  only the matching regular files are unlinked; the directory, differing files
  and generated code are retained. A fully verified bundle may be removed whole.
- Public symlinks must match their retained source link. They are never traversed
  during traversal/removal. Partial cleanup does not remove links. Protected
  names, secrets, configured exclusions and archive roots are respected.
- Recheck source and target identities, contents and process state immediately
  before removal. Descriptor-relative unlink and Python's symlink-safe rmtree
  prevent following replaced directory links. No process is terminated.
- A ten-minute plan expires; concurrent runs are serialized. A durable attempt
  receipt precedes deletion. A partial failure is not reported as success.

No process snapshot can atomically prevent a separate program from subsequently
opening an old directory. Manually reusing old bundler outputs is outside this
fresh-per-invocation contract; exclude such locations in `~/.devpurgerc`.

## Ongoing care

Prepare an inspectable launchd definition, then explicitly install it:

```sh
python3 scripts/install-render-care.py --root /absolute/primary/devpurge
python3 scripts/install-render-care.py --root /absolute/primary/devpurge --install
```

The installer defaults to preparation only. Installation starts a per-user job
every600seconds and on login/load. It refuses an existing job and temporary
worktree runtime paths. No root privileges, reboot, force-kill, outgoing messages
or modification to existing purge/triage jobs. macOS privacy permissions may
block access; those failures retain data and appear in service status/logs.

Local private state: `~/Library/Application Support/devpurge/render-care/`.
`latest.json` contains proof, `review.json` the model result, `receipts/` the exact
removal and retained-source hashes, and `history.json` up to2,016 samples. The
dashboard flags free space below50GiB or growth of10GiB since the last sample.
The actual free-space delta and removed allocation are separate: concurrent
rendering, APFS snapshots/clones and OS cleanup affect the former. Sampling can
observe a sharp rise; it does not impose a hard quota or guarantee prevention of
a200GB surge within an interval. An incomplete inventory is not a zero.

Recreate removed copies by running the retained Remotion project again. Permanent
removal has no Trash restoration. Retained differing edits require separate
review; automatic care never labels those unique versions disposable.
