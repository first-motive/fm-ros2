#!/usr/bin/env bash
# Native run path for the fm_ros2 stack, dispatched from ./run.sh on a native
# profile. Builds the workspace on the host inside the pixi env (RoboStack), then
# opens the fm_tui launcher natively — no container, no VNC. rviz2 renders through
# its native RoboStack build; foxglove opens the host Studio app against the
# in-env bridge.
#
# The env is provisioned by install.sh --native (scripts/install/native.sh). This
# path assumes it exists; it fails with a pointer when pixi is missing.
#
# Wrapped in main() and called on the last line so a truncated pipe never half-runs.
set -euo pipefail

# Reach the repo root — this script lives two levels down in scripts/run/.
cd "$(dirname "$0")/../.."

usage() {
  cat <<'EOF'
native.sh — build + launch the fm_ros2 stack natively via pixi (macOS / Windows)

Usage: ./scripts/run/native.sh [--no-foxglove] [-h]

  --no-foxglove   skip auto-opening Foxglove Studio
  -h, --help      show this help

Reads the viewer from .fm_ros2.json (foxglove|rviz|none); defaults to foxglove.
EOF
}

# Ensure pixi is on PATH — the native env must already be provisioned. Point at the
# installer rather than bootstrapping here: run is not the place to install.
ensure_pixi() {
  command -v pixi >/dev/null 2>&1 && return
  if [ -x "$HOME/.pixi/bin/pixi" ]; then
    export PATH="$HOME/.pixi/bin:$PATH"
    return
  fi
  echo "error: pixi not found — provision the native env first:" >&2
  echo "       ./install.sh --native" >&2
  exit 1
}

main() {
  local open_foxglove=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-foxglove) open_foxglove=false; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
    esac
  done

  ensure_pixi

  # Read the persisted viewer (foxglove|rviz|none); default foxglove. Same shape as
  # the container path reads it from the /ws mount.
  local viewer=foxglove
  if [[ -f .fm_ros2.json ]]; then
    viewer=$(sed -n 's/.*"viewer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      .fm_ros2.json | head -1)
    viewer=${viewer:-foxglove}
  fi

  # Carry the host OS + native marker into the launcher. FM_NATIVE lets fm_tui know
  # rviz can render natively here (no VNC, unlike the macOS container path).
  case "$(uname -s)" in
    Darwin) export FM_HOST_OS=macos ;;
    *) export FM_HOST_OS=linux ;;
  esac
  export FM_NATIVE=1
  # The launcher persists its viewer preference next to the profile at the root.
  export FM_TUI_CONFIG="$PWD/.fm_tui.json"

  # CI self-test hook: env resolved — stop before the pixi build or launch. Lets the
  # smoke test exercise dispatch + profile read without a real workspace build.
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: native run resolved (viewer=$viewer, host=$FM_HOST_OS)"
    return 0
  fi

  # Use the pixi `build` task, not an inline colcon call — the task carries the
  # FindPython cmake args that let interface packages (unitree_api and friends)
  # build on osx-arm64. An inline build would hit the FindPython failure that
  # aborts the whole workspace.
  echo "==> building the workspace natively (pixi run build) ..."
  pixi run build

  # Open Foxglove Studio when the viewer is foxglove — the in-env bridge binds
  # 8765 on the host, so Studio connects directly (no container port publish).
  # Best-effort, macOS GUI only; never blocks the launcher.
  if [[ "$viewer" == foxglove && "$open_foxglove" == true ]]; then
    if [[ "$FM_HOST_OS" == macos ]] && command -v open >/dev/null 2>&1; then
      if [[ -d "/Applications/Foxglove.app" ]]; then
        open "foxglove://open?ds=foxglove-websocket&ds.url=ws://localhost:8765" 2>/dev/null || true
        echo "==> Foxglove Studio: connects when a view starts (ws://localhost:8765)"
      else
        echo "==> Foxglove Studio not installed — ./install.sh --native --viewer foxglove"
      fi
    fi
  fi

  # Launch the fm_tui launcher inside the pixi env with the workspace overlay
  # sourced. `pixi run` activates ROS; layer install/setup.bash on top, then exec
  # the console script via `ros2 run` (it installs under lib/, not on PATH).
  echo "==> opening the fm_tui launcher (native) ..."
  exec pixi run bash -c \
    'source install/setup.bash && exec ros2 run fm_tui fm_tui_launcher'
}

main "$@"
