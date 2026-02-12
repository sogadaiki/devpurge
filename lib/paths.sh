#!/usr/bin/env bash
# devpurge - Cache path definitions
# Format: ID|PATH|TIER|DESCRIPTION
# TIER: ai (AI-era), dev (Standard Dev), caution (Caution - --all only)

DEVPURGE_PATHS=()

# ── Tier 1: AI-Era (no competitor covers these) ──────────────────────────────
DEVPURGE_PATHS+=(
  "A01|${HOME}/Library/Application Support/Claude/vm_bundles|ai|Claude Desktop VM bundles"
  "A02|${HOME}/Library/Application Support/Cursor/Cache|ai|Cursor IDE cache"
  "A03|${HOME}/Library/Application Support/Cursor/CachedData|ai|Cursor cached data"
  "A04|${HOME}/.cache/uv|ai|uv Python cache"
  "A05|${HOME}/Library/Caches/ms-playwright|ai|Playwright browsers"
  "A06|${HOME}/.cache/puppeteer|ai|Puppeteer browsers"
  "A07|${HOME}/.bun/install/cache|ai|Bun package cache"
)

# ── Tier 2: Standard Dev (comprehensive coverage) ────────────────────────────
DEVPURGE_PATHS+=(
  "D01|${HOME}/.npm/_cacache|dev|npm cache"
  "D02|${HOME}/Library/Caches/Homebrew|dev|Homebrew downloads"
  "D03|${HOME}/Library/Caches/Google/Chrome|dev|Chrome browser cache"
  "D04|${HOME}/Library/Application Support/Code/CachedExtensionVSIXs|dev|VS Code extension cache"
  "D05|${HOME}/Library/Caches/com.microsoft.VSCode.ShipIt|dev|VS Code update cache"
  "D06|${HOME}/Library/Caches/pip|dev|pip cache"
  "D07|${HOME}/.cargo/registry/cache|dev|Cargo registry cache"
  "D08|${HOME}/.gradle/caches|dev|Gradle build cache"
  "D09|${HOME}/.m2/repository|dev|Maven local repository"
  "D10|${HOME}/Library/Developer/Xcode/DerivedData|dev|Xcode DerivedData"
  "D11|${HOME}/Library/Developer/CoreSimulator/Devices|dev|iOS Simulator runtimes"
  "D12|${HOME}/.cache/go-build|dev|Go build cache"
  "D13|${HOME}/.cache/pip|dev|pip cache (Linux-style)"
  "D14|${HOME}/Library/Developer/Xcode/Archives|dev|Xcode archives"
  "D15|${HOME}/.cache/chrome-devtools-mcp|dev|Chrome DevTools MCP cache"
)

# ── Tier 3: Caution (--all to enable) ────────────────────────────────────────
DEVPURGE_PATHS+=(
  "C01|${HOME}/Library/Application Support/Notion|caution|Notion local data"
  "C02|${HOME}/Library/Application Support/discord/Cache|caution|Discord cache"
  "C03|${HOME}/Library/Application Support/Slack/Cache|caution|Slack cache"
  "C04|${HOME}/Library/Logs/Adobe|caution|Adobe CC logs"
  "C05|${HOME}/Library/Logs/CreativeCloud|caution|Creative Cloud logs"
  "C06|${HOME}/Library/Application Support/Wondershare Filmora Mac|caution|Filmora cache"
  "C07|${HOME}/Library/Application Support/Steam/appcache|caution|Steam app cache"
)

# ── Whitelist: only these path prefixes are allowed for deletion ──────────────
DEVPURGE_WHITELIST=(
  "${HOME}/Library/Application Support/"
  "${HOME}/Library/Caches/"
  "${HOME}/Library/Logs/"
  "${HOME}/Library/Developer/"
  "${HOME}/.npm/"
  "${HOME}/.cache/"
  "${HOME}/.bun/"
  "${HOME}/.cargo/"
  "${HOME}/.gradle/"
  "${HOME}/.m2/"
)

# Verify a path is on the whitelist
# Returns 0 if allowed, 1 if not
devpurge_path_allowed() {
  local target="$1"
  for prefix in "${DEVPURGE_WHITELIST[@]}"; do
    case "$target" in
      "$prefix"*) return 0 ;;
    esac
  done
  return 1
}
