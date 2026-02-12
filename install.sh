#!/usr/bin/env bash
# devpurge installer
# Usage: curl -fsSL https://raw.githubusercontent.com/sogadaiki/devpurge/main/install.sh | bash
set -euo pipefail

REPO="sogadaiki/devpurge"
INSTALL_DIR="${HOME}/.devpurge"
BIN_LINK="/usr/local/bin/devpurge"

info() { printf "\033[36m%s\033[0m\n" "$*"; }
success() { printf "\033[32m%s\033[0m\n" "$*"; }
error() { printf "\033[31m%s\033[0m\n" "$*" >&2; }

# ── macOS check ──────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  error "devpurge is designed for macOS only."
  exit 1
fi

# ── Get latest release tag ───────────────────────────────────────────────────
info "Fetching latest release..."

LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [[ -z "$LATEST_TAG" ]]; then
  error "Could not determine latest release. Installing from main branch."
  LATEST_TAG="main"
fi

info "Installing devpurge ${LATEST_TAG}..."

# ── Download and extract ─────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR" ]]; then
  info "Removing previous installation..."
  rm -rf "$INSTALL_DIR"
fi

mkdir -p "$INSTALL_DIR"

if [[ "$LATEST_TAG" == "main" ]]; then
  ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/main.tar.gz"
else
  ARCHIVE_URL="https://github.com/${REPO}/archive/refs/tags/${LATEST_TAG}.tar.gz"
fi

curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1

chmod +x "${INSTALL_DIR}/bin/devpurge"

# ── Create symlink ───────────────────────────────────────────────────────────
if [[ -L "$BIN_LINK" ]]; then
  rm "$BIN_LINK"
fi

if ln -sf "${INSTALL_DIR}/bin/devpurge" "$BIN_LINK" 2>/dev/null; then
  success "Linked devpurge to ${BIN_LINK}"
else
  info "Could not create symlink at ${BIN_LINK} (may need sudo)."
  info "Adding ${INSTALL_DIR}/bin to your PATH instead."

  SHELL_RC=""
  if [[ -f "${HOME}/.zshrc" ]]; then
    SHELL_RC="${HOME}/.zshrc"
  elif [[ -f "${HOME}/.bashrc" ]]; then
    SHELL_RC="${HOME}/.bashrc"
  elif [[ -f "${HOME}/.bash_profile" ]]; then
    SHELL_RC="${HOME}/.bash_profile"
  fi

  if [[ -n "$SHELL_RC" ]]; then
    if ! grep -q 'devpurge' "$SHELL_RC" 2>/dev/null; then
      printf '\n# devpurge\nexport PATH="${HOME}/.devpurge/bin:${PATH}"\n' >> "$SHELL_RC"
      info "Added to ${SHELL_RC}. Restart your shell or run: source ${SHELL_RC}"
    fi
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
printf "\n"
success "devpurge ${LATEST_TAG} installed successfully!"
printf "\n"
info "Run 'devpurge --help' to get started."
info "Run 'devpurge -n' for a dry run (scan only)."
printf "\n"
