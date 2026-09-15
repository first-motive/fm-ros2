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

# fm_supervisor_request_exact <command-topic> <payload> <status-topic> <request-id>
# A latched status can name an older episode with the same id. Callers that
# mint a request id use this form so an old snapshot cannot acknowledge a new
# request.
fm_supervisor_request_exact() {
  local cmd_topic="$1" payload="$2" status_topic="$3" request_id="$4"
  local yaml="{data: \"${payload//\"/\\\"}\"}"
  fm_supervisor_exec bash -c "$FM_SUPERVISOR_REQUEST_EXACT_SCRIPT" _ \
    "$cmd_topic" "$yaml" "$status_topic" "$FM_SUPERVISOR_TIMEOUT" "$request_id" "$payload"
}

# fm_supervisor_request_stdin_exact <command-topic> <result-topic>
# The request stays on stdin through the processor runtime. This is used for
# review payloads because notes and reviewer identity must not reach argv.
fm_supervisor_request_stdin_exact() {
  local cmd_topic="$1" result_topic="$2"
  fm_supervisor_exec bash -c "$FM_SUPERVISOR_REQUEST_STDIN_EXACT_SCRIPT" _ \
    "$cmd_topic" "$result_topic" "$FM_SUPERVISOR_TIMEOUT"
}

# fm_supervisor_wait_exact <status-topic> <request-id>
# Observe one request until its queue/current, retained request aggregate, or
# cloud lifecycle entry is terminal. It never submits another request.
fm_supervisor_wait_exact() {
  local status_topic="$1" request_id="$2"
  fm_supervisor_exec bash -c "$FM_SUPERVISOR_WAIT_EXACT_SCRIPT" _ \
    "$status_topic" "$FM_SUPERVISOR_TIMEOUT" "$request_id"
}

# shellcheck disable=SC2016  # runs in the processor's runtime, not expanded here
FM_SUPERVISOR_REQUEST_EXACT_SCRIPT='
set -u
cmd_topic=$1 yaml=$2 status_topic=$3 timeout=$4 request_id=$5 payload=$6
log=$(mktemp)
trap "rm -f $log" EXIT
ros2 topic echo --qos-durability volatile --field data "$status_topic" >"$log" 2>/dev/null &
echo_pid=$!
sleep 1
if ! timeout "$timeout" ros2 topic pub -1 -w 1 "$cmd_topic" std_msgs/msg/String "$yaml" >/dev/null 2>&1; then
  kill "$echo_pid" 2>/dev/null
  echo "error: no subscriber on $cmd_topic within ${timeout}s — is fm-processor.service running?" >&2
  exit 1
fi
python3 - "$log" "$timeout" "$request_id" "$payload" <<"PY"
import hashlib, json, sys, time
log, timeout, request_id, payload = (
    sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
)
request_payload_sha256 = hashlib.sha256(payload.encode("utf-8")).hexdigest()
deadline = time.time() + timeout
last = None
def carries_id(value):
    if not isinstance(value, dict):
        return False
    return (
        value.get("request_id") == request_id
        and value.get("request_payload_sha256") == request_payload_sha256
    )
def result_code(value):
    if value.get("request_error") or value.get("refused"):
        return 3
    for result in value.get("request_results") or []:
        if not isinstance(result, dict) or result.get("request_id") != request_id:
            continue
        state = result.get("state")
        if state in {"queued", "running"}:
            return 0
        if state in {"completed", "failed", "refused"} or isinstance(result.get("ok"), bool):
            return 0 if result.get("ok") is True else 3
    last = value.get("last")
    if isinstance(last, dict) and last.get("request_id") == request_id:
        return 0 if last.get("ok") is True else 3
    return 0
while time.time() < deadline:
    with open(log) as f:
        for line in f:
            line = line.strip()
            if not line or line == "---":
                continue
            try:
                status = json.loads(line)
            except ValueError:
                continue
            last = line
            if carries_id(status):
                print(line)
                sys.exit(result_code(status))
    time.sleep(0.5)
if last is not None:
    print(last)
print("error: no status answered request %s within %ss; showing the last one seen" % (request_id, int(timeout)), file=sys.stderr)
sys.exit(3)
PY
rc=$?
kill "$echo_pid" 2>/dev/null
exit $rc
'

# shellcheck disable=SC2016  # runs in the processor's runtime, not expanded here
FM_SUPERVISOR_REQUEST_STDIN_EXACT_SCRIPT='
set -u
cmd_topic=$1 result_topic=$2 timeout=$3
payload_file=$(mktemp)
log=$(mktemp)
cleanup() {
  rm -f "$payload_file" "$log"
  if [ -n "${echo_pid:-}" ]; then kill "$echo_pid" 2>/dev/null; fi
}
trap cleanup EXIT
cat >"$payload_file"
ros2 topic echo --qos-durability volatile --field data "$result_topic" >"$log" 2>/dev/null &
echo_pid=$!
sleep 1
request_key=$(python3 - "$payload_file" "$cmd_topic" "$timeout" <<"PY"
import hashlib, json, sys, time
from pathlib import Path
import rclpy
from std_msgs.msg import String

payload_path, topic, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])
payload = Path(payload_path).read_text(encoding="utf-8")
request = json.loads(payload)
request_id = request.get("request_id") if isinstance(request, dict) else None
if not isinstance(request_id, str) or not request_id:
    print("error: request JSON needs a request_id", file=sys.stderr)
    raise SystemExit(2)
request_payload_sha256 = hashlib.sha256(payload.encode("utf-8")).hexdigest()
rclpy.init()
node = rclpy.create_node("fm_process_cli_request")
publisher = node.create_publisher(String, topic, 10)
deadline = time.time() + timeout
try:
    while publisher.get_subscription_count() < 1 and time.time() < deadline:
        rclpy.spin_once(node, timeout_sec=0.1)
    if publisher.get_subscription_count() < 1:
        print("error: no subscriber on %s within %ss" % (topic, int(timeout)), file=sys.stderr)
        raise SystemExit(1)
    message = String()
    message.data = payload
    publisher.publish(message)
    rclpy.spin_once(node, timeout_sec=0.1)
    print(request_id + ":" + request_payload_sha256)
finally:
    node.destroy_node()
    rclpy.shutdown()
PY
)
rc=$?
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
request_id="${request_key%%:*}"
request_payload_sha256="${request_key#*:}"
python3 - "$log" "$timeout" "$request_id" "$request_payload_sha256" <<"PY"
import json, sys, time
log, timeout, request_id, request_payload_sha256 = (
    sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
)
deadline = time.time() + timeout
last = None
def carries_id(value):
    return (
        isinstance(value, dict)
        and isinstance(value.get("request_id"), str)
        and value["request_id"] == request_id
        and isinstance(value.get("request_payload_sha256"), str)
        and value["request_payload_sha256"] == request_payload_sha256
    )
while time.time() < deadline:
    with open(log) as f:
        for line in f:
            line = line.strip()
            if not line or line == "---":
                continue
            try:
                result = json.loads(line)
            except ValueError:
                continue
            last = line
            if carries_id(result):
                print(line)
                sys.exit(0 if result.get("ok") is not False else 3)
    time.sleep(0.5)
if last is not None:
    print(last)
print("error: no result answered request %s within %ss; showing the last one seen" % (request_id, int(timeout)), file=sys.stderr)
sys.exit(3)
PY
exit $?
'

# shellcheck disable=SC2016  # runs in the processor's runtime, not expanded here
FM_SUPERVISOR_WAIT_EXACT_SCRIPT='
set -u
status_topic=$1 timeout=$2 request_id=$3
log=$(mktemp)
trap "rm -f $log" EXIT
ros2 topic echo --field data "$status_topic" >"$log" 2>/dev/null &
echo_pid=$!
sleep 1
python3 - "$log" "$timeout" "$request_id" <<"PY"
import json, sys, time
log, timeout, request_id = sys.argv[1], float(sys.argv[2]), sys.argv[3]
deadline = time.time() + timeout
last = None
failure_seen = False
history_missing = False
def matching(value):
    return (
        isinstance(value, dict)
        and isinstance(value.get("request_id"), str)
        and value["request_id"] == request_id
    )
def has_matching(value):
    if isinstance(value, dict):
        return matching(value)
    if isinstance(value, list):
        return any(matching(item) for item in value)
    return False
def request_result(status):
    results = status.get("request_results")
    if not isinstance(results, list):
        return None, False
    matches = [
        item for item in results
        if isinstance(item, dict) and item.get("request_id") == request_id
    ]
    return (matches[-1] if matches else None), True
def aggregate_terminal(result):
    if result is None:
        return None
    state = result.get("state")
    if state in {"completed", "succeeded"}:
        return 0 if result.get("ok") is True else 3
    if state in {
        "failed", "refused", "capacity_timeout", "quota_blocked",
        "request_error", "error",
    }:
        return 3
    if isinstance(result.get("ok"), bool):
        return 0 if result.get("ok") is True else 3
    return None
def terminal(status):
    for key in ("queue", "current"):
        value = status.get(key)
        if has_matching(value):
            return None
    if matching(status) and status.get("request_error"):
        return 3
    if matching(status) and status.get("refused"):
        return 3
    if has_matching(status.get("refused")):
        return 3
    result, has_results = request_result(status)
    if has_results:
        # New supervisors retain a bounded request aggregate. If this id was
        # evicted, do not infer success from an unrelated ``last`` episode.
        return aggregate_terminal(result)
    last = status.get("last")
    if matching(last) and last.get("ok") is not True:
        # A failure is safe to report from the legacy per-episode result. A
        # successful batch still needs its request aggregate.
        return 3
    for item in status.get("cloud_lifecycle") or []:
        if matching(item):
            state = item.get("state", item.get("reason", item.get("reason_code")))
            if state in {"ready", "completed", "stopped", "cancelled"}:
                return 0
            if state in {
                "failed", "budget_blocked", "capacity_timeout", "quota_blocked",
            }:
                return 3
            return None
    return None
while time.time() < deadline:
    with open(log) as f:
        for line in f:
            line = line.strip()
            if not line or line == "---":
                continue
            try:
                status = json.loads(line)
            except ValueError:
                continue
            last = line
            if matching(status) and (
                status.get("request_error") or status.get("refused")
            ):
                failure_seen = True
            if has_matching(status.get("refused")):
                failure_seen = True
            aggregate, has_results = request_result(status)
            if not has_results and matching(status.get("last")):
                history_missing = True
            if aggregate is not None and any(
                isinstance(item, dict) and item.get("state") == "refused"
                for item in aggregate.get("episodes", [])
            ):
                failure_seen = True
            result = terminal(status)
            if result is not None:
                print(line)
                sys.exit(3 if failure_seen else result)
    time.sleep(0.5)
if last is not None:
    print(last)
if history_missing:
    print("error: request %s has no retained batch result; refusing to infer success from last" % request_id, file=sys.stderr)
print("error: request %s did not reach a terminal status within %ss; inspect status or retry with a new id" % (request_id, int(timeout)), file=sys.stderr)
sys.exit(3)
PY
rc=$?
kill "$echo_pid" 2>/dev/null
exit $rc
'

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
