#!/usr/bin/env bash
# Launch the OpenArm in a ros2_control simulation backend. One control stack, the
# sim backend selectable with --backend; the compose overlay follows from it:
#
#   mock, mujoco   -> compose.macos   (Mac daily driver, CPU)
#   gazebo, isaac  -> compose.linux   (Linux/GPU)
#
# Foxglove Studio on the host renders it at ws://localhost:8765.
#
# Prerequisites (run once, or after changing externals / sources):
#   ./scripts/import-externals.sh
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm_ros2 colcon build --symlink-install
#
# Then:
#   ./scripts/sim.sh                                       # openarm right_arm, mujoco
#   ./scripts/sim.sh --backend mock                        # no sim; perfect state echo
#   ./scripts/sim.sh --variant default_bimanual            # both arms in mujoco
#   ./scripts/sim.sh --backend gazebo                      # Linux/GPU overlay
#   ./scripts/sim.sh --backend isaac                       # Isaac over ROS topics
#
# --robot/--backend accept hyphen or underscore form. Extra args pass straight
# through to `ros2 launch`.
set -euo pipefail

ROBOT=openarm
VARIANT=""
BACKEND=mujoco
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --robot) ROBOT="$2"; shift 2 ;;
    --robot=*) ROBOT="${1#--robot=}"; shift ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --variant=*) VARIANT="${1#--variant=}"; shift ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --backend=*) BACKEND="${1#--backend=}"; shift ;;
    *) PASSTHROUGH+=("$1"); shift ;;
  esac
done

# Normalize hyphen -> underscore (default-bimanual -> default_bimanual).
ROBOT="${ROBOT//-/_}"
BACKEND="${BACKEND//-/_}"

VALID_BACKENDS=(mock mujoco gazebo isaac real)
ok=false
for b in "${VALID_BACKENDS[@]}"; do
  [[ "$BACKEND" == "$b" ]] && ok=true && break
done
if [[ "$ok" != true ]]; then
  echo "error: unknown backend '$BACKEND'" >&2
  echo "valid backends: ${VALID_BACKENDS[*]}" >&2
  exit 1
fi

# Backend picks the compose overlay: CPU sim on macOS, GPU sim on Linux.
case "$BACKEND" in
  mock|mujoco) OVERLAY=docker/compose.macos.yaml ;;
  gazebo|isaac|real) OVERLAY=docker/compose.linux.yaml ;;
esac

cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker/compose.yaml -f "$OVERLAY")
SERVICE=fm_ros2

LAUNCH=(ros2 launch fm_bringup sim.launch.py \
  "robot:=$ROBOT" "sim_backend:=$BACKEND")
[[ -n "$VARIANT" ]] && LAUNCH+=("variant:=$VARIANT")
LAUNCH+=(${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"})

echo ">> $BACKEND backend — overlay $(basename "$OVERLAY")"
echo ">> shared stack — bringing container up (idempotent)"
"${COMPOSE[@]}" up -d
echo ">> launching $ROBOT sim — Ctrl-C stops it, stack stays up"
echo ">> Foxglove Studio: connect to ws://localhost:8765"
echo ">> tear down with: ${COMPOSE[*]} down"
# `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh "${LAUNCH[@]}"
