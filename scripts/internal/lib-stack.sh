#!/usr/bin/env bash
# Shared stack resolution for the fm_ros2 lifecycle verbs. Sourced by
# scripts/run/stack.sh, scripts/run/episode.sh, scripts/run/dataset.sh and
# scripts/run/sim.sh — never executed.
#
# Three facts the verbs would otherwise each re-derive:
#
#   1. which sim backend names are real, and which compose overlay each implies
#   2. whether this shell can run `ros2` itself, or has to route through compose
#   3. how to run one ROS command either way
#
# (2) is what lets `fm stack up` behave the same on a laptop and inside CI. On a
# laptop there is no ROS on the host, so every command is routed through the
# compose service; inside the built container ROS is already sourced, so the same
# verb runs the command in place. One code path, two hosts.

# Every backend sim.launch.py accepts. `real` is not a simulator — it is the
# hardware path, kept in the same list because it picks an overlay the same way.
FM_BACKENDS=(mock mujoco gazebo isaac real)

# fm_stack_normalize <value>
# Echo the underscore spelling of a robot/backend/variant argument, so
# `default-bimanual` and `default_bimanual` are the same value everywhere.
fm_stack_normalize() { printf '%s\n' "${1//-/_}"; }

# fm_stack_check_backend <backend>
# 0 when the backend is one this workspace launches; 1 with a message otherwise.
fm_stack_check_backend() {
  local backend="$1" known
  for known in "${FM_BACKENDS[@]}"; do
    [[ "$backend" == "$known" ]] && return 0
  done
  echo "error: unknown backend '$backend'" >&2
  echo "valid backends: ${FM_BACKENDS[*]}" >&2
  return 1
}

# fm_stack_overlay <backend>
# Echo the compose overlay the backend needs. The CPU simulators run on the macOS
# daily driver; the GPU simulators and the hardware path need the Linux overlay.
fm_stack_overlay() {
  case "$1" in
    mock | mujoco) printf 'docker/compose.macos.yaml\n' ;;
    gazebo | isaac | real) printf 'docker/compose.linux.yaml\n' ;;
    *)
      echo "error: no compose overlay for backend '$1'" >&2
      return 1
      ;;
  esac
}

# fm_stack_inplace
# 0 when this shell can run ROS commands directly (inside the built container, or
# an activated pixi env), 1 when they have to be routed through compose. `ros2`
# on PATH is the whole test: it is present exactly where ROS is sourced.
fm_stack_inplace() { command -v ros2 >/dev/null 2>&1; }

# fm_stack_compose <overlay>
# Fill the FM_COMPOSE array with the compose invocation for that overlay. An
# array, not a string, because the paths must survive word splitting.
fm_stack_compose() {
  export FM_IMAGE="${FM_IMAGE:-ghcr.io/first-motive/fm-app:humble}"
  export FM_WS="$PWD"
  FM_COMPOSE=(docker compose -f docker/compose.yaml -f "$1")
}

# fm_stack_exec <overlay> <command...>
# Run one ROS command on whichever host this shell is. In place when ROS is
# already sourced; otherwise through the compose service, via the image
# entrypoint (`exec` skips ENTRYPOINT, so ROS and the overlay would be unsourced).
fm_stack_exec() {
  local overlay="$1"
  shift
  if fm_stack_inplace; then
    "$@"
    return
  fi
  fm_stack_compose "$overlay"
  "${FM_COMPOSE[@]}" exec -T fm /ros_entrypoint.sh "$@"
}

# fm_stack_exec_detached <overlay> <command...>
# As fm_stack_exec, but returns immediately and leaves the command running. The
# caller owns the teardown: in place it gets the background PID in
# FM_STACK_PID, through compose the process lives in the container and is
# reaped by `stack down`.
fm_stack_exec_detached() {
  local overlay="$1"
  shift
  if fm_stack_inplace; then
    "$@" &
    FM_STACK_PID=$!
    return
  fi
  fm_stack_compose "$overlay"
  # shellcheck disable=SC2034  # read by the caller in the in-place branch above
  FM_STACK_PID=""
  "${FM_COMPOSE[@]}" exec -d fm /ros_entrypoint.sh "$@"
}

# The topics that define the stack's surface: what bringup itself publishes,
# present in sim and on hardware alike — that identity is the claim `--real`
# rests on. Both `up` and `status` read this one list: a readiness gate narrower
# than the assertion that follows it is a race, and that race is what made the
# loop job red on a cold runner (a subscriber alone advertises /joint_states, so
# it appears before the broadcaster that publishes it is active).
# Teleop-layer topics (Servo's command input) belong to the teleop verb, not the
# stack; a topic only exists once something publishes or subscribes to it.
FM_SURFACE_TOPICS=(/joint_states /dynamic_joint_states)

# fm_stack_missing_topics <overlay>
# Echo the surface topics the running stack does not carry, one per line. Empty
# output means the surface is complete; a non-zero exit means there is no stack
# to ask.
fm_stack_missing_topics() {
  local overlay="$1" topics topic
  topics=$(fm_stack_exec "$overlay" ros2 topic list 2>/dev/null) || return 1
  for topic in "${FM_SURFACE_TOPICS[@]}"; do
    grep -qx "$topic" <<<"$topics" || printf '%s\n' "$topic"
  done
  return 0
}

# fm_stack_wait_surface <overlay> <timeout_s>
# Poll until every surface topic is advertised, or fail after the timeout. A
# bounded wait, never a fixed sleep: a cold container takes far longer than a
# warm one, and a sleep long enough for the cold case wastes that time on every
# warm run.
fm_stack_wait_surface() {
  local overlay="$1" timeout="$2"
  local missing _
  for _ in $(seq 1 "$timeout"); do
    missing=$(fm_stack_missing_topics "$overlay") || missing="${FM_SURFACE_TOPICS[*]}"
    [[ -z "$missing" ]] && return 0
    sleep 1
  done
  echo "error: stack surface incomplete after ${timeout}s — missing ${missing//$'\n'/ }" >&2
  return 1
}

# fm_stack_remote_path <path>
# Rewrite a leading `~/` to a literal `$HOME/`, for a path that will be expanded
# by the shell on the other side of fm_stack_exec. Tilde expansion happens at
# parse time in the shell that reads the word, so a `~/recordings` sent through
# compose arrives unexpanded and matches nothing; `$HOME/recordings` inside a
# double-quoted remote command expands there, where the home directory is the
# container's rather than the laptop's.
fm_stack_remote_path() {
  # shellcheck disable=SC2088,SC2016  # both deliberate: the tilde is matched
  # unexpanded, and the $HOME is expanded by the far-side shell, not this one.
  case "$1" in
    "~/"*) printf '$HOME/%s\n' "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
