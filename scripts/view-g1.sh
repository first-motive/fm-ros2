#!/usr/bin/env bash
# Launch the Unitree G1 URDF view in the macOS dev container so Foxglove Studio
# on the host can render it at ws://localhost:8765.
#
# Prerequisites (run once, or after changing externals / sources):
#   ./scripts/import-externals.sh    # clone unitree_ros into src/external/
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm_ros2 colcon build --symlink-install
#
# Then:
#   ./scripts/view-g1.sh                         # default 29dof, no hands
#   ./scripts/view-g1.sh variant:=g1_29dof_rev_1_0_with_inspire_hand_FTP
#   ./scripts/view-g1.sh use_rviz:=true          # needs an X display
#
# Any extra args are passed straight through to `ros2 launch`.
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker/compose.yaml -f docker/compose.macos.yaml)
SERVICE=fm_ros2

LAUNCH=(ros2 launch fm_description view_g1.launch.py "$@")

echo ">> shared stack — bringing container up (idempotent)"
"${COMPOSE[@]}" up -d
echo ">> launching G1 view — Ctrl-C stops it, stack stays up"
echo ">> Foxglove Studio: connect to ws://localhost:8765"
echo ">> tear down with: ${COMPOSE[*]} down"
# `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh "${LAUNCH[@]}"
