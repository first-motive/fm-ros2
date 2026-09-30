#!/usr/bin/env bash
# lidar-power.sh — read or set the chest LiDAR's work mode (idle|sample).
#
# fm_data_sensors' lidar_power node idles the Livox MID-360S between takes (the
# FM_RECORDER_LIDAR_IDLE policy) and wakes it for a take. This asks that node: status
# reads its plan and the lidar's own work state and core temperature; idle and sample
# set it now, the same as the policy would, and wait for the lidar to report it.
# Auto idle still applies afterwards: `sample` lasts until the idle grace period ends
# without a take, `idle` until the next take.
#
#   scripts/run/lidar-power.sh                     # on the rig: print the state
#   scripts/run/lidar-power.sh idle|sample         # set it and wait for the lidar
#   scripts/run/lidar-power.sh idle --host fmrec   # from any machine, over ssh
#   scripts/run/lidar-power.sh status --json       # one JSON object for Desktop
#
# A set refuses (exit 3) while a take is recording, and `sample` while the lidar
# reports a temperature alarm. Exit 0 done, 2 usage, 3 refused or no answer.
set -uo pipefail

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

HOST="" JSON=false WANT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    status) WANT=""; shift ;;
    idle|sample) WANT="$1"; shift ;;
    --host)
      [[ "${2:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { echo "error: --host needs one SSH host or alias" >&2; exit 2; }
      HOST="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$HOST" ]; then
  remote_args=(${WANT:+"$WANT"}); $JSON && remote_args+=(--json)
  exec ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$HOST" bash -s -- "${remote_args[@]+"${remote_args[@]}"}" < "${BASH_SOURCE[0]}"
fi

[ "$(uname -s)" = Linux ] || { echo "lidar-power runs on the recorder host — use --host <rig> from here" >&2; exit 2; }

refuse() {  # code detail
  if $JSON; then
    # json.dumps, not sed: the detail carries a path, and JSON has more escapes than quotes.
    python3 -c 'import json, sys; print(json.dumps({"schema_version": 1, "verb": "lidar-power",
      "host": sys.argv[1], "ok": False, "error": {"code": sys.argv[2], "detail": sys.argv[3]}}))' \
      "$(hostname)" "$1" "$2"
  else
    echo "lidar power: refused: $2" >&2
  fi
  exit 3
}

# A take in flight holds its .mcap open (the recorder's own user, so no sudo). The
# node refuses too; this answers before ROS starts and names the reason.
if [ -n "$WANT" ]; then
  recdir="$(sed -n 's/^FM_RECORDER_RECORDINGS_DIR=//p' /etc/fm-recorder.env 2>/dev/null | tail -1)"
  recdir="${recdir:-$HOME/recordings}"
  [ -z "$(find /proc/[0-9]*/fd -lname "$recdir/*.mcap*" -print -quit 2>/dev/null)" ] \
    || refuse recording "a take is recording (open .mcap under $recdir); stop it first"
fi

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

exec python3 - "$(hostname)" "$JSON" "$WANT" <<'PY'
import json, sys, time
import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from std_msgs.msg import String
from std_srvs.srv import SetBool

host, as_json, want = sys.argv[1], sys.argv[2] == "true", sys.argv[3]
READ_S = 3.0      # /lidar/power is latched and 1 Hz; /lidar/health is 1 Hz
# Waking runs the motor start-up (Livox: about 8 s at 18 W); idling is quicker.
REACH_S = {"idle": 15.0, "sample": 30.0}
STATE = {"idle": 2, "sample": 1}


def out(ok, data=None, error=None):
    if as_json:
        body = {"schema_version": 1, "verb": "lidar-power", "host": host, "ok": ok}
        body.update({"data": data} if ok else {"error": error})
        print(json.dumps(body))
    elif ok:
        temp = data.get("core_temp_c")
        policy = ("auto idle after %g min" % (data["idle_after_s"] / 60)
                  if data.get("policy") == "auto" else "auto idle off")
        print(f"lidar: {data.get('work_state_name') or 'no reading'}"
              f"  core {temp if temp is not None else '?'} °C  thermal {data.get('thermal')}"
              f"  plan {data.get('target') or 'none'} ({data.get('reason')})  {policy}")
    else:
        print(f"lidar power: {error['detail']}", file=sys.stderr)
    return 0 if ok else 3


rclpy.init()
node = Node("fm_lidar_power_cli")
latched = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                     durability=DurabilityPolicy.TRANSIENT_LOCAL)
seen = {}
node.create_subscription(String, "/lidar/power", lambda m: seen.__setitem__("power", json.loads(m.data)), latched)
node.create_subscription(String, "/lidar/health", lambda m: seen.__setitem__("health", json.loads(m.data)), 10)


def spin_until(check, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        rclpy.spin_once(node, timeout_sec=0.1)
        if check():
            return True
    return False


def data(**extra):
    power, health = seen.get("power", {}), seen.get("health", {})
    return {
        "work_state": health.get("work_state"),
        "work_state_name": health.get("work_state_name"),
        "core_temp_c": health.get("core_temp_c"),
        "thermal": health.get("thermal", power.get("thermal")),
        "target": power.get("target"),
        "reason": power.get("reason"),
        "policy": power.get("policy"),
        "idle_after_s": power.get("idle_after_s"),
        "recording": power.get("recording"),
        **extra,
    }


status = 3
try:
    if not spin_until(lambda: "power" in seen and "health" in seen, READ_S):
        missing = "/lidar/power" if "power" not in seen else "/lidar/health"
        status = out(False, error={"code": "no_reading", "detail": (
            f"no {missing} message for {READ_S:g} s — is the lidar on, fm-recorder running, "
            "and fm_data new enough to run lidar_power?")})
    elif not want:
        status = out(True, data())
    else:
        before = seen["power"].get("target")
        client = node.create_client(SetBool, "/lidar/power/set_sampling")
        if not client.wait_for_service(timeout_sec=READ_S):
            status = out(False, error={"code": "no_service", "detail": "lidar_power offers no /lidar/power/set_sampling"})
        else:
            future = client.call_async(SetBool.Request(data=want == "sample"))
            rclpy.spin_until_future_complete(node, future, timeout_sec=5.0)
            answer = future.result()
            if answer is None:
                status = out(False, error={"code": "no_answer", "detail": "lidar_power did not answer"})
            elif not answer.success:
                code = ("recording" if "recording" in answer.message
                        else "temperature_alarm" if "temperature" in answer.message else "refused")
                status = out(False, error={"code": code, "detail": answer.message})
            else:
                reached = spin_until(
                    lambda: seen.get("health", {}).get("work_state") == STATE[want], REACH_S[want])
                status = out(True, data(changed=before != want, reached=reached))
except KeyboardInterrupt:
    pass
node.destroy_node()
rclpy.try_shutdown()
sys.exit(status)
PY
