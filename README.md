# devpurge

> Purge hidden dev caches on macOS. Reclaim GBs from Claude Code, Codex, Cursor, node_modules, stale git worktrees, uv, Playwright, and 70+ more.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Cleaned with devpurge](https://img.shields.io/badge/cleaned_with-devpurge-00cc88)](https://github.com/sogadaiki/devpurge)

---

## Why devpurge?

Your Mac's "System Data" keeps growing. GUI cleaners are catching up on AI-era tools, but none of them understand a *developer's* disk: stale git worktrees from agentic coding sessions, monorepo node_modules, Codex/Claude runtime caches — and none of them can run from cron.

**devpurge** knows exactly where AI-era dev tools store their bloat, and safely removes it. It cleans dev caches only — it never touches your personal files.

```
$ devpurge -n

  devpurge v0.4.0
  Purge hidden dev caches on macOS

  #     Tier      Size      Description
  ──    ────────  ────────  ───────────────────────────────────
  A11   AI-Era    3.3G      Codex CLI runtime cache
  W12   Worktree  1.9G      worktree: my-app-feature-x (merged, clean, idle 7d+)
  D28   DevTool   1.6G      pnpm content-addressable store
  A04   AI-Era    1.6G      uv Python cache
  X01   Project   1.3G      .next cache (web)
  N07   Project   1.1G      node_modules (web)
  E01   DevTool   127M      App cache: Claude/Code Cache

  Total reclaimable: 43.8G

  Review — large data devpurge will NOT delete (your call)
  V01   59.8G     Downloads folder (check old files yourself)
  R05   1.9G      worktree: my-app-wip (dirty (uncommitted changes))
```

## Real Results

- v0.3.0: **45GB recovered** on one machine — 221GB used down to 176GB
- v0.4.0: **43.8GB found reclaimable** on an already-maintained machine (22.4GB of it was stale git worktrees no other tool detects)

## Install

### Homebrew (recommended)

```bash
brew tap sogadaiki/devpurge
brew install devpurge
```

### curl

```bash
curl -fsSL https://raw.githubusercontent.com/sogadaiki/devpurge/main/install.sh | bash
```

### Manual

```bash
git clone https://github.com/sogadaiki/devpurge.git ~/.devpurge
ln -sf ~/.devpurge/bin/devpurge /usr/local/bin/devpurge
```

## Usage

```bash
# Scan only (dry run) — see what's there without deleting
devpurge -n

# Interactive cleanup — scan, review, confirm, delete
devpurge

# Recoverable cleanup — move to ~/.Trash instead of deleting
devpurge --trash

# Auto-confirm + generate share text
devpurge -y -s

# Where did my disk go? (read-only overview of $HOME)
devpurge --discover

# Machine-readable output for scripts
devpurge --json | jq '.total_reclaimable_bytes'

# AI-era caches only
devpurge --ai-only

# Include everything (Notion, Discord, Slack, AI models, etc.)
devpurge -a

# System-level caches (sleepimage, diagnostics, Adobe system caches)
sudo devpurge -n

# Exclude specific paths (also skips everything under them)
devpurge --exclude ~/Projects/my-app/node_modules
```

### Options

| Flag | Description |
|------|-------------|
| `-n, --dry-run` | Scan only, don't delete anything |
| `-a, --all` | Include caution-level caches |
| `-y, --yes` | Skip confirmation prompt |
| `-s, --share` | Generate shareable summary after cleanup |
| `--trash` | Move to `~/.Trash` instead of deleting (recoverable) |
| `--json` | Print scan results as JSON and exit |
| `--discover` | Show largest items under `$HOME` (read-only) and exit |
| `--exclude PATH` | Exclude path and everything under it (repeatable) |
| `--ai-only` | AI-era caches only |
| `--no-worktrees` | Skip git worktree detection |
| `--no-color` | Disable colored output |
| `-v, --version` | Show version |
| `-h, --help` | Show help |

## Cache Tiers

### Worktree (v0.4.0 new — no other tool has this)

Agentic coding (Codex, Claude Code, etc.) leaves behind git worktrees — full checkouts with their own node_modules. devpurge finds every worktree of every repo in your project directories and classifies it:

- **merged + clean + idle 7d+** → removable, via `git worktree remove` (never `rm -rf`)
- **stale records** → `git worktree prune`
- **unmerged / dirty / locked / recently active / contains `.env*`** → *reported only, never touched*

Unattended runs (`-y`, e.g. cron) skip worktree removal entirely unless you opt in with `worktree_auto=1` — git-clean checks can't see ignored files, so a human should be in the loop by default. Idle threshold configurable via `worktree_age_days=N` in `~/.devpurgerc`.

### Review (v0.4.0 new — reported, NEVER deleted)

Large user data that a cleanup tool has no business deleting, but that you should know about: Downloads, Movies, screen recordings on the Desktop, AI session histories (`~/.codex/sessions`, `~/.claude/projects`), browser-automation profiles, Time Machine local snapshots. devpurge shows them with sizes and lets *you* decide.

### AI-Era

Claude Desktop VM bundles, Claude Code CLI/plugin/debug caches, Codex CLI runtime cache, Gemini CLI temp sessions, Cursor, Codeium, Kiro, uv, Playwright, Puppeteer, Bun.

### Standard Dev Tools

npm (+npx), pnpm store, Yarn, Homebrew, Chrome (browser cache + Service Workers + IndexedDB + component cache), VS Code (extensions + bytecode cache), pip, Poetry, Cargo, Gradle, Maven, Xcode (DerivedData, archives, simulator caches), Go, Deno, Composer, TypeScript ATA, Electron, electron-builder, SwiftPM, JetBrains, Android build cache, Adobe media cache, system logs, and more.

Plus three auto-detectors that catch what static lists miss:

- **Misc caches**: anything ≥10MB in `~/Library/Caches` not already targeted
- **Electron app caches**: `Cache` / `Code Cache` / `GPUCache` / `DawnCache` inside any app's Application Support (catches new AI IDEs the day you install them)
- **Container caches**: sandboxed app caches in `~/Library/Containers/*/Data/Library/Caches`

### Project

node_modules and `.next` in your project folders (scans 5 levels deep — monorepo `apps/*`, `workers/*` included). Recoverable with `npm install` / `npm run build`.

### Caution (use `--all`)

Notion, Discord, Slack, Adobe Fonts/CoreSync, Filmora, Steam, Zoom, Chatwork, Telegram — plus things that are *safe* but expensive to re-download: Whisper / Hugging Face / Ollama / LM Studio models, Chrome on-device AI models, Cypress binaries, Gradle wrapper dists, Xcode device symbols.

### System (`sudo devpurge`)

sleepimage (with automatic `hibernatemode 0`), system diagnostics logs, software update cache, Adobe system-level caches, iLife-era leftovers.

## vs CleanMyMac / DevCleaner / npkill / kondo

| Feature | devpurge | CleanMyMac | DevCleaner | npkill/kondo |
|---------|----------|------------|------------|--------------|
| Stale git worktree detection | **Yes** | No | No | No |
| AI-era caches (Claude/Codex/Cursor/uv/…) | Yes | Partial | Yes | No |
| Auto-detect new Electron/AI apps | **Yes** | No | No | No |
| node_modules / .next auto-scan (monorepo) | Yes | No | No | Yes |
| Review tier (reports, refuses to delete user data) | **Yes** | No | No | No |
| Recoverable deletion | `--trash` | Trash | — | No |
| JSON output / cron-safe CLI | **Yes** | No | No | Partial |
| Free & open source, zero deps, zero telemetry | **Yes** | No ($40/yr) | Free (GUI) | Yes |

**What devpurge deliberately does NOT do**: mail attachments, language files, duplicate finders, "smart" scans of your documents. Dev caches only. Personal data is never touched — the Review tier exists precisely so the tool can inform without acting.

## Config File

Create `~/.devpurgerc`:

```
# Keep active project dependencies (path + everything under it)
exclude=~/Desktop/development/my-app/node_modules

# Days a merged worktree must be idle before it's removable (default 7)
worktree_age_days=14

# Allow worktree removal in unattended (-y) runs (default: skip)
worktree_auto=1
```

CLI `--exclude` flags are merged with config file entries.

## Safety

- Static targets are limited to a hardcoded whitelist
- Dynamic scans (node_modules, misc/Electron/Container caches) are restricted to `$HOME` and whitelisted path patterns
- Worktrees are removed via `git worktree remove` — git itself refuses dirty/locked trees; devpurge never passes `--force`
- Review tier is structurally excluded from deletion (not just by default — the cleanup code refuses it)
- Final guard before every `rm -rf`: blocks empty paths, `/`, `$HOME` itself, traversal, and symlinks
- `--trash` moves to `~/.Trash` for full recoverability
- Permission errors are skipped, not forced
- Interactive confirmation by default (use `--yes` to skip)
- Dry run mode (`--dry-run`) for safe scanning

## Share Your Results

After cleanup, use `--share` to generate a ready-to-post summary:

```
I just purged 43.8GB of hidden dev caches with devpurge

Stale git worktrees: 22.4GB
Codex runtime: 3.3GB
uv Python: 1.6GB
+ 30 more

Your Mac is hoarding AI-era bloat. Check yours:
https://github.com/sogadaiki/devpurge
#devpurge
```

## Requirements

- macOS (any version with Bash 3.2+)
- No dependencies. Pure Bash.

## License

MIT
