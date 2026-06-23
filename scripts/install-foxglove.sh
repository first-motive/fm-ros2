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

if [ "$(uname -s)" != "Darwin" ]; then
  exit 0
fi

if [ -d "/Applications/Foxglove.app" ]; then
  echo "Foxglove Studio already installed"
  exit 0
fi

echo "Foxglove Studio not found, installing..."
if ! command -v brew >/dev/null 2>&1; then
  echo "WARNING: Homebrew not found — skipping Foxglove Studio." >&2
  echo "         Install it (https://brew.sh), then: brew install --cask foxglove" >&2
  echo "         Or download manually: https://foxglove.dev/download" >&2
  exit 0
fi

if brew install --cask foxglove; then
  echo "Foxglove Studio installed"
else
  echo "WARNING: Foxglove Studio install failed — continuing without it." >&2
  echo "         Retry later: brew install --cask foxglove" >&2
fi

# Best-effort viewer: succeed regardless of the install outcome so the bootstrap
# never aborts on a missing or failed Foxglove install.
exit 0
