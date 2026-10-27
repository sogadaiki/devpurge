# AI cleanup assistant

The app starts at **AIで片付ける**. The manual workflow is:

1. Press **AIで片付ける** once. Scan, local verification, AI selection and
   preparation of the exact deletion plan proceed automatically.
2. Review the final paths, measured sizes and effects; choose **この内容で完全削除する**
   or **今回は削除しない**. No checkbox selection or model choice is required.
3. After the user's final deletion action, see actual free-space change.

There is no schedule. Selecting candidates is not deletion. The final in-app
action explicitly says permanent deletion; there is no Trash recovery. Existing
Trash/restore workflows remain available elsewhere for reviewable intermediates.

## Supported reclamation

- Fixed pip, npm download and Homebrew download caches already declared safe
  in Studio's target list. Runtime environments and npx/MCP installs are held.
- Ignored `.next` and `.open-next` build directories found by the bounded
  development scan, with a retained Next package manifest and build script.
  Git-tracked output, active project processes/open files and unknown sources
  are held. Package manifest identity is rechecked before deleting.
- Registered Remotion temporary copies are included in the same proposal using
  existing retained-original proofs, partial-copy handling and activity checks.
- Ended-browser recovery and memory/swap diagnosis remain separate advanced
  screens. The one-button workflow does not close user processes.

This is not a whole-disk eraser. Source media, session history, generated images,
model weights, virtual environments, worktrees, unknown intermediates and
user documents remain held with reasons. The scan reports its bounded scope.
Large size alone is not permission to delete; empty candidates are a valid result.

## Codex CLI

Uses the installed `codex exec`, existing ChatGPT login and advertised model
catalog. No API key is required or read, and API-key environment variables are
removed from the child environment. Default roles: sol for the proposal and
terra for independent verification of every deletion recommendation. The user
does not need to choose a model. The internal adapter supports luna, terra, sol
and astra. Versions resolve from the local CLI catalog. If the account rejects a
version as unavailable, the adapter tries older advertised versions of the same
family and remembers rejected versions for one hour. It never guesses a model
ID or switches to API billing. Other failures or invalid output preserve targets.

Only opaque IDs, category, byte counts, growth and local-verification flags are
sent. No paths, project names or file contents are supplied. The CLI runs with
user config disabled, ephemeral history, isolated temporary cwd, a read-only
sandbox and structured output; global instructions can still load. Model output
is data, never executable code. It cannot add paths or override local holds.
Included usage and credits follow account policy; purchase settings are unchanged.

All locally eligible candidates plus the largest retained rows, up to 80, receive
AI review. Unreviewed rows remain held. The first model's keep decision is never
overridden; proposed cleanup/review receives the second check. Failed review
invalidates eligibility. Starting a new scan invalidates old proposals/plans.

## Revalidation and receipts

Exact local allowlists, protected/excluded paths, no links/special files,
24-hour inactivity and complete open-file/process checks gate every deletion.
Plans revalidate metadata and regeneration evidence, expire after five minutes,
and are single-use. Proposals expire after 30 minutes. App operations serialize
with existing Studio cleanup and an assistant file lock.

Before each deletion, all checks run again; every ancestor is opened without
following links and descriptor-relative rmtree checks the root identity. No
process is stopped. Python must support descriptor-relative safe removal
(tested with the installed Python 3.12); unsupported removal preserves the target.
External applications can still change state between checks: this is conservative
best-effort coordination, not a system-wide lock on writers.

Private state is `~/Library/Application Support/devpurge/assistant/`. Durable
receipts precede removal and distinguish removed, kept and partial/uncertain
results. Measured candidate bytes and actual free-space delta are separate;
APFS sharing/snapshots and concurrent work can make them differ. Interrupted
operations retain their receipts; rerun inspection before another action.
