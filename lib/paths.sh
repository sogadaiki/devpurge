#!/usr/bin/env bash
# devpurge - Cache path definitions
# Format: ID|PATH|TIER|DESCRIPTION
# TIER: ai (AI-era), dev (Standard Dev), caution (Caution - --all only)

DEVPURGE_PATHS=()

# ── Tier 1: AI-Era ───────────────────────────────────────────────────────────
DEVPURGE_PATHS+=(
  "A01|${HOME}/Library/Application Support/Claude/vm_bundles|ai|Claude Desktop VM bundles"
  "A02|${HOME}/Library/Application Support/Cursor/Cache|ai|Cursor IDE cache"
  "A03|${HOME}/Library/Application Support/Cursor/CachedData|ai|Cursor cached data"
  "A04|${HOME}/.cache/uv|ai|uv Python cache"
  "A05|${HOME}/Library/Caches/ms-playwright|ai|Playwright browsers"
  "A06|${HOME}/.cache/puppeteer|ai|Puppeteer browsers"
  "A07|${HOME}/.bun/install/cache|ai|Bun package cache"
  "A08|${HOME}/.codeium|ai|Codeium AI cache"
  "A09|${HOME}/Library/Caches/claude-cli-nodejs|ai|Claude Code CLI cache (MCP logs)"
  "A10|${HOME}/Library/Application Support/Kiro|ai|Kiro IDE cache"
  "A11|${HOME}/.cache/codex-runtimes|ai|Codex CLI runtime cache"
  "A12|${HOME}/.gemini/tmp|ai|Gemini CLI temp sessions"
  "A13|${HOME}/.claude/plugins/cache|ai|Claude Code plugin cache"
  "A14|${HOME}/.claude/debug|ai|Claude Code debug logs"
)

# ── Tier 2: Standard Dev ─────────────────────────────────────────────────────
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
  "D16|${HOME}/Library/Application Support/Adobe/Common/Media Cache Files|dev|Adobe media cache"
  "D17|${HOME}/Library/Caches/Adobe|dev|Adobe app caches"
  "D18|${HOME}/Library/Application Support/Google/Chrome/Default/Service Worker|dev|Chrome Service Workers"
  "D19|${HOME}/Library/Application Support/Google/Chrome/Default/File System|dev|Chrome File System"
  "D20|${HOME}/Library/Application Support/Google/Chrome/Default/IndexedDB|dev|Chrome IndexedDB"
  "D21|${HOME}/.npm/_npx|dev|npm npx cache"
  "D22|${HOME}/Library/Logs|dev|System & app logs"
  "D23|${HOME}/Library/Caches/dotslash|dev|dotslash binary cache"
  "D24|${HOME}/Library/Caches/pypoetry|dev|Poetry cache"
  "D25|${HOME}/Library/Caches/node-gyp|dev|node-gyp cache"
  "D26|${HOME}/Library/Caches/next-swc|dev|next-swc cache"
  "D27|${HOME}/.cargo/registry/src|dev|Cargo registry source"
  "D28|${HOME}/Library/pnpm/store|dev|pnpm content-addressable store"
  "D29|${HOME}/Library/Caches/Yarn|dev|Yarn cache"
  "D30|${HOME}/Library/Caches/deno|dev|Deno module cache"
  "D31|${HOME}/Library/Caches/composer|dev|Composer cache"
  "D32|${HOME}/Library/Caches/typescript|dev|TypeScript auto type acquisition cache"
  "D33|${HOME}/Library/Caches/electron|dev|Electron binary cache"
  "D34|${HOME}/Library/Caches/electron-builder|dev|electron-builder toolchain cache"
  "D35|${HOME}/Library/Caches/org.swift.swiftpm|dev|SwiftPM cache"
  "D36|${HOME}/Library/Caches/JetBrains|dev|JetBrains IDE caches (reindex on next launch)"
  "D37|${HOME}/Library/Caches/com.apple.dt.Xcode|dev|Xcode app cache"
  "D38|${HOME}/Library/Developer/CoreSimulator/Caches|dev|Simulator dyld caches"
  "D39|${HOME}/Library/Application Support/Code/CachedData|dev|VS Code V8 bytecode cache"
  "D40|${HOME}/.android/cache|dev|Android build cache"
  "D41|${HOME}/Library/Application Support/Google/Chrome/component_crx_cache|dev|Chrome component update cache"
)

# ── Tier 3: Caution (--all to enable) ────────────────────────────────────────
DEVPURGE_PATHS+=(
  "C01|${HOME}/Library/Application Support/Notion|caution|Notion local data"
  "C02|${HOME}/Library/Application Support/discord/Cache|caution|Discord cache"
  "C03|${HOME}/Library/Application Support/Slack/Cache|caution|Slack cache"
  "C04|${HOME}/Library/Application Support/Wondershare Filmora Mac|caution|Filmora cache"
  "C05|${HOME}/Library/Application Support/Steam/appcache|caution|Steam app cache"
  "C06|${HOME}/Library/Application Support/Adobe/Fonts|caution|Adobe font sync"
  "C07|${HOME}/Library/Application Support/Adobe/CoreSync|caution|Adobe CoreSync"
  "C08|${HOME}/Library/Caches/us.zoom.xos|caution|Zoom cache"
  "C09|${HOME}/Library/Application Support/Chatwork|caution|Chatwork cache"
  "C10|${HOME}/Library/Application Support/Telegram Desktop|caution|Telegram cache"
  "C11|${HOME}/.cache/whisper|caution|Whisper models (re-download ~3GB)"
  "C12|${HOME}/.cache/huggingface|caution|Hugging Face model cache (re-download cost)"
  "C13|${HOME}/.ollama/models|caution|Ollama models (re-pull cost)"
  "C14|${HOME}/.lmstudio/models|caution|LM Studio models (re-download cost)"
  "C18|${HOME}/Library/Caches/Cypress|caution|Cypress binaries (re-download per version)"
  "C19|${HOME}/.gradle/wrapper/dists|caution|Gradle wrapper distributions (re-download per version)"
  "C20|${HOME}/Library/Developer/Xcode/iOS DeviceSupport|caution|Xcode device symbols (regenerated on device connect)"
  "C21|${HOME}/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel|caution|Chrome on-device AI models (auto re-downloads ~4GB)"
  "C22|${HOME}/Library/Application Support/Google/Chrome/OptGuideOnDeviceClassifierModel|caution|Chrome on-device AI classifier (auto re-downloads)"
  "C23|${HOME}/Library/Application Support/Google/Chrome/screen_ai|caution|Chrome Screen AI models (auto re-downloads)"
  "C24|${HOME}/Library/Application Support/com.apple.wallpaper|caution|macOS wallpaper videos (auto re-downloads)"
)

# ── Review: reported but NEVER deleted (user data / history) ─────────────────
# Format: ID|PATH|review|DESCRIPTION
DEVPURGE_REVIEW_PATHS=(
  "V01|${HOME}/Downloads|review|Downloads folder (check old files yourself)"
  "V02|${HOME}/Movies|review|Movies (user videos)"
  "V03|${HOME}/.codex/archived_sessions|review|Codex archived sessions (history mining source)"
  "V04|${HOME}/.codex/sessions|review|Codex session history"
  "V05|${HOME}/.claude/projects|review|Claude Code session transcripts"
  "V06|${HOME}/.gemini/antigravity-browser-profile|review|Antigravity browser profile (contains logins)"
  "V07|${HOME}/.agent-browser|review|agent-browser profiles (active tool, contains logins)"
  "V08|${HOME}/Library/Containers/com.docker.docker/Data/vms|review|Docker Desktop VM disk (use: docker system prune)"
  "V09|${HOME}/.android/avd|review|Android emulator images (recreate cost)"
  "V10|${HOME}/.claude-backup|review|Claude settings backup (delete manually if obsolete)"
  "V11|${HOME}/.dev-browser|review|dev-browser profiles (may hold logins; superseded by agent-browser)"
  "V12|${HOME}/.gemini/antigravity-backup|review|Antigravity IDE backup copy (delete manually if obsolete)"
  "V13|${HOME}/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data|review|OrbStack VM data (use: docker system prune inside OrbStack)"
  "V14|${HOME}/.colima|review|Colima VM data (deleting destroys all containers)"
  "V15|${HOME}/.lima|review|Lima VM data (deleting destroys all VMs)"
  "V16|${HOME}/Library/Containers/com.utmapp.UTM/Data/Documents|review|UTM virtual machines (user-created VMs)"
)

# ── Tier 4: System (sudo devpurge only) ─────────────────────────────────────
DEVPURGE_SYSTEM_PATHS=(
  "S01|/private/var/vm/sleepimage|system|Sleep image (RAM snapshot)"
  "S02|/private/var/root/.Trash|system|Root user Trash"
  "S03|/private/var/db/diagnostics|system|System diagnostics logs"
  "S04|/private/var/db/uuidtext|system|Diagnostics UUID text"
  "S05|/Library/Updates|system|Software update cache"
  "S06|/Library/Application Support/Adobe/Premiere Pro|system|Adobe Premiere Pro cache"
  "S07|/Library/Application Support/Adobe/Adobe Media Encoder|system|Adobe Media Encoder cache"
  "S08|/Library/Application Support/Adobe/Installers|system|Adobe old installers"
  "S09|/Library/Application Support/Adobe/CEP|system|Adobe CEP extensions cache"
  "S10|/Library/Application Support/GarageBand|system|GarageBand support data"
  "S11|/Library/Application Support/iPhoto|system|iPhoto legacy data"
  "S12|/Library/Application Support/iDVD|system|iDVD legacy data"
  "S13|/Library/Application Support/iWork '09|system|iWork '09 legacy data"
  "S14|/Library/Application Support/iLifeSlideshow|system|iLife slideshow legacy data"
)

# ── Whitelist: only these path prefixes are allowed for deletion ──────────────
DEVPURGE_WHITELIST=(
  "${HOME}/Library/Application Support/"
  "${HOME}/Library/Caches/"
  "${HOME}/Library/Logs/"
  "${HOME}/Library/Developer/"
  "${HOME}/Library/pnpm/store/"
  "${HOME}/.npm/"
  "${HOME}/.cache/"
  "${HOME}/.bun/"
  "${HOME}/.cargo/"
  "${HOME}/.gradle/"
  "${HOME}/.m2/"
  "${HOME}/.codeium/"
  "${HOME}/.gemini/tmp/"
  "${HOME}/.claude/plugins/cache/"
  "${HOME}/.claude/debug/"
  "${HOME}/.ollama/models/"
  "${HOME}/.lmstudio/models/"
  "${HOME}/.android/cache/"
)

# System-level paths allowed only when running as root
DEVPURGE_SYSTEM_WHITELIST=(
  "/private/var/vm/"
  "/private/var/root/"
  "/private/var/db/diagnostics"
  "/private/var/db/uuidtext"
  "/Library/Updates"
  "/Library/Application Support/Adobe/"
  "/Library/Application Support/GarageBand"
  "/Library/Application Support/iPhoto"
  "/Library/Application Support/iDVD"
  "/Library/Application Support/iWork "
  "/Library/Application Support/iLifeSlideshow"
)

# Verify a path is on the whitelist
# Returns 0 if allowed, 1 if not
devpurge_path_allowed() {
  local target="$1"
  local prefix
  for prefix in "${DEVPURGE_WHITELIST[@]}"; do
    # Match both "prefix*" and exact "prefix" (without trailing slash)
    local prefix_stripped="${prefix%/}"
    case "$target" in
      "$prefix"*|"$prefix_stripped") return 0 ;;
    esac
  done
  # Allow project build artifacts and sandboxed app caches under $HOME
  case "$target" in
    "${HOME}/"*/node_modules) return 0 ;;
    "${HOME}/"*/.next) return 0 ;;
    "${HOME}/Library/Containers/"*/Data/Library/Caches) return 0 ;;
  esac
  # System paths allowed when running as root
  if [[ "${DEVPURGE_IS_ROOT:-0}" == "1" ]]; then
    for prefix in "${DEVPURGE_SYSTEM_WHITELIST[@]}"; do
      local sys_prefix_stripped="${prefix%/}"
      case "$target" in
        "$prefix"*|"$sys_prefix_stripped") return 0 ;;
      esac
    done
  fi
  return 1
}
