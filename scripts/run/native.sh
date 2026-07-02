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

# Step narration lives in the shared fm-tools wheel (fm_tools.tui.banner) so this
# path, run.sh, and install.sh share one source of brand colour. Same pattern as
# scripts/run/container.sh — keep the pin in sync.
FM_TOOLS="fm-tools @ git+https://github.com/first-motive/fm-tools@v0.2.0"

STEP=0
step() {  # title  [role]
  STEP=$((STEP + 1))
  if command -v uv >/dev/null 2>&1; then
    # -W ignore::RuntimeWarning silences runpy's harmless "already in sys.modules"
    # note: fm_tools.tui re-exports banner, so `-m` sees it pre-imported.
    uv run --quiet --no-project --with "$FM_TOOLS" \
      python3 -W ignore::RuntimeWarning -m fm_tools.tui.banner "$STEP" "$1" "${2:-step}"
  else
    echo "== $STEP. $1 =="
  fi
}
item() { echo "$1"; }  # status line under a step — one place to restyle later

usage() {
  cat <<'EOF'
native.sh — build + launch the fm_ros2 stack natively via pixi (macOS / Windows)

Usage: ./scripts/run/native.sh [--no-foxglove] [-h]

  --no-foxglove   skip auto-opening Foxglove Studio
  -h, --help      show this help

Viewer preference: .fm_tui.json (launcher V-toggle) wins, then the install
profile (.fm_ros2.json), then foxglove.
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

# Read the "viewer" key from a JSON file; empty when absent.
read_viewer() {  # file
  [ -f "$1" ] || return 0
  sed -n 's/.*"viewer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

# Open Foxglove Studio once a foxglove view is actually launched from the TUI —
# not while the menu is still open. The bridge binds 8765 only when a view starts,
# so poll the port and open Studio (pre-connected) the moment it binds. The V-toggle
# can flip either way inside the TUI after this forks, so the watcher runs whatever
# the startup viewer was and re-reads the toggle each pass: rviz now means keep
# waiting (a later flip to foxglove still opens Studio), foxglove now + port bound
# means open. Forked before the launcher exec so it outlives this shell, bounded so
# a quit leaves nothing polling. macOS GUI path only; never blocks the launcher.
# Reads $viewer from main (dynamic scope) as the fallback when no toggle file exists.
open_foxglove_when_ready() {
  command -v open >/dev/null 2>&1 || return 0
  if [[ ! -d "/Applications/Foxglove.app" ]]; then
    item "Foxglove Studio not installed — run ./install.sh or: brew install --cask foxglove"
    return 0
  fi
  local url="foxglove://open?ds=foxglove-websocket&ds.url=ws://localhost:8765"
  (
    # ~10 min budget (300 × 2s) — enough to navigate the menu and launch, then
    # give up so a quit without launching never leaves this polling forever.
    local now
    for ((i = 0; i < 300; i++)); do
      now="$(read_viewer .fm_tui.json)"
      now="${now:-$viewer}"
      if [[ "$now" == foxglove ]] \
        && bash -c 'exec 3<>/dev/tcp/127.0.0.1/8765' 2>/dev/null; then
        open "$url" 2>/dev/null || true
        exit 0
      fi
      sleep 2
    done
  ) &
  disown 2>/dev/null || true
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

  # Resolve the viewer: the launcher's persisted V-toggle (.fm_tui.json) is the
  # most recent user intent, so it wins over the install profile (.fm_ros2.json);
  # default foxglove. Same file the container path reads on the /ws mount.
  local viewer
  viewer="$(read_viewer .fm_tui.json)"
  [[ -z "$viewer" ]] && viewer="$(read_viewer .fm_ros2.json)"
  viewer="${viewer:-foxglove}"

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

  step "Detect OS"
  item "${FM_HOST_OS} detected (native)"

  step "Build Workspace"
  # Use the pixi `build` task, not an inline colcon call — the task carries the
  # FindPython cmake args that let interface packages (unitree_api and friends)
  # build on osx-arm64. An inline build would hit the FindPython failure that
  # aborts the whole workspace. Incremental, so a warm tree returns fast.
  pixi run build

  step "Launcher"
  # Fork the watcher whatever the startup viewer is — the V-toggle can flip to
  # foxglove inside the TUI, and Studio must still auto-open then. The watcher
  # itself is toggle-aware (opens only while foxglove is the current choice), so
  # an rviz session that never flips costs one silent bounded poll and nothing else.
  if [[ "$open_foxglove" == true && "$FM_HOST_OS" == macos ]]; then
    open_foxglove_when_ready
  fi
  if [[ "$viewer" == foxglove ]]; then
    item "Foxglove Studio: opens when a view starts (ws://localhost:8765)"
  else
    item "viewer: $viewer (V toggles in the launcher; foxglove still opens on a flip)"
  fi

  # Launch the fm_tui launcher inside the pixi env with the workspace overlay
  # sourced. `pixi run` activates ROS; layer install/setup.bash on top, then exec
  # the console script via `ros2 run` (it installs under lib/, not on PATH).
  exec pixi run bash -c \
    'source install/setup.bash && exec ros2 run fm_tui fm_tui_launcher'
}

main "$@"
