#!/usr/bin/env bash
# App run path for the fm_ros2 stack — build and launch First Motive, the native
# macOS app, dispatched from ./run.sh --app.
#
# First Motive lives in its own repo (first-motive/fm-desktop), deliberately outside
# this workspace's .repos manifests. This path finds that checkout (or clones it),
# builds the .app bundle from source, and opens it. A locally built app carries no
# Gatekeeper quarantine, so it runs unsigned — no Developer ID needed for the team
# that already clones this repo. The app then adopts this workspace at ~/fm_ros2.
#
# macOS only: the app is SwiftUI/AppKit and needs the Swift toolchain.
#
# Wrapped in main() and called on the last line so a truncated pipe never half-runs.
set -euo pipefail

# Reach the repo root — this script lives two levels down in scripts/run/.
cd "$(dirname "$0")/../.."
WORKSPACE="$PWD"

usage() {
  cat <<'EOF'
app.sh — build + launch First Motive, the native macOS app (dispatched by run.sh --app)

Usage: ./scripts/run/app.sh [-h]

Finds the fm-desktop checkout (or clones it), builds the .app from source, and
opens it. Locally built means no Gatekeeper quarantine — the app runs unsigned.

The checkout is resolved as: $FM_DESKTOP_DIR, else a sibling ../fm-desktop, else
~/fm-desktop; if none exists it is cloned into ~/fm-desktop. macOS only.
EOF
}

# Where First Motive's checkout lives: an explicit override, a sibling of this repo,
# ~/fm-desktop, else a clone target of ~/fm-desktop.
resolve_desktop_dir() {
  if [ -n "${FM_DESKTOP_DIR:-}" ]; then echo "$FM_DESKTOP_DIR"; return; fi
  local candidate
  for candidate in "$WORKSPACE/../fm-desktop" "$HOME/fm-desktop"; do
    if [ -d "$candidate/.git" ]; then echo "$candidate"; return; fi
  done
  echo "$HOME/fm-desktop"
}

main() {
  case "${1:-}" in -h | --help) usage; return 0 ;; esac

  if [ "$(uname -s)" != Darwin ]; then
    echo "error: First Motive is a macOS app — --app is macOS only." >&2
    echo "       Use ./run.sh (native/container) for the terminal launcher." >&2
    return 1
  fi
  if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift not found — install the Xcode Command Line Tools:" >&2
    echo "       xcode-select --install" >&2
    return 1
  fi

  local dir; dir="$(resolve_desktop_dir)"

  # CI self-test hook: resolved the toolchain + app checkout path over the
  # curl|bash pipe, without cloning or building. Mirrors run.sh's selftest.
  if [ -n "${FM_SELFTEST:-}" ]; then
    echo "selftest ok: run.sh --app resolved (desktop=$dir)"
    return 0
  fi

  if [ ! -d "$dir/.git" ]; then
    echo "==> Cloning fm-desktop into $dir"
    git clone https://github.com/first-motive/fm-desktop.git "$dir"
  fi

  echo "==> Building First Motive from $dir (first build takes ~30s)"
  "$dir/scripts/package-app.sh" >/dev/null

  local app="$dir/dist/First Motive.app"
  echo "==> Launching $app"
  open "$app"
  echo "First Motive launched — it adopts this workspace ($WORKSPACE)."
}

main "$@"
