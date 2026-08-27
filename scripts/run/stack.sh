#!/usr/bin/env bash
# The robot stack lifecycle verb: bring one up, look at it, tear it down.
#
#   ./scripts/run/stack.sh up                    # mujoco sim, the default
#   ./scripts/run/stack.sh up --real             # the same stack on hardware
#   ./scripts/run/stack.sh status                # what is running, and its topics
#   ./scripts/run/stack.sh down                  # tear it down
#
# Sim is the default because the topic surface is the same either way: the same
# controllers, the same /joint_states, the same servo command topics. `--real`
# swaps the backend under that surface and nothing above it, which is what makes
# the whole record → process loop runnable on a laptop with no hardware attached.
#
#   sim  (default)   mujoco backend, CPU, macOS compose overlay
#   --real           hardware backend, Linux compose overlay, CAN + GPU
#
# `stack up` is the inverse of `stack down`, and each is safe to repeat: `up`
# leaves an already-running stack alone, `down` on nothing exits clean.
#
# Where sim.sh launches one robot in the foreground and hands you its log, this
# runs the stack detached and returns, so a script can record an episode against
# it. Both take the same --robot/--variant/--backend/--task-env arguments.
set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=scripts/internal/lib-stack.sh
source scripts/internal/lib-stack.sh

READY_TIMEOUT=90 # seconds to wait for the stack's first topic

usage() {
  cat <<'EOF'
stack.sh — bring the robot stack up, inspect it, tear it down

Usage: ./scripts/run/stack.sh <up|down|status> [options] [ros2-launch-args...]

  up        launch the stack detached and wait for it to publish
  down      stop the stack and the container behind it
  status    report whether the stack is up and which topics it carries

  --robot R      openarm | so101 | g1_d | axol (default openarm)
  --variant V    description variant (e.g. default_bimanual)
  --backend B    mock | mujoco | gazebo | isaac | real (default mujoco)
  --real         shorthand for --backend real
  --task-env E   task environment (default default)
  -h, --help     show this help

Sim is the default and carries the same topic surface as hardware. Extra args
pass straight through to `ros2 launch`.
EOF
}

# The topics that define the stack's surface: what bringup itself publishes,
# present in sim and on hardware alike — that identity is the claim `--real`
# rests on, so status asserts it rather than describing it. Teleop-layer topics
# (Servo's command input) belong to the teleop verb, not the stack; a topic
# only exists once something publishes or subscribes to it.
SURFACE_TOPICS=(/joint_states /dynamic_joint_states)

stack_up() {
  local overlay="$1" robot="$2" variant="$3" backend="$4" task_env="$5"
  shift 5

  if ! fm_stack_inplace; then
    [[ -d docker ]] || vcs import <fm-ros2.repos
    fm_stack_compose "$overlay"
    echo ">> container up (idempotent)"
    "${FM_COMPOSE[@]}" up -d
  fi

  # A publisher, never the topic name: a LAN subscriber (the Jetson recorder
  # subscribes to /joint_states) makes the name appear on a container that is
  # running nothing at all, and this branch then skips the launch (#136).
  if fm_stack_has_publisher "$overlay" /joint_states; then
    for topic in "${SURFACE_TOPICS[@]}"; do
      fm_stack_wait_publisher "$overlay" "$topic" "$READY_TIMEOUT"
    done
    echo ">> stack already up — surface complete"
    return 0
  fi

  # --noninteractive: detached, there is no stdin for launch to read (#130).
  local launch=(ros2 launch --noninteractive fm_bringup sim.launch.py
    "robot:=$robot" "sim_backend:=$backend" "task_env:=$task_env")
  [[ -n "$variant" ]] && launch+=("variant:=$variant")
  launch+=("$@")

  echo ">> launching $robot on the $backend backend, detached"
  fm_stack_exec_detached "$overlay" "${launch[@]}"
  for topic in "${SURFACE_TOPICS[@]}"; do
    fm_stack_wait_publisher "$overlay" "$topic" "$READY_TIMEOUT"
  done
  echo ">> stack up — surface complete (${SURFACE_TOPICS[*]})"
}

stack_down() {
  local overlay="$1"

  # In place there is no container to stop: kill the nodes the launch spawned.
  # Named processes rather than a PID, because `down` is normally a separate
  # shell from the `up` that started them.
  if fm_stack_inplace; then
    pkill -f 'ros2 launch fm_bringup' 2>/dev/null || true
    pkill -f ros2_control_node 2>/dev/null || true
    pkill -f robot_state_publisher 2>/dev/null || true
    echo ">> stack down"
    return 0
  fi

  if [[ ! -d docker ]]; then
    echo ">> no container overlay present — nothing to tear down"
    return 0
  fi
  fm_stack_compose "$overlay"
  "${FM_COMPOSE[@]}" down
  echo ">> stack down"
}

stack_status() {
  local overlay="$1"
  # Reachability first: no ROS graph at all is "down", which is a different
  # answer from a graph that carries no stack.
  if ! fm_stack_exec "$overlay" ros2 topic list >/dev/null 2>&1; then
    echo "stack: down"
    return 1
  fi

  # Publishers, for the reason stack_up tests them: an idle LAN with a remote
  # subscriber reported "up" here too (#136).
  local missing=() topic
  for topic in "${SURFACE_TOPICS[@]}"; do
    fm_stack_has_publisher "$overlay" "$topic" || missing+=("$topic")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "stack: partial — missing ${missing[*]}"
    return 1
  fi
  echo "stack: up — surface complete (${SURFACE_TOPICS[*]})"
  # Bounded: this line is decoration, and `ros2 control list_controllers` waits
  # on the controller_manager service forever when it is busy or a second
  # graph participant confuses discovery — it held the sim loop for 34 minutes
  # on fm-ws-01 (2026-08-27).
  fm_stack_exec "$overlay" timeout 15 ros2 control list_controllers 2>/dev/null || true
}

main() {
  local action="" robot=openarm variant="" backend=mujoco task_env=default real=false
  local passthrough=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      up | down | status)
        action="$1"
        shift
        ;;
      --robot)
        robot="$2"
        shift 2
        ;;
      --robot=*)
        robot="${1#--robot=}"
        shift
        ;;
      --variant)
        variant="$2"
        shift 2
        ;;
      --variant=*)
        variant="${1#--variant=}"
        shift
        ;;
      --backend)
        backend="$2"
        shift 2
        ;;
      --backend=*)
        backend="${1#--backend=}"
        shift
        ;;
      --real)
        real=true
        shift
        ;;
      --task-env)
        task_env="$2"
        shift 2
        ;;
      --task-env=*)
        task_env="${1#--task-env=}"
        shift
        ;;
      *)
        passthrough+=("$1")
        shift
        ;;
    esac
  done

  if [[ -z "$action" ]]; then
    usage >&2
    echo "error: expected one of up, down, status" >&2
    return 2
  fi

  # --real and an explicit --backend are two answers to one question. Refuse
  # rather than silently letting the later flag win.
  if [[ "$real" == true ]]; then
    if [[ "$backend" != mujoco ]]; then
      echo "error: --real and --backend $backend both set — pick one" >&2
      return 2
    fi
    backend=real
  fi

  robot=$(fm_stack_normalize "$robot")
  backend=$(fm_stack_normalize "$backend")
  fm_stack_check_backend "$backend"

  local overlay
  overlay=$(fm_stack_overlay "$backend")

  # CI self-test hook, matching sim.sh: arguments parsed and the overlay picked,
  # stopping before any Docker or ROS call CI cannot make. Proves `fm stack`
  # reaches this script and resolves its flags.
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: stack $action resolved (robot=$robot, backend=$backend, overlay=$(basename "$overlay"))"
    return 0
  fi

  case "$action" in
    up) stack_up "$overlay" "$robot" "$variant" "$backend" "$task_env" \
      ${passthrough[@]+"${passthrough[@]}"} ;;
    down) stack_down "$overlay" ;;
    status) stack_status "$overlay" ;;
  esac
}

main "$@"
