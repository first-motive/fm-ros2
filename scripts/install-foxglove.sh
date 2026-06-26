#!/usr/bin/env bash
# Ensure Foxglove Studio is installed on macOS. Idempotent: a no-op when the app
# is already present. Installs via the Homebrew cask when missing; if Homebrew is
# absent it points at the manual download.
#
# Foxglove Studio is the macOS robot viewer — run.sh auto-opens it pre-connected
# to the foxglove_bridge. It is a viewer, not required infrastructure (unlike
# OrbStack), so every failure here warns and returns 0: the stack still builds
# and runs without it, and run.sh prints the same install hint if the app is
# missing. On Linux the viewer path is RViz inside the container, so this skips.
set -euo pipefail

usage() {
  cat <<'EOF'
install-foxglove.sh — ensure Foxglove Studio is installed on macOS (idempotent)

Installs via the Homebrew cask when missing; warns and returns 0 on any
failure (the viewer is optional). No-op off macOS.

Usage: ./scripts/install-foxglove.sh [-h]

  -h, --help   show this help
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  if [ "$(uname -s)" != "Darwin" ]; then
    return 0
  fi

  if [ -d "/Applications/Foxglove.app" ]; then
    echo "Foxglove Studio already installed"
    return 0
  fi

  echo "Foxglove Studio not found, installing..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "WARNING: Homebrew not found — skipping Foxglove Studio." >&2
    echo "         Install it (https://brew.sh), then: brew install --cask foxglove" >&2
    echo "         Or download manually: https://foxglove.dev/download" >&2
    return 0
  fi

  if brew install --cask foxglove; then
    echo "Foxglove Studio installed"
  else
    echo "WARNING: Foxglove Studio install failed — continuing without it." >&2
    echo "         Retry later: brew install --cask foxglove" >&2
  fi

  # Best-effort viewer: succeed regardless of the install outcome so the bootstrap
  # never aborts on a missing or failed Foxglove install.
  return 0
}

main "$@"
