#!/usr/bin/env bash
# Ensure OrbStack is installed on macOS. Idempotent: a no-op when OrbStack is
# already present. Installs via Homebrew when missing; if Homebrew is absent it
# points at the manual download rather than guessing at a silent .dmg install.
#
# Pairs with scripts/ensure-docker.sh: this guarantees OrbStack exists, that one
# guarantees the daemon is running. run.sh calls both on the macOS path.
set -euo pipefail

# Already installed? Nothing to do. Check the CLI first, then fall back to the app
# bundle — a fresh cask install lands the .app before `orb` reaches the PATH.
if command -v orb >/dev/null 2>&1 || [ -d "/Applications/OrbStack.app" ]; then
  echo "    OrbStack already installed."
  exit 0
fi

echo "    OrbStack not found — installing..."
if command -v brew >/dev/null 2>&1; then
  brew install --cask orbstack
  echo "    OrbStack installed."
else
  echo "ERROR: Homebrew not found. Install it (https://brew.sh) and re-run, or" >&2
  echo "       install OrbStack manually: https://orbstack.dev" >&2
  exit 1
fi
