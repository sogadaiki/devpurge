# Studio 0.18 — focused manual cleanup

The home action stays AI-assisted cleanup. Originals, active work and unknown
records remain held; only the user can submit permanent deletion. No new jobs,
automatic expiry, API keys, or process termination were added.

## Design decisions

Reference inspected: [DaisyDisk's official product screenshot](https://daisydiskapp.com/img/home/intro-ss1.png).
Adopt capacity hierarchy, one clear next action, and progressive disclosure.
Change the disk exploration emphasis to an evidence-backed AI proposal, because
this user wants completed project leftovers reviewed without losing originals.
Do not copy the radial chart: overlapping project totals cannot truthfully form
a whole-disk partition. Do not reuse branding or artwork. Preserve devpurge's
existing quiet palette and native controls.

- Current free capacity appears immediately, separately from the last scan.
- Home navigation exposes AI, storage overview and history; specialist tools
  remain available in a disclosure.
- One-second progress polling reads a small activity endpoint, without loading
  audit records or rebuilding the result DOM. Final revalidation reports the
  current item and completed count. All mutation controls are disabled while
  that request runs.
- Candidate details expand individually. Kept items are searchable across the
  complete report; only display is limited to 80 matching rows, not AI coverage.
- Confirmation uses a bounded list with visible footer, exact paths/reasons on
  expansion, a five-minute countdown, and a disabled expired/consumed ticket.

## Performance and safety

Profiling Q126's retained-dependency verification found repeated construction of
parent Path objects in lexical containment. Component-prefix comparison preserves
the old lexical semantics; physical/symlink validation remains separate and
unchanged. fwalk inventory paths are already descriptor-relative, so deriving
relative names no longer walks the absolute parents again.

Same read-only Q126 check with cProfile: 75.8 seconds before, 27.0 seconds after
the containment change (969,723,904 bytes verified in both). This is a single
warm-cache observation, not an end-to-end scan benchmark. Hashing all required
files, audit matching, source retention, activity checks and final pre-delete
revalidation remain in place. Full scans can still take minutes.

Unknown quarantine provenance formats are held with an explicit unsupported-format
reason before hashing; they are not mislabeled as changed content. New records
without a unique source binding are also held, never inferred disposable.
