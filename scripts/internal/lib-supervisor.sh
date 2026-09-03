#!/usr/bin/env bash
# Talk to the processor's supervisors from a shell. Sourced by process.sh and
# release.sh — never executed.
#
# Desktop drives the processor over latched JSON-on-String topics
# (/process/*, /release/*). These helpers publish the same requests and read
# the same latched answers, inside the processor's own runtime, so a verb sees
# exactly what Desktop sees and nothing else. No engine logic lives here.
# Sourced with stdout sent to stderr: the comms profile announces itself on
# stdout, and `--json` promises a payload there and nothing else.
# shellcheck source=lib-processor.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-processor.sh" >&2

FM_SUPERVISOR_TIMEOUT="${FM_SUPERVISOR_TIMEOUT:-20}" # seconds per topic read or publish

# fm_supervisor_require
# The supervisors run where the processor role is installed; anywhere else
# there is no graph to read, and saying so beats an empty payload.
fm_supervisor_require() {
  if ! fm_processor_installed; then
    echo "error: the processor role is not installed on this host (no ${FM_PROCESSOR_ENV_FILE:-/etc/fm-processor.env})" >&2
    echo "       run this where fm-processor.service lives" >&2
    return 1
  fi
  # Resolve the runtime once, here, so a host that cannot reach it fails with
  # that reason instead of a misleading "nothing published" after the timeout.
  local runtime
  runtime=$(fm_processor_runtime) || return 1
  if [[ "$runtime" == container ]]; then
    fm_processor_compose "$PWD" || return 1
    if [[ -z "$("${FM_COMPOSE[@]}" ps -q fm 2>/dev/null)" ]]; then
      echo "error: the processor container is not running — check: systemctl status fm-processor" >&2
      return 1
    fi
  fi
}

# fm_supervisor_exec <command...>
# One command in the processor's runtime with ROS sourced, argv preserved.
fm_supervisor_exec() {
  fm_processor_exec "$PWD" bash -lc 'exec "$@"' bash "$@"
}

# fm_supervisor_read <topic>
# Print the latched JSON payload on <topic>. Fails when nothing is publishing
# it within the timeout — the supervisor is down, or not on this graph.
fm_supervisor_read() {
  local topic="$1" payload
  # `echo` prints a `---` message separator after the field; drop it so the
  # payload is exactly the JSON the supervisor published.
  payload=$(fm_supervisor_exec timeout "$FM_SUPERVISOR_TIMEOUT" \
    ros2 topic echo --once --field data "$topic" 2>/dev/null | sed '/^---$/d' || true)
  if [[ -z "$payload" ]]; then
    echo "error: nothing published on $topic within ${FM_SUPERVISOR_TIMEOUT}s — is fm-processor.service running?" >&2
    return 1
  fi
  printf '%s\n' "$payload"
}

# fm_supervisor_publish <topic> <payload>
# Publish one String request and wait for the supervisor to be subscribed
# first; a request published into a graph nobody has joined is silently lost.
fm_supervisor_publish() {
  local topic="$1" payload="$2"
  local yaml="{data: \"${payload//\"/\\\"}\"}"
  if ! fm_supervisor_exec timeout "$FM_SUPERVISOR_TIMEOUT" \
    ros2 topic pub -1 -w 1 "$topic" std_msgs/msg/String "$yaml" >/dev/null 2>&1; then
    echo "error: no subscriber on $topic within ${FM_SUPERVISOR_TIMEOUT}s — is fm-processor.service running?" >&2
    return 1
  fi
}

# fm_supervisor_request <command-topic> <payload> <status-topic> <id...>
# Publish one request and print the first status message that answers it —
# one naming any <id> (in its queue, current job, refusals, or last outcome)
# or carrying a request error. A one-shot latched read cannot do this: the
# supervisor republishes status on every cloud-lifecycle tick, so the message
# that carried the refusal is gone before a reader that started late sees it.
# Subscribes first, publishes second, all inside the processor's runtime.
# Exit 3 when nothing answered within the timeout; the last status seen is
# still printed so the caller has something honest to show.
fm_supervisor_request() {
  local cmd_topic="$1" payload="$2" status_topic="$3"
  shift 3
  local yaml="{data: \"${payload//\"/\\\"}\"}"
  fm_supervisor_exec bash -c "$FM_SUPERVISOR_REQUEST_SCRIPT" _ \
    "$cmd_topic" "$yaml" "$status_topic" "$FM_SUPERVISOR_TIMEOUT" "$@"
}

# shellcheck disable=SC2016  # runs in the processor's runtime, not expanded here
FM_SUPERVISOR_REQUEST_SCRIPT='
set -u
cmd_topic=$1 yaml=$2 status_topic=$3 timeout=$4
shift 4
log=$(mktemp)
trap "rm -f $log" EXIT
ros2 topic echo --field data "$status_topic" >"$log" 2>/dev/null &
echo_pid=$!
sleep 1
if ! timeout "$timeout" ros2 topic pub -1 -w 1 "$cmd_topic" std_msgs/msg/String "$yaml" >/dev/null 2>&1; then
  kill "$echo_pid" 2>/dev/null
  echo "error: no subscriber on $cmd_topic within ${timeout}s — is fm-processor.service running?" >&2
  exit 1
fi
python3 - "$log" "$timeout" "$@" <<"PY"
import json, sys, time
log, timeout, ids = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
deadline = time.time() + timeout
last = None
def answers(text, s):
    return bool(s.get("request_error") or s.get("issue_code")) or any(json.dumps(i) in text for i in ids)
while time.time() < deadline:
    with open(log) as f:
        for line in f:
            line = line.strip()
            if not line or line == "---":
                continue
            try:
                s = json.loads(line)
            except ValueError:
                continue
            last = line
            if answers(line, s):
                print(line)
                sys.exit(0)
    time.sleep(0.5)
if last is not None:
    print(last)
print("error: no status answered the request within %ss; showing the last one seen" % int(timeout), file=sys.stderr)
sys.exit(3)
PY
rc=$?
kill "$echo_pid" 2>/dev/null
exit $rc
'

# fm_supervisor_format <python-source>
# Pretty-print the JSON on stdin with a small formatter, run in the processor's
# runtime rather than the host's — the same reason dataset.sh parses the
# manifest there: jq is not in the image, python always is.
fm_supervisor_format() {
  fm_supervisor_exec python3 -c "$1"
}

# fm_supervisor_request_id
# A contract-safe id for a release request: lowercase, digits, dashes.
fm_supervisor_request_id() {
  printf 'cli-%s-%04x\n' "$(date -u +%Y%m%dt%H%M%Sz)" "$((RANDOM % 65536))"
}
