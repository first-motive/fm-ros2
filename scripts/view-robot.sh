#!/usr/bin/env bash
# Launch a robot URDF view in the macOS dev container so Foxglove Studio on the
# host can render it at ws://localhost:8765. One entry point for every robot;
# pick one with --robot (default g1_d).
#
# Prerequisites (run once, or after changing externals / sources):
#   ./scripts/import-externals.sh    # clone/import robot sources into src/external/
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm_ros2 colcon build --symlink-install
#
# Then:
#   ./scripts/view-robot.sh                                  # g1_d wheeled G1-D (default)
#   ./scripts/view-robot.sh --robot g1_d --variant g1_29dof_rev_1_0   # bipedal body
#   ./scripts/view-robot.sh --robot so101
#   ./scripts/view-robot.sh --robot openarm                  # right_arm
#   ./scripts/view-robot.sh --robot openarm --variant left_arm
#   ./scripts/view-robot.sh --robot openarm --variant default_bimanual
#   ./scripts/view-robot.sh use_rviz:=true                   # needs an X display
#
# --robot accepts hyphen or underscore form (g1-d == g1_d). Any extra args are
# passed straight through to `ros2 launch`.
set -euo pipefail

ROBOT=g1_d
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --robot)
      ROBOT="$2"
      shift 2
      ;;
    --robot=*)
      ROBOT="${1#--robot=}"
      shift
      ;;
    *)
      PASSTHROUGH+=("$1")
      shift
      ;;
  esac
done

# Normalize hyphen -> underscore (g1-d -> g1_d).
ROBOT="${ROBOT//-/_}"

VALID_ROBOTS=(g1_d so101 openarm)
ok=false
for r in "${VALID_ROBOTS[@]}"; do
  [[ "$ROBOT" == "$r" ]] && ok=true && break
done
if [[ "$ok" != true ]]; then
  echo "error: unknown robot '$ROBOT'" >&2
  echo "valid robots: ${VALID_ROBOTS[*]}" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker/compose.yaml -f docker/compose.macos.yaml)
SERVICE=fm_ros2

LAUNCH=(ros2 launch fm_description view_robot.launch.py "robot:=$ROBOT" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"})

echo ">> shared stack — bringing container up (idempotent)"
"${COMPOSE[@]}" up -d
echo ">> launching $ROBOT view — Ctrl-C stops it, stack stays up"
echo ">> Foxglove Studio: connect to ws://localhost:8765"
echo ">> tear down with: ${COMPOSE[*]} down"
# `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh "${LAUNCH[@]}"
