#!/usr/bin/env bash
# Launch the Enactic OpenArm URDF view in the macOS dev container so Foxglove
# Studio on the host can render it at ws://localhost:8765.
#
# Unlike the G1, OpenArm ships as a real built ament_cmake package. It must be
# BUILT into the workspace (not just vendored) before this view will run.
#
# Prerequisites (run once, or after changing externals / sources):
#   ./scripts/import-externals.sh    # imports openarm_description (no COLCON_IGNORE)
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm_ros2 colcon build --symlink-install
#
# Then:
#   ./scripts/view-openarm.sh                       # right_arm (default)
#   ./scripts/view-openarm.sh arm_type:=left_arm
#   ./scripts/view-openarm.sh arm_type:=default_bimanual
#   ./scripts/view-openarm.sh use_rviz:=true        # needs an X display
#
# Any extra args are passed straight through to `ros2 launch`.
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker/compose.yaml -f docker/compose.macos.yaml)
SERVICE=fm_ros2

LAUNCH=(ros2 launch fm_description view_openarm.launch.py "$@")

echo ">> shared stack — bringing container up (idempotent)"
"${COMPOSE[@]}" up -d
echo ">> launching OpenArm view — Ctrl-C stops it, stack stays up"
echo ">> Foxglove Studio: connect to ws://localhost:8765"
echo ">> tear down with: ${COMPOSE[*]} down"
# `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh "${LAUNCH[@]}"
