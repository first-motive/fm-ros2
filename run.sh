#!/usr/bin/env bash
# Single front door for the fm_ros2 stack. Brings the dev container up and opens
# the fm_tui launcher — an arrow-key menu that walks action -> robot -> variant
# (-> backend for sim/teleop) and dispatches the launch. Wired actions: robot
# description, simulation, and teleop; autonomous is stubbed.
#
# It auto-detects the host OS to pick the compose overlay (macOS / Linux) and
# reuses the shared-stack pattern from scripts/view-robot.sh: `up -d`, build the
# workspace, then `exec` the launcher through the image entrypoint so ROS + the
# workspace overlay are sourced.
#
#   ./run.sh                  # auto-detect overlay, build, open the launcher
#   ./run.sh --linux          # force the Linux overlay (GPU / hardware)
#   ./run.sh --macos          # force the macOS overlay (OrbStack, sim only)
#   ./run.sh --no-foxglove    # skip auto-opening Foxglove Studio (macOS)
#
# Every run rebuilds the workspace (colcon) before opening the launcher, so source
# and console-script changes are always picked up. The build is incremental, so a
# warm tree is quick. The package repos and externals are imported first, once:
#   vcs import src < fm-ros2.repos   # pull the seven package repos into src/
#   ./scripts/import-externals.sh    # vendor robot sources into external/
#
# scripts/view-robot.sh, scripts/sim.sh, and scripts/teleop.sh coexist as the
# direct, scriptable paths to the same launches — use them when you want one
# capability without the menu.
set -euo pipefail

cd "$(dirname "$0")"

# Step narration lives in fm_tui (fm_tui/banner.py) so run.sh and the TUI share
# one source of brand colour. `step` draws a numbered header block as a rich rule;
# `item` prints a plain status line beneath it. The first steps run on the host
# before the container exists, so reach rich through `uv run --with rich`. Fall
# back to a plain header when uv or the module is absent (e.g. before `vcs import`).
BANNER=src/fm-app/fm_tui/fm_tui/banner.py
STEP=0
step() {  # title  [role]
  STEP=$((STEP + 1))
  if [[ -f "$BANNER" ]] && command -v uv >/dev/null 2>&1; then
    uv run --quiet --no-project --with rich python3 "$BANNER" "$STEP" "$1" "${2:-step}"
  else
    echo "== $STEP. $1 =="
  fi
}
item() { echo "$1"; }  # status line under a step — one place to restyle later

OVERLAY=""
OPEN_FOXGLOVE=true  # auto-open Foxglove Studio on macOS; --no-foxglove disables

while [[ $# -gt 0 ]]; do
  case "$1" in
    --macos)
      OVERLAY=docker/compose.macos.yaml
      shift
      ;;
    --linux)
      OVERLAY=docker/compose.linux.yaml
      shift
      ;;
    --no-foxglove)
      OPEN_FOXGLOVE=false
      shift
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      echo "usage: ./run.sh [--macos|--linux] [--no-foxglove]" >&2
      exit 1
      ;;
  esac
done

# Auto-detect the overlay from the host OS when not forced by a flag.
if [[ -z "$OVERLAY" ]]; then
  case "$(uname -s)" in
    Darwin)
      OVERLAY=docker/compose.macos.yaml
      ;;
    Linux)
      OVERLAY=docker/compose.linux.yaml
      ;;
    *)
      echo "error: unsupported host OS '$(uname -s)' — pass --macos or --linux" >&2
      exit 1
      ;;
  esac
fi

# Friendly host label, derived from whichever overlay won (flag or auto-detect).
case "$OVERLAY" in
  *macos*) HOST="macOS" ;;
  *linux*) HOST="Linux" ;;
esac

step "Detect OS"
item "${HOST} detected"

COMPOSE=(docker compose -f docker/compose.yaml -f "$OVERLAY")
SERVICE=fm_ros2

# macOS runs on OrbStack as the Docker provider. Install it if missing, then make
# sure the daemon is up — both idempotent, and each prints its own status bullet.
step "${HOST} Container"
if [[ "$OVERLAY" == docker/compose.macos.yaml ]]; then
  ./scripts/install-orbstack.sh
  ./scripts/ensure-docker.sh
fi
"${COMPOSE[@]}" up -d
item "Container up"

step "Build Workspace"
# Route through the entrypoint so ROS is sourced; build from /ws (the compose
# working_dir). Incremental, so a warm tree returns fast.
"${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh colcon build --symlink-install

# Open Foxglove Studio on the host, pre-connected to the bridge. The bridge runs
# inside the container once a view is selected in the launcher, so Studio shows
# "waiting" until then and connects when it appears. macOS GUI path only — skipped
# on Linux/CI/headless and with --no-foxglove. If the app is absent, point at the
# installer rather than fail; the launcher still runs and the URL above stands.
open_foxglove() {
  [[ "$OPEN_FOXGLOVE" == true ]] || return 0
  [[ "$OVERLAY" == docker/compose.macos.yaml ]] || return 0
  command -v open >/dev/null 2>&1 || return 0
  if [[ ! -d "/Applications/Foxglove.app" ]]; then
    item "Foxglove Studio not installed — run ./install.sh or: brew install --cask foxglove"
    return 0
  fi
  # Branch on `open` (not a bare call) so a non-zero exit never trips set -e and
  # aborts the launcher — auto-opening the viewer is best-effort, not a gate.
  local url="foxglove://open?ds=foxglove-websocket&ds.url=ws://localhost:8765"
  if open "$url" 2>/dev/null; then
    item "Foxglove Studio: opening"
  else
    item "Foxglove Studio: open failed — connect manually to ws://localhost:8765"
  fi
}

step "Launcher"
item "Foxglove Studio: ws://localhost:8765"
item "teardown: ${COMPOSE[*]} down"
open_foxglove
# `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
# The launcher is an ament_python console_script (installed under lib/fm_tui/, not
# on PATH), so reach it via `ros2 run`, not by name.
exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh ros2 run fm_tui fm_tui_launcher
