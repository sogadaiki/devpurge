# Completed-build duplicate prevention

CLI0.9 adds an explicitly registered, opt-in build policy (Python3.11+ for cleanup). No new service or
scheduler is installed. Without activation `run` returns `disabled` and deletes
nothing. `scan`, ordinary `-n`, and `--json` are read-only and do not register
arrivals, enable a policy or erase data. Standard CLI rows are always `review`;
only the separate enabled policy can perform permanent cleanup.
The supported artifact grammar is the inspected Rental Legend Godot/iOS export
layout (`RentalLegend.ipa`, `.xcarchive`, `.pck`, `.xcframework`); other layouts
are not generalized into deletion candidates.

## Why the copies accumulated

The inspected Godot/iOS builders create a new numbered directory, export a PCK
and an XCFramework, copy tracked source, import resources, create Xcode caches,
archive/sign, export an IPA and unpack it for validation. Validation ended the
build without a cleanup step. Repeated output directories retained those copies
alongside the actual IPA, archive/dSYMs and source originals. Previous devpurge
discovery reported file duplicates or generic generated folders without proving
their relationship to the retained release. Whole active worktrees consequently
remained too risky to remove.

## Exact retention and proof rules

- Register at most16 physical `build` roots under development projects; never
  infer roots from filenames across the entire disk. Only their direct numbered
  `ios-testflight-build<N>...` directories participate. Links, exclusions,
  protected names and `.devpurge-keep` are honored.
- Keep the highest two build numbers across **all** registered roots, explicitly
  pinned numbers and the build that owns the retained common framework. Incomplete
  newer outputs also count, conservatively keeping them. Unrelated worktrees,
  Git state and any whole output directory are never deletion targets.
- Every old build needs an existing nonempty signed-archive directory and an
  unchanged IPA matching its recorded successful distribution validation/build
  number. That record is provenance, not deletion authority; content proofs are
  still required. The policy never deletes an IPA, archive, dSYM or validation.
- PCK copies and IPA extraction files must freshly match the exact retained IPA
  members. Unknown/additional/different files stay held. Partial extraction trees
  are supported when all remaining files match. Original IPA hashes are rechecked.
- A duplicate exported framework must match every retained framework file, with
  the retained copy outside the target and in the configured roots. Differing
  versions stay held. Old Xcode projects need these removed parts restored from
  the recorded retained source before rebuilding; current/pinned builds keep them.
- Imported Godot data requires matching source-archive provenance, current source
  assets and `.import` mappings for every cache file. Editor state and unknown
  imported files stay held. Only named module/compiler caches are considered
  in Xcode; dependency checkouts, logs and unsupported intermediate trees remain.
- Output must be Git-ignored and untracked. Current open files, process arguments,
  package operations within the build, reference links, incomplete usage checks and failed content
  verification retain the target. Before each deletion, re-evaluate policy and
  newest/pinned builds and repeat proofs. Symlink-safe pinned-parent removal uses
  the same operation lock as quarantine/Studio. Root execution is prohibited.

## Setup and operation

```sh
# First register a disabled, reviewable policy (repeat --root and --pin as needed).
devpurge build-care configure --root /absolute/project/build \
  --pin 53 --pin 54 \
  --anchor /absolute/project/build/ios-testflight-build53-date/RentalLegend.xcframework
devpurge build-care scan
# Only after the user authorizes this exact ongoing permanent-deletion policy:
# repeat configure with the same arguments plus --auto
devpurge build-care run
```

Policy: `~/Library/Application Support/devpurge/build-care/policy.json`.
Receipts under its `receipts/` directory record per-target success/holds and
physical free bytes before/after separately from allocated target bytes. Keep
those original-source locators and receipts for restoration. Disable by repeating
`configure` without `--auto`; this does not undo completed deletion.

The existing unattended `devpurge -y` invokes enabled policies even if there are
no other ordinary caches. It skips this operation for root, AI-only and read-only
modes. Build54's builder also calls `devpurge build-care run` **after successful
IPA validation**, with failures logged instead of invalidating the exported IPA.
Future builder templates should retain this hook. Existing active branches must
integrate the hook normally; never replace another session's working files.

Safety fixtures cover latest/pins, changed originals, dirty/tracked data, unique
files, mismatched frameworks, links, keep markers, unmapped imports, unknown use,
policy changes and a complete two-generation transition. No test uses real user
releases. This prevents recurrence within the registered grammar; it does not
stop every application or arbitrary new output layout from consuming storage.
