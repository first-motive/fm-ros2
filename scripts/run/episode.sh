#!/usr/bin/env bash
# The episode lifecycle verb: record a take against a running stack, end one, or
# list what has been recorded.
#
#   ./scripts/run/episode.sh record --duration 10   # record a ten-second take
#   ./scripts/run/episode.sh stop                   # end the take in flight
#   ./scripts/run/episode.sh list                   # what is on disk
#
# The stack has to be up first (`./scripts/run/stack.sh up`) — this verb records
# what that stack publishes and does not launch a robot of its own.
#
# The recorder is a node, not a command: it listens on an episode-marker topic
# and opens a bag when a start marker arrives. `record` starts it if it is not
# already up, publishes the start marker, holds for the duration, then publishes
# the end marker and waits for the finalized episode to land in the index. That
# wait is the point — a take is not recorded until the recorder says it closed.
set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=scripts/internal/lib-stack.sh
source scripts/internal/lib-stack.sh

MARKER_TOPIC=/fm_data_record/episode_marker
STATUS_TOPIC=/fm_data_record/recorder_status
RECORDER_TIMEOUT=60 # seconds to wait for a started recorder to advertise status
FINALIZE_TIMEOUT=60 # seconds to wait for the closed episode to reach the index
MARKER_TIMEOUT=30   # seconds to wait for the recorder to subscribe to a marker

usage() {
  cat <<'EOF'
episode.sh — record an episode against the running stack

Usage: ./scripts/run/episode.sh <record|stop|list> [options]

  record    start a take, hold for --duration, end it, wait for the bag
  stop      end the take in flight (no duration, no wait)
  list      print the recorded episode index

  --duration S     seconds to record (default 10)
  --task-id T      task id stamped into the episode (default fm-loop-demo)
  --instruction I  natural-language instruction stamped into the episode
  --output-dir D   recorder output directory (default ~/recordings)
  --backend B      backend the stack was brought up on (default mujoco)
  --real           shorthand for --backend real
  -h, --help       show this help
EOF
}

# Publish one marker and wait for the recorder to be subscribed before sending
# it. Without the wait the marker is published into a graph the recorder has not
# joined yet, and a take that was asked for never starts. `-w 1` blocks forever
# when no recorder is running, so the wait is bounded — an unbounded one here is
# a hung CI job rather than a failing one.
publish_marker() {
  local overlay="$1" json="$2"
  fm_stack_exec "$overlay" timeout "$MARKER_TIMEOUT" \
    ros2 topic pub -1 -w 1 "$MARKER_TOPIC" \
    std_msgs/msg/String "{data: '$json'}" >/dev/null
}

ensure_recorder() {
  local overlay="$1" output_dir="$2"
  if fm_stack_exec "$overlay" ros2 topic list 2>/dev/null | grep -qx "$STATUS_TOPIC"; then
    echo ">> recorder already running"
    return 0
  fi
  echo ">> starting the recorder (output $output_dir)"
  # The recorder reads one nested YAML through `config_file`, not flat ROS
  # params, so the output dir is set by deriving a config from the package's
  # default with that one key replaced. Written on the far side: the path must
  # resolve where the recorder runs, not where this shell does.
  local remote_output config
  remote_output=$(fm_stack_remote_path "$output_dir")
  config='$HOME/.cache/fm/recorder.loop.yaml'
  fm_stack_exec "$overlay" bash -lc "
    set -euo pipefail
    default=\$(ros2 pkg prefix fm_data_record)/share/fm_data_record/config/recorder.yaml
    mkdir -p \"\$(dirname $config)\"
    sed \"s|^output_dir:.*|output_dir: $remote_output|\" \"\$default\" > $config"
  # Through a shell so $HOME in the config path expands where the recorder
  # runs — ros2 run itself performs no expansion on a parameter value.
  fm_stack_exec_detached "$overlay" bash -lc \
    "ros2 run fm_data_record recorder --ros-args -p config_file:=$config"
  fm_stack_wait_topic "$overlay" "$STATUS_TOPIC" "$RECORDER_TIMEOUT"
}

# The recorder appends one line per finalized episode. Growth of that file is
# the only honest "the take closed" signal available from outside the node.
wait_for_episode() {
  local overlay="$1" index="$2" before="$3"
  local _ after
  for _ in $(seq 1 "$FINALIZE_TIMEOUT"); do
    after=$(fm_stack_exec "$overlay" bash -lc "wc -l <\"$index\" 2>/dev/null || echo 0")
    if [[ "${after//[[:space:]]/}" -gt "$before" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "error: no finalized episode appeared in $index within ${FINALIZE_TIMEOUT}s" >&2
  return 1
}

main() {
  # shellcheck disable=SC2088  # deliberate: the recorder expands ~ itself, and a
  # shell on the far side of fm_stack_exec gets it via fm_stack_remote_path.
  local action="" duration=10 task_id=fm-loop-demo output_dir='~/recordings'
  local instruction="Move the arm through a short synthetic take."
  local backend=mujoco real=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      record | stop | list)
        action="$1"
        shift
        ;;
      --duration)
        duration="$2"
        shift 2
        ;;
      --duration=*)
        duration="${1#--duration=}"
        shift
        ;;
      --task-id)
        task_id="$2"
        shift 2
        ;;
      --task-id=*)
        task_id="${1#--task-id=}"
        shift
        ;;
      --instruction)
        instruction="$2"
        shift 2
        ;;
      --instruction=*)
        instruction="${1#--instruction=}"
        shift
        ;;
      --output-dir)
        output_dir="$2"
        shift 2
        ;;
      --output-dir=*)
        output_dir="${1#--output-dir=}"
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
      *)
        echo "error: unknown argument '$1'" >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$action" ]]; then
    usage >&2
    echo "error: expected one of record, stop, list" >&2
    return 2
  fi

  if [[ "$real" == true ]]; then
    if [[ "$backend" != mujoco ]]; then
      echo "error: --real and --backend $backend both set — pick one" >&2
      return 2
    fi
    backend=real
  fi

  backend=$(fm_stack_normalize "$backend")
  fm_stack_check_backend "$backend"

  local overlay
  overlay=$(fm_stack_overlay "$backend")

  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: episode $action resolved (backend=$backend, duration=${duration}s, task=$task_id)"
    return 0
  fi

  # The recorder expands `~` itself when it reads output_dir, but a shell on the
  # far side of fm_stack_exec does not — see fm_stack_remote_path.
  local index
  index="$(fm_stack_remote_path "$output_dir")/sessions.jsonl"

  case "$action" in
    record)
      ensure_recorder "$overlay" "$output_dir"
      local before
      before=$(fm_stack_exec "$overlay" bash -lc "wc -l <\"$index\" 2>/dev/null || echo 0")
      before="${before//[[:space:]]/}"

      echo ">> start marker — recording ${duration}s"
      publish_marker "$overlay" \
        "{\"event\": \"start\", \"task_id\": \"$task_id\", \"instruction\": \"$instruction\"}"
      sleep "$duration"

      echo ">> end marker"
      publish_marker "$overlay" '{"event": "end", "operator_success": true}'
      wait_for_episode "$overlay" "$index" "$before"
      echo ">> episode recorded — indexed in $index"
      ;;
    stop)
      publish_marker "$overlay" '{"event": "end", "operator_success": true}'
      echo ">> end marker published"
      ;;
    list)
      fm_stack_exec "$overlay" bash -lc "cat \"$index\" 2>/dev/null || echo 'no episodes recorded yet'"
      ;;
  esac
}

main "$@"
