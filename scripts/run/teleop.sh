#!/usr/bin/env bash
# Jog a robot's arm interactively through MoveIt Servo (--robot openarm | so101 |
# g1_d | axol). Brings up Servo plus the selected teleop input against a sim (or real)
# target. The compose overlay follows from --backend, same mapping as sim.sh:
#
#   mock, mujoco   -> compose.macos   (Mac daily driver, CPU)
#   gazebo, isaac  -> compose.linux   (Linux/GPU)
#   real           -> compose.linux   (hardware, Linux only)
#
# Teleop input devices (--input), scalability-first:
#   foxglove   custom Foxglove panel -> TwistStamped/JointJog (browser, no HW) [default]
#   joy        gamepad (Linux /dev/input, or Mac host-side HID->Joy bridge)
#   spacenav   SpaceMouse 6-DOF (USB, Linux only)
#   vision     camera tracks the operator's wrist -> arm twist (MediaPipe). Override the
#              camera_source launch arg: camera_source:=<index|url>. On macOS/OrbStack
#              a USB webcam cannot pass through, so use a phone MJPEG stream URL, e.g.
#              camera_source:=http://<phone-ip>:8080/video. One-time setup inside the
#              container: pip install mediapipe opencv-python, then run
#              fm_teleop/fm_teleop_vision/scripts/download_model.sh. Engage from the
#              Foxglove panel's "Vision (hold)" button (a deadman).
#
# In the Foxglove panel, pick the robot in the panel settings so the joint set +
# command frame match. Per-robot Cartesian reach:
#   openarm  7-DOF  full 6-DOF Cartesian
#   g1_d     7-DOF  full 6-DOF Cartesian (right arm; base driven separately)
#   so101    5-DOF  JointJog primary; Cartesian is translation-only, orientation drifts
#   axol     7+7-DOF  full 6-DOF Cartesian (both arms, one servo_node each)
#
# Real backends differ by robot: OpenArm + SO101 use a ros2_control hardware plugin
# (openarm SocketCAN, SO101 feetech serial); the G1-D has no such plugin — its real
# arm runs through the Servo->arm_sdk bridge (fm_control/g1_arm_sdk_bridge), and
# the wheeled base is driven separately by a Twist->AGV node. Axol's real CAN backend
# is deferred (no ros2_control plugin yet), so it is sim-only. The OpenArm/SO101/G1-D
# real paths are plumbed but untested — no physical hardware yet.
#
# Prerequisites: build the workspace first (see sim.sh). The sim/real target must
# be reachable — run ./scripts/run/sim.sh in another terminal, or wire the real arm.
#
# Then:
#   ./scripts/run/teleop.sh                              # openarm, mujoco target, foxglove
#   ./scripts/run/teleop.sh --robot so101 --backend mock # SO101 teleop
#   ./scripts/run/teleop.sh --robot g1_d                 # G1-D right arm, mujoco
#   ./scripts/run/teleop.sh --robot axol                 # Axol, one servo_node per arm
#   ./scripts/run/teleop.sh --input joy                  # gamepad
#
# Extra args pass straight through to `ros2 launch`.
set -euo pipefail

usage() {
  cat <<'EOF'
teleop.sh — jog a robot's arm interactively through MoveIt Servo

Usage: ./scripts/run/teleop.sh [--robot R] [--variant V] [--backend B] [--input I] [-h] [ros2-launch-args...]

  --robot R      openarm | so101 | g1_d | axol (default openarm)
  --variant V    description variant
  --backend B    mock | mujoco | gazebo | isaac | real (default mujoco)
  --input I      foxglove | joy | spacenav | vision | mirror (default foxglove)
  -h, --help     show this help

mock/mujoco use the macOS (CPU) overlay; gazebo/isaac/real use the Linux (GPU)
overlay. Extra args pass straight through to `ros2 launch`.
EOF
}

main() {
  local ROBOT=openarm VARIANT="" BACKEND=mujoco INPUT=foxglove
  local PASSTHROUGH=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
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

  local VALID_BACKENDS=(mock mujoco gazebo isaac real)
  local ok=false b
  for b in "${VALID_BACKENDS[@]}"; do
    [[ "$BACKEND" == "$b" ]] && ok=true && break
  done
  if [[ "$ok" != true ]]; then
    echo "error: unknown backend '$BACKEND'" >&2
    echo "valid backends: ${VALID_BACKENDS[*]}" >&2
    return 1
  fi

  local VALID_INPUTS=(foxglove joy spacenav vision mirror) i
  ok=false
  for i in "${VALID_INPUTS[@]}"; do
    [[ "$INPUT" == "$i" ]] && ok=true && break
  done
  if [[ "$ok" != true ]]; then
    echo "error: unknown input '$INPUT'" >&2
    echo "valid inputs: ${VALID_INPUTS[*]}" >&2
    return 1
  fi

  local OVERLAY
  case "$BACKEND" in
    mock|mujoco) OVERLAY=docker/compose.macos.yaml ;;
    gazebo|isaac|real) OVERLAY=docker/compose.linux.yaml ;;
  esac

  cd "$(dirname "$0")/../.."

  # fm-ros2 consumes the published fm-app full-stack image and sources the compose
  # overlays from fm-docker (imported into docker/ on first run via fm-ros2.repos).
  [[ -d docker ]] || vcs import < fm-ros2.repos
  export FM_IMAGE="${FM_IMAGE:-ghcr.io/first-motive/fm-app:humble}"
  export FM_WS="$PWD"
  local COMPOSE=(docker compose -f docker/compose.yaml -f "$OVERLAY")
  local SERVICE=fm

  local LAUNCH=(ros2 launch fm_bringup teleop.launch.py \
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
}

main "$@"
