#!/usr/bin/env bash
# Jog the OpenArm interactively through MoveIt Servo. Brings up Servo plus the
# selected teleop input against a sim (or real) target. The compose overlay follows
# from --backend, same mapping as sim.sh:
#
#   mock, mujoco   -> compose.macos   (Mac daily driver, CPU)
#   gazebo, isaac  -> compose.linux   (Linux/GPU)
#   real           -> compose.linux   (SocketCAN, Linux only)
#
# Teleop input devices (--input), scalability-first:
#   foxglove   custom Foxglove panel -> TwistStamped/JointJog (browser, no HW) [default]
#   joy        gamepad (Linux /dev/input, or Mac host-side HID->Joy bridge)
#   spacenav   SpaceMouse 6-DOF (USB, Linux only)
#
# Prerequisites: build the workspace first (see sim.sh). The sim/real target must
# be reachable — run ./scripts/sim.sh in another terminal, or wire the real arm.
#
# Then:
#   ./scripts/teleop.sh                              # openarm, mujoco target, foxglove
#   ./scripts/teleop.sh --input joy                  # gamepad
#   ./scripts/teleop.sh --backend gazebo --input joy # Linux/GPU
#
# Extra args pass straight through to `ros2 launch`.
set -euo pipefail

ROBOT=openarm
VARIANT=""
BACKEND=mujoco
INPUT=foxglove
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --robot) ROBOT="$2"; shift 2 ;;
    --robot=*) ROBOT="${1#--robot=}"; shift ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --variant=*) VARIANT="${1#--variant=}"; shift ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --backend=*) BACKEND="${1#--backend=}"; shift ;;
    --input) INPUT="$2"; shift 2 ;;
    --input=*) INPUT="${1#--input=}"; shift ;;
    *) PASSTHROUGH+=("$1"); shift ;;
  esac
done

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

VALID_INPUTS=(foxglove joy spacenav)
ok=false
for i in "${VALID_INPUTS[@]}"; do
  [[ "$INPUT" == "$i" ]] && ok=true && break
done
if [[ "$ok" != true ]]; then
  echo "error: unknown input '$INPUT'" >&2
  echo "valid inputs: ${VALID_INPUTS[*]}" >&2
  exit 1
fi

case "$BACKEND" in
  mock|mujoco) OVERLAY=docker/compose.macos.yaml ;;
  gazebo|isaac|real) OVERLAY=docker/compose.linux.yaml ;;
esac

cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker/compose.yaml -f "$OVERLAY")
SERVICE=fm_ros2

LAUNCH=(ros2 launch fm_bringup teleop.launch.py \
  "robot:=$ROBOT" "sim_backend:=$BACKEND" "input:=$INPUT")
[[ -n "$VARIANT" ]] && LAUNCH+=("variant:=$VARIANT")
LAUNCH+=(${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"})

echo ">> teleop: $INPUT -> MoveIt Servo -> $ROBOT ($BACKEND target)"
echo ">> shared stack — bringing container up (idempotent)"
"${COMPOSE[@]}" up -d
echo ">> Ctrl-C stops teleop, stack stays up"
echo ">> Foxglove Studio: connect to ws://localhost:8765"
# `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh "${LAUNCH[@]}"
