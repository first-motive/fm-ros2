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
#     run --rm fm colcon build --symlink-install
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

usage() {
  cat <<'EOF'
sim.sh — launch a robot in a ros2_control simulation backend

Usage: ./scripts/sim.sh [--robot R] [--variant V] [--backend B] [--task-env E] [-h] [ros2-launch-args...]

  --robot R      openarm | so101 | g1_d (default openarm)
  --variant V    description variant (e.g. default_bimanual)
  --backend B    mock | mujoco | gazebo | isaac | real (default mujoco)
  --task-env E   task environment (default default)
  -h, --help     show this help

mock/mujoco use the macOS (CPU) overlay; gazebo/isaac/real use the Linux (GPU)
overlay. --robot/--backend accept hyphen or underscore form. Extra args pass
straight through to `ros2 launch`.
EOF
}

main() {
  local ROBOT=openarm VARIANT="" BACKEND=mujoco TASK_ENV=default
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
      --task-env) TASK_ENV="$2"; shift 2 ;;
      --task-env=*) TASK_ENV="${1#--task-env=}"; shift ;;
      *) PASSTHROUGH+=("$1"); shift ;;
    esac
  done

  # Normalize hyphen -> underscore (default-bimanual -> default_bimanual).
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

  # Backend picks the compose overlay: CPU sim on macOS, GPU sim on Linux.
  local OVERLAY
  case "$BACKEND" in
    mock|mujoco) OVERLAY=docker/compose.macos.yaml ;;
    gazebo|isaac|real) OVERLAY=docker/compose.linux.yaml ;;
  esac

  cd "$(dirname "$0")/.."

  # fm-ros2 consumes the published fm-app full-stack image and sources the compose
  # overlays from fm-docker (imported into docker/ on first run via fm-ros2.repos).
  [[ -d docker ]] || vcs import < fm-ros2.repos

  # On macOS the MuJoCo path depends on OrbStack/Docker being up first. Delegate the
  # runtime bring-up to fm-docker — no vendored helper here. docker/ is imported
  # above, so use the imported installer; fall back to the pinned tag when absent.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ -f docker/install.sh ]]; then
      bash docker/install.sh --no-pull
    else
      curl -fsSL --proto '=https' --proto-redir '=https' \
        "https://raw.githubusercontent.com/first-motive/fm-docker/v0.1.0/install.sh" | bash -s -- --no-pull
    fi
  fi
  export FM_IMAGE="${FM_IMAGE:-ghcr.io/first-motive/fm-app:humble}"
  export FM_WS="$PWD"
  local COMPOSE=(docker compose -f docker/compose.yaml -f "$OVERLAY")
  local SERVICE=fm

  local LAUNCH=(ros2 launch fm_bringup sim.launch.py \
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
}

main "$@"
