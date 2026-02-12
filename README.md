# devpurge

> Purge hidden dev caches on macOS. Reclaim GBs from Claude Desktop, Cursor, uv, Playwright, Bun, and 20+ more.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Cleaned with devpurge](https://img.shields.io/badge/cleaned_with-devpurge-00cc88)](https://github.com/sogadaiki/devpurge)

---

## Why devpurge?

Your Mac's "System Data" keeps growing. Tools like CleanMyMac have no idea what Claude Desktop, Cursor, uv, or Playwright are — let alone where they hide gigabytes of cached data.

**devpurge** knows exactly where AI-era dev tools store their bloat, and safely removes it.

```
$ devpurge -n

  devpurge v0.1.0
  Purge hidden dev caches on macOS

  Scanning cache directories...

  #     Tier      Size      Description
  ──    ────────  ────────  ───────────────────────────────────
  A04   AI-Era    4.2G      uv Python cache
  A01   AI-Era    1.8G      Claude Desktop VM bundles
  A05   AI-Era    1.2G      Playwright browsers
  D10   DevTool   3.1G      Xcode DerivedData
  D01   DevTool   890M      npm cache
  D02   DevTool   650M      Homebrew downloads

  Total reclaimable: 11.8G
```

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

# Auto-confirm + generate share text
devpurge -y -s

# AI-era caches only
devpurge --ai-only

# Include everything (Notion, Discord, Slack, etc.)
devpurge -a
```

### Options

| Flag | Description |
|------|-------------|
| `-n, --dry-run` | Scan only, don't delete anything |
| `-a, --all` | Include caution-level caches |
| `-y, --yes` | Skip confirmation prompt |
| `-s, --share` | Generate shareable summary after cleanup |
| `--ai-only` | AI-era caches only |
| `--no-color` | Disable colored output |
| `-v, --version` | Show version |
| `-h, --help` | Show help |

## Cache Targets

### AI-Era (no other tool covers these)

| ID | Target | Typical Size |
|----|--------|-------------|
| A01 | Claude Desktop VM bundles | 500MB - 2GB |
| A02 | Cursor IDE cache | 200MB - 1GB |
| A03 | Cursor cached data | 300MB - 1GB |
| A04 | uv Python cache | 500MB - 5GB |
| A05 | Playwright browsers | 500MB - 2GB |
| A06 | Puppeteer browsers | 500MB - 2GB |
| A07 | Bun package cache | 200MB - 2GB |

### Standard Dev Tools

npm, Homebrew, Chrome, VS Code, pip, Cargo, Gradle, Maven, Xcode DerivedData, iOS Simulator, Go build cache.

### Caution (use `--all`)

Notion, Discord, Slack, Adobe CC logs, Creative Cloud, Filmora, Steam.

## vs CleanMyMac / OnyX / Other Tools

| Feature | devpurge | CleanMyMac | OnyX |
|---------|----------|------------|------|
| Claude Desktop cache | Yes | No | No |
| Cursor IDE cache | Yes | No | No |
| uv / Bun / Playwright | Yes | No | No |
| Xcode DerivedData | Yes | Yes | Yes |
| npm / pip / Cargo | Yes | Partial | No |
| Free & open source | Yes | No ($35/yr) | Yes |
| No GUI needed | Yes | No | No |
| Zero dependencies | Yes | No | No |

## Safety

- Only deletes paths from a hardcoded whitelist — no dynamic path discovery
- Never uses `sudo`
- Permission errors are skipped, not forced
- All paths are absolute and double-quoted
- Interactive confirmation by default (use `--yes` to skip)
- Dry run mode (`--dry-run`) for safe scanning

## Share Your Results

After cleanup, use `--share` to generate a ready-to-post summary:

```
I just purged 7.2GB of hidden dev caches with devpurge

Claude Desktop: 2.1GB
uv Python: 1.8GB
Playwright: 1.2GB
+ 8 more

Your Mac is hoarding AI-era bloat. Check yours:
https://github.com/sogadaiki/devpurge
#devpurge
```

Add a badge to your README:

```markdown
[![Cleaned with devpurge](https://img.shields.io/badge/cleaned_with-devpurge-00cc88)](https://github.com/sogadaiki/devpurge)
```

## Requirements

- macOS (any version with Bash 3.2+)
- No dependencies. Pure Bash.

## License

MIT
