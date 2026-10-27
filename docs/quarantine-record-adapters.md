# Cross-session quarantine receipts (Studio 0.19)

The user still performs the final permanent deletion. Adapters consume metadata,
never execute commands or instructions from audit documents.

## Binding and supported proofs

- Read `movement-receipt.json` / `receipts.json` arrays and `receipt.json` objects.
  Match the exact quarantine ID, original and stored paths. Numeric epoch strings
  must equal the manifest epoch. Duplicate bindings across formats/folders fail
  closed. A receipt alone never grants deletion authority.
  Catalog-confirmed completed deletions stay in history and are excluded from
  the unbound-record panel; their audit files are preserved.
- Legacy `{size, sha256}` inventories are compared with the entire current
  inventory; missing, additional, linked, protected or changed files stay held.
- PCM staging WAV: require its recorded source-to-retained-MOV mapping, unchanged
  retained MOV hash, exactly one staging stream, matching PCM24 codec / rate /
  channel count and freshly hashed exact PCM packets. No lossy conversion is used.
  Both fresh stream hashes must also match the original audit hashes. Only local
  WAV/MOV demuxers and file/pipe protocols are enabled; subprocesses have deadlines.
- Remotion pack caches: only known `webpack/remotion-production-<version>/<hash>/`
  pack filenames. The retained checkout's manifest and lockfile hashes must match
  the audit, the Remotion version must match every pack path, and the source
  entrypoint must remain. The retained checkout can differ from the old cache's
  checkout; the UI identifies the actual regeneration location.
- Duplicate asset directories: the single receipt and execution plan's per-file
  proofs must cover every quarantined file exactly once. Rehash each retained
  original; verify each old asset path is now a symlink to that retained original,
  never back to quarantine. Final apply rechecks these hashes and alias identities.
  Only the quarantined directory is deleted; aliases and originals remain.

## Explicit holds

Git worktrees remain outside the generic file-deletion path even when the new
receipt format binds successfully. They need the existing dedicated Git removal
workflow and its current-work / unique-file checks; never `rmtree` a worktree.

Older movie stages with different encoded packets or audio are not classified as
duplicates merely because an audit says a script can regenerate them. If full
file equivalence or actual regeneration has not been established, keep them with
that specific reason. Format support and deletion readiness are separate states.

## Verification

Disposable fixtures cover all three receipt names, string timestamps, duplicate
bindings, wrong PCM, changed retained files, extra staged streams, broken aliases,
unknown cache content, missing regeneration sources, active quarantine and Git
worktree holds. A fixture apply verifies retained assets and aliases survive.
Real read-only probes of the eight new records verified three candidates; five
remain held. No real data was permanently deleted by the agent.
