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

OVERLAY=""

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
    *)
      echo "error: unknown argument '$1'" >&2
      echo "usage: ./run.sh [--macos|--linux]" >&2
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

cd "$(dirname "$0")"

COMPOSE=(docker compose -f docker/compose.yaml -f "$OVERLAY")
SERVICE=fm_ros2

# Step narration lives in fm_tui (fm_tui/banner.py) so run.sh and the TUI share
# one source of brand colour. It is pure-stdlib ANSI, so the host python3 renders
# it without ROS or the container — needed because the first steps run before the
# container exists. Fall back to a plain line when python3 or the module is
# absent (e.g. before `vcs import`).
BANNER=src/fm-app/fm_tui/fm_tui/banner.py
banner() {
  if [[ -f "$BANNER" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$BANNER" "$1" "${2:-step}"
  else
    echo ">> $1"
  fi
}

# macOS runs on OrbStack as the Docker provider. Install it if missing, then make
# sure the daemon is up — both steps are idempotent no-ops once satisfied.
if [[ "$OVERLAY" == docker/compose.macos.yaml ]]; then
  banner "ensuring OrbStack is installed and running"
  ./scripts/install-orbstack.sh
  ./scripts/ensure-docker.sh
fi

banner "bringing container up (idempotent), overlay: $OVERLAY"
"${COMPOSE[@]}" up -d
banner "building workspace (colcon, incremental) — picks up source changes"
# Route through the entrypoint so ROS is sourced; build from /ws (the compose
# working_dir). Incremental, so a warm tree returns fast.
"${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh colcon build --symlink-install
banner "opening fm_tui launcher — pick action -> robot -> variant (-> backend)"
banner "Foxglove Studio: connect to ws://localhost:8765" info
banner "tear down with: ${COMPOSE[*]} down" info
# `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
# The launcher is an ament_python console_script (installed under lib/fm_tui/, not
# on PATH), so reach it via `ros2 run`, not by name.
exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh ros2 run fm_tui fm_tui_launcher
