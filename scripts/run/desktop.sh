#!/usr/bin/env bash
# App run path for the fm_ros2 stack — launch First Motive, the native macOS app,
# dispatched from ./run.sh --desktop.
#
# Launch only. This opens the installed app at /Applications/First Motive.app; it
# does not build or install. First Motive is installed separately — team members
# get it from ./install.sh (the team-extras step), or straight from the fm-desktop
# repo's own install.sh. Building from source lives there too (install.sh --source),
# not here: run launches, install installs.
#
# macOS only: First Motive is a SwiftUI/AppKit app.
#
# Wrapped in main() and called on the last line so a truncated pipe never half-runs.
set -euo pipefail

APP="/Applications/First Motive.app"

usage() {
  cat <<'EOF'
desktop.sh — launch First Motive, the native macOS app (dispatched by run.sh --desktop)

Usage: ./scripts/run/desktop.sh [-h]

Opens the installed app at /Applications/First Motive.app. Launch only — it does
not build or install. Install First Motive first: ./install.sh (team members), or
the fm-desktop repo's own install.sh. macOS only.
EOF
}

main() {
  case "${1:-}" in -h | --help) usage; return 0 ;; esac

  if [ "$(uname -s)" != Darwin ]; then
    echo "error: First Motive is a macOS app — --desktop is macOS only." >&2
    echo "       Use ./run.sh (native/container) for the terminal launcher." >&2
    return 1
  fi

  # CI self-test hook: resolved the launch target over the curl|bash pipe, without
  # opening anything. Mirrors run.sh's selftest.
  if [ -n "${FM_SELFTEST:-}" ]; then
    echo "selftest ok: run.sh --desktop resolved (app=$APP)"
    return 0
  fi

  # Launch only — never install from a run path. Point at the installer when the
  # app is missing rather than silently building it.
  if [ ! -d "$APP" ]; then
    echo "error: First Motive is not installed ($APP not found)." >&2
    echo "       Install it first (macOS):" >&2
    echo "         ./install.sh          # from this workspace — installs the team stack incl. the app" >&2
    echo "       or straight from the app repo:" >&2
    echo "         gh api repos/first-motive/fm-desktop/contents/install.sh --jq .content | base64 --decode | bash" >&2
    return 1
  fi

  echo "==> Launching First Motive"
  open "$APP"
  echo "First Motive launched — it adopts this workspace ($PWD)."
}

main "$@"
