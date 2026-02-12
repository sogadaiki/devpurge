#!/usr/bin/env bash
# devpurge - Utility functions

# ── Color constants ───────────────────────────────────────────────────────────
if [[ "${DEVPURGE_NO_COLOR:-}" == "1" ]] || [[ ! -t 1 ]]; then
  CLR_RESET=""
  CLR_BOLD=""
  CLR_RED=""
  CLR_GREEN=""
  CLR_YELLOW=""
  CLR_CYAN=""
  CLR_DIM=""
else
  CLR_RESET="\033[0m"
  CLR_BOLD="\033[1m"
  CLR_RED="\033[31m"
  CLR_GREEN="\033[32m"
  CLR_YELLOW="\033[33m"
  CLR_CYAN="\033[36m"
  CLR_DIM="\033[2m"
fi

DEVPURGE_VERSION="0.1.0"

# ── Print helpers ─────────────────────────────────────────────────────────────
dp_info() {
  printf "${CLR_CYAN}%s${CLR_RESET}\n" "$*"
}

dp_success() {
  printf "${CLR_GREEN}%s${CLR_RESET}\n" "$*"
}

dp_warn() {
  printf "${CLR_YELLOW}%s${CLR_RESET}\n" "$*"
}

dp_error() {
  printf "${CLR_RED}%s${CLR_RESET}\n" "$*" >&2
}

dp_bold() {
  printf "${CLR_BOLD}%s${CLR_RESET}\n" "$*"
}

dp_dim() {
  printf "${CLR_DIM}%s${CLR_RESET}\n" "$*"
}

# ── Size conversion ───────────────────────────────────────────────────────────
# Convert human-readable size (e.g. "1.2G", "450M", "12K") to bytes for sorting
size_to_bytes() {
  local size="$1"
  local num unit
  num=$(echo "$size" | sed 's/[^0-9.]//g')
  unit=$(echo "$size" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

  case "$unit" in
    T|TB) echo "$num * 1099511627776" | bc 2>/dev/null || echo 0 ;;
    G|GB) echo "$num * 1073741824" | bc 2>/dev/null || echo 0 ;;
    M|MB) echo "$num * 1048576" | bc 2>/dev/null || echo 0 ;;
    K|KB) echo "$num * 1024" | bc 2>/dev/null || echo 0 ;;
    B|"") echo "${num%.*}" ;;
    *)    echo 0 ;;
  esac
}

# Format bytes to human-readable
bytes_to_human() {
  local bytes="$1"
  if [[ "$bytes" -ge 1073741824 ]]; then
    printf "%.1fG" "$(echo "$bytes / 1073741824" | bc -l 2>/dev/null)"
  elif [[ "$bytes" -ge 1048576 ]]; then
    printf "%.0fM" "$(echo "$bytes / 1048576" | bc -l 2>/dev/null)"
  elif [[ "$bytes" -ge 1024 ]]; then
    printf "%.0fK" "$(echo "$bytes / 1024" | bc -l 2>/dev/null)"
  else
    printf "%dB" "$bytes"
  fi
}

# ── Confirm prompt ────────────────────────────────────────────────────────────
dp_confirm() {
  local prompt="${1:-Continue?}"
  local response
  printf "${CLR_BOLD}%s [y/N] ${CLR_RESET}" "$prompt"
  read -r response
  case "$response" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ── URL encode (for Twitter intent) ──────────────────────────────────────────
urlencode() {
  local string="$1"
  local length=${#string}
  local encoded=""
  local c
  for (( i = 0; i < length; i++ )); do
    c="${string:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      ' ') encoded+="%20" ;;
      *) encoded+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$encoded"
}

# ── Tier display name ────────────────────────────────────────────────────────
tier_label() {
  case "$1" in
    ai)      printf "${CLR_CYAN}AI-Era${CLR_RESET}" ;;
    dev)     printf "${CLR_GREEN}DevTool${CLR_RESET}" ;;
    caution) printf "${CLR_YELLOW}Caution${CLR_RESET}" ;;
    *)       printf "%s" "$1" ;;
  esac
}

tier_label_plain() {
  case "$1" in
    ai)      printf "AI-Era" ;;
    dev)     printf "DevTool" ;;
    caution) printf "Caution" ;;
    *)       printf "%s" "$1" ;;
  esac
}
