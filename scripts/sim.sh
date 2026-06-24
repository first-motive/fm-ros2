#!/usr/bin/env bash
# Launch a robot in a ros2_control simulation backend. One control stack across
# three robots (--robot openarm | so101 | g1_d), the sim backend selectable with
# --backend; the compose overlay follows from it:
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
#   ./scripts/sim.sh --robot so101 --backend mock          # SO101, no sim
#   ./scripts/sim.sh --robot g1_d --backend mujoco         # G1-D right arm in mujoco
#   ./scripts/sim.sh --variant default_bimanual            # both OpenArm arms
#   ./scripts/sim.sh --backend gazebo                      # Linux/GPU overlay
#   ./scripts/sim.sh --backend isaac                       # Isaac over ROS topics
#
# Notes: the G1-D simulates its right arm only (the rest of the body holds);
# its mujoco model is the bipedal g1_29dof (arm joints match, wired-not-validated).
# G1-D has no `real` sim backend — the real arm runs through the arm_sdk bridge,
# not a controller_manager (see scripts/teleop.sh + src/fm_control).
#
# --robot/--backend accept hyphen or underscore form. Extra args pass straight
# through to `ros2 launch`.
set -euo pipefail

ROBOT=openarm
VARIANT=""
BACKEND=mujoco
TASK_ENV=default
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --robot) ROBOT="$2"; shift 2 ;;
    --robot=*) ROBOT="${1#--robot=}"; shift ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --variant=*) VARIANT="${1#--variant=}"; shift ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --backend=*) BACKEND="${1#--backend=}"; shift ;;
    --task-env) TASK_ENV="$2"; shift 2 ;;
    --task-env=*) TASK_ENV="${1#--task-env=}"; shift ;;
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

# On macOS the MuJoCo path depends on OrbStack/Docker being up first.
if [[ "$(uname -s)" == "Darwin" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found. Install OrbStack: https://orbstack.dev" >&2
    exit 1
  fi
  ./scripts/ensure-docker.sh
fi

COMPOSE=(docker compose -f docker/compose.yaml -f "$OVERLAY")
SERVICE=fm_ros2

LAUNCH=(ros2 launch fm_bringup sim.launch.py \
  "robot:=$ROBOT" "sim_backend:=$BACKEND" "task_env:=$TASK_ENV")
[[ -n "$VARIANT" ]] && LAUNCH+=("variant:=$VARIANT")
LAUNCH+=(${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"})

echo ">> $BACKEND backend — overlay $(basename "$OVERLAY")"
if [[ "$TASK_ENV" != "default" ]]; then
  echo ">> task environment: $TASK_ENV"
fi
echo ">> shared stack — bringing container up (idempotent)"
"${COMPOSE[@]}" up -d
echo ">> launching $ROBOT sim — Ctrl-C stops it, stack stays up"
echo ">> Foxglove Studio: connect to ws://localhost:8765"
echo ">> tear down with: ${COMPOSE[*]} down"
# `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh "${LAUNCH[@]}"
