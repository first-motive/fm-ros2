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

# Where detached launches write their output inside the container, one file
# per launch: `stack up` and `episode` both launch detached in one container,
# and a single file would be truncated by the second.
FM_STACK_LOG_DIR=/tmp/fm-launch

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
# Echo the compose overlay for this host and backend. The host OS decides first:
# the macOS overlay pins linux/arm64, and picking it on an x86-64 Linux box for
# a CPU simulator pulled the wrong image and died on `exec format error` (#128).
# On Linux every backend takes the Linux overlay; on macOS the CPU simulators
# take the macOS one and the GPU/hardware backends still name the Linux overlay,
# which is what they need wherever they end up running.
fm_stack_overlay() {
  fm_stack_check_backend "$1" || return 1
  if [[ "$(uname -s)" == Darwin ]]; then
    case "$1" in
      mock | mujoco) printf 'docker/compose.macos.yaml\n'; return ;;
    esac
  fi
  printf 'docker/compose.linux.yaml\n'
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
  # Through a shell so the launch's output lands in a file: `exec -d` discards
  # stdout and stderr, and a launch that died left no trace (#130). stdin is
  # closed on purpose — the compose service is a tty, and `ros2 launch` reading
  # an interactive stdin it never gets is the likeliest reason it exited.
  # shellcheck disable=SC2016  # deliberate: $0 and $@ expand in the far-side shell
  "${FM_COMPOSE[@]}" exec -d fm /ros_entrypoint.sh bash -c \
    'mkdir -p "$0" && exec "$@" >"$0/$(date +%s)-$$.log" 2>&1 </dev/null' \
    "$FM_STACK_LOG_DIR" "$@"
}

# fm_stack_has_publisher <overlay> <topic>
# 0 when something on this graph PUBLISHES the topic, 1 otherwise.
#
# Not `ros2 topic list | grep`: a topic appears in that list as soon as any
# participant on the domain holds a publisher *or a subscription* on it. The
# Jetson recorder and watchdog subscribe to /joint_states, so on the office LAN
# a container with nothing running in it saw the topic immediately, `stack up`
# took the already-up branch, and the stack was never launched (#136). A
# publisher count is the question actually being asked: is this stack running.
fm_stack_has_publisher() {
  local overlay="$1" topic="$2"
  fm_stack_exec "$overlay" ros2 topic info "$topic" 2>/dev/null |
    grep -qE '^Publisher count: [1-9]'
}

# fm_stack_wait_publisher <overlay> <topic> <timeout_s>
# Poll until the topic has a publisher, or fail after the timeout. The bounded
# wait of fm_stack_wait_topic, asking fm_stack_has_publisher's question.
fm_stack_wait_publisher() {
  local overlay="$1" topic="$2" timeout="$3"
  local _
  for _ in $(seq 1 "$timeout"); do
    if fm_stack_has_publisher "$overlay" "$topic"; then
      return 0
    fi
    sleep 1
  done
  echo "error: nothing published $topic within ${timeout}s" >&2
  fm_stack_inplace || echo "launch output: docker compose exec fm sh -c 'tail -n 50 $FM_STACK_LOG_DIR/*.log'" >&2
  return 1
}

# fm_stack_wait_topic <overlay> <topic> <timeout_s>
# Poll until the topic is advertised, or fail after the timeout. A bounded wait,
# never a fixed sleep: a cold container takes far longer than a warm one, and a
# sleep long enough for the cold case wastes that time on every warm run.
fm_stack_wait_topic() {
  local overlay="$1" topic="$2" timeout="$3"
  local _
  for _ in $(seq 1 "$timeout"); do
    if fm_stack_exec "$overlay" ros2 topic list 2>/dev/null | grep -qx "$topic"; then
      return 0
    fi
    sleep 1
  done
  echo "error: $topic never appeared within ${timeout}s" >&2
  fm_stack_inplace || echo "launch output: docker compose exec fm sh -c 'tail -n 50 $FM_STACK_LOG_DIR/*.log'" >&2
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
