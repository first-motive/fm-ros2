#!/usr/bin/env bash
# lidar-health.sh — the chest LiDAR's own health: core temperature, work state, HMS codes.
#
# Reads /lidar/health, which fm_data_sensors' lidar_health node publishes at 1 Hz
# from the Livox status push (the vendor driver drops it).
#
#   scripts/run/lidar-health.sh                   # on the rig: one reading
#   scripts/run/lidar-health.sh --host fmrec      # from any machine, over ssh
#   scripts/run/lidar-health.sh --json            # one JSON object for Desktop and agents
#   scripts/run/lidar-health.sh --watch [--json]  # every reading until Ctrl-C
#
# Read-only. No temperature limit is applied: Livox documents none for the core, and
# its HMS codes already report temperature trouble. A notice (the latched link-recovered
# 0x0401) is shown but is not a fault. Exit 0 healthy, 1 an HMS fault is set, 2 usage,
# 3 no reading (lidar off, or the recorder is down).
set -uo pipefail

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

HOST="" JSON=false WATCH=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [[ "${2:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { echo "error: --host needs one SSH host or alias" >&2; exit 2; }
      HOST="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    --watch) WATCH=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$HOST" ]; then
  remote_args=(); $JSON && remote_args+=(--json); $WATCH && remote_args+=(--watch)
  exec ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$HOST" bash -s -- "${remote_args[@]+"${remote_args[@]}"}" < "${BASH_SOURCE[0]}"
fi

[ "$(uname -s)" = Linux ] || { echo "lidar-health runs on the recorder host — use --host <rig> from here" >&2; exit 2; }

# The workspace: beside this script when run from a checkout, the recorder unit's
# WorkingDirectory when the script arrived over ssh stdin.
ROOT=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi
[ -f "$ROOT/lib.sh" ] || ROOT="$(systemctl show fm-recorder -p WorkingDirectory --value 2>/dev/null)"
[ -f "$ROOT/install/setup.bash" ] || { echo "cannot find the built fm_ros2 workspace on this host" >&2; exit 2; }

set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh" >/dev/null 2>&1
set -u

exec python3 - "$(hostname)" "$JSON" "$WATCH" <<'PY'
import json, sys, time
import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from std_msgs.msg import String

host, as_json, watch = sys.argv[1], sys.argv[2] == "true", sys.argv[3] == "true"
WAIT_S = 3.0  # the push is 1 Hz; three misses means it is not coming


def emit(health):
    faults = health.get("faults") or []
    if as_json:
        print(json.dumps({"schema_version": 1, "verb": "lidar-health", "host": host,
                          "ok": not faults, "data": health}), flush=True)
        return
    temp = health.get("core_temp_c")
    state = health.get("work_state_name") or health.get("work_state")
    hms = ", ".join(f"{f['code']} ({f['level']})" for f in faults) or "none"
    # Notices (the latched link-recovered 0x0401) are information, not a fault.
    notices = "".join(f"  notice {n['code']}" for n in health.get("notices") or [])
    print(f"{time.strftime('%H:%M:%S')}  core {temp if temp is not None else '?'} °C  "
          f"state {state}  HMS {hms}{notices}", flush=True)


rclpy.init()
node = Node("fm_lidar_health_cli")
latest = []
node.create_subscription(String, "/lidar/health", lambda m: latest.append(json.loads(m.data)), 10)
status = 3
try:
    deadline = time.monotonic() + WAIT_S
    while True:
        if time.monotonic() >= deadline:
            status = 3  # never arrived, or (--watch) stopped arriving
            break
        rclpy.spin_once(node, timeout_sec=0.1)
        if not latest:
            continue
        health = latest.pop()
        latest.clear()
        emit(health)
        status = 1 if health.get("faults") else 0
        if not watch:
            break
        deadline = time.monotonic() + WAIT_S
except (KeyboardInterrupt, ExternalShutdownException):
    pass  # Ctrl-C ends --watch
if status == 3:
    detail = f"no /lidar/health message for {WAIT_S:g} s — is the lidar on and fm-recorder running?"
    if as_json:
        print(json.dumps({"schema_version": 1, "verb": "lidar-health", "host": host, "ok": False,
                          "error": {"code": "no_reading", "detail": detail}}))
    else:
        print(f"lidar health: {detail}", file=sys.stderr)
node.destroy_node()
rclpy.try_shutdown()
sys.exit(status)
PY
