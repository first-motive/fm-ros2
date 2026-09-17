#!/usr/bin/env bash
# rig-health.sh — one pass/fail line per thing a recording depends on.
#
# The check an operator runs after plugging the rig together and before the first
# take: every fixture found, every stream at its rate, the clock set, the units up,
# the versions current. By hand this audit took twenty minutes of ssh (2026-09-17);
# a silent glove, a wedged USB link, and a rig still booting all looked the same from
# the app.
#
#   scripts/run/rig-health.sh                 # on the rig
#   scripts/run/rig-health.sh --host fmrec    # from any machine, over ssh
#   scripts/run/rig-health.sh --json          # one JSON object for agents and CI
#
# --host pipes THIS script to the host, so it works against a rig whose checkout is
# older than the machine asking. Exit 0 when nothing FAILed, 1 otherwise. Read-only:
# it opens no serial port, restarts nothing, and writes nothing.
set -uo pipefail

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

HOST="" JSON=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [[ "${2:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { echo "error: --host needs one SSH host or alias" >&2; exit 2; }
      HOST="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$HOST" ]; then
  remote_args=(); $JSON && remote_args+=(--json)
  exec ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$HOST" bash -s -- "${remote_args[@]+"${remote_args[@]}"}" < "${BASH_SOURCE[0]}"
fi

[ "$(uname -s)" = Linux ] || { echo "rig-health runs on the recorder host — use --host <rig> from here" >&2; exit 2; }

# The workspace: beside this script when run from a checkout, the recorder unit's
# WorkingDirectory when the script arrived over ssh stdin.
ROOT=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; fi
[ -f "$ROOT/lib.sh" ] || ROOT="$(systemctl show fm-recorder -p WorkingDirectory --value 2>/dev/null)"
[ -f "$ROOT/lib.sh" ] || { echo "cannot find the fm_ros2 workspace on this host" >&2; exit 2; }

names=() states=() details=()
report() { names+=("$1"); states+=("$2"); details+=("$3"); }  # name  ok|warn|FAIL|skip  detail

# --- software ------------------------------------------------------------------
tags="fm_ros2 $(git -C "$ROOT" describe --tags --always 2>/dev/null), fm_data $(git -C "$ROOT/src/fm_data" describe --tags --always 2>/dev/null)"
behind="$("$ROOT/scripts/service/appliance-update.sh" --check recorder 2>/dev/null | sed -n 's/^check \(.*\): behind \(.*\)/\1 -> \2/p' | paste -sd, -)"
if [ -n "$behind" ]; then report versions warn "$tags; update pending: $behind"; else report versions ok "$tags"; fi

if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && [ "$(date +%Y)" -ge 2026 ]; then
  report clock ok "synced, $(date -u +%FT%TZ)"
else
  report clock FAIL "not synced ($(date -u +%FT%TZ)) — takes recorded now carry the wrong time"
fi

for unit in fm-recorder fm-watchdog fm-episode-qa fm-zenoh-bridge fm-tactile@left fm-tactile@right; do
  state="$(systemctl is-active "$unit" 2>/dev/null)"
  if [ "$state" = active ]; then report "unit $unit" ok active; else report "unit $unit" FAIL "${state:-not installed}"; fi
done

# --- host ------------------------------------------------------------------------
hot=0
for zone in /sys/class/thermal/thermal_zone*/temp; do
  t="$(cat "$zone" 2>/dev/null)"   # some Tegra zones exist and answer "No data available"
  [ -n "$t" ] || continue
  t=$(( t / 1000 )); [ "$t" -gt "$hot" ] && hot="$t"
done
if [ "$hot" -ge 85 ]; then report thermal FAIL "${hot} C — throttling; let the rig cool"
elif [ "$hot" -ge 70 ]; then report thermal warn "${hot} C"
else report thermal ok "${hot} C"; fi

free_gb="$(df -BG --output=avail "$HOME/recordings" 2>/dev/null | tail -1 | tr -dc 0-9)"
if [ -z "$free_gb" ]; then report disk skip "no ~/recordings yet"
elif [ "$free_gb" -lt 10 ]; then report disk FAIL "${free_gb} GB free — the recorder refuses takes under 10 GB"
elif [ "$free_gb" -lt 50 ]; then report disk warn "${free_gb} GB free"
else report disk ok "${free_gb} GB free"; fi

# --- fixtures on the bus ---------------------------------------------------------
count_usb() {  # vendor:product -> how many are plugged in
  local n=0 d
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor"):$(cat "$d/idProduct")" = "$1" ] && n=$((n + 1))
  done
  echo "$n"
}
head_speed=""
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] && [ "$(cat "$d/idVendor")" = 8086 ] && head_speed="$(cat "$d/speed")"
done
if [ -z "$head_speed" ]; then report "head camera" FAIL "RealSense not found on USB"
elif [ "$head_speed" -lt 5000 ]; then report "head camera" warn "RealSense on a ${head_speed} Mbit/s link — needs a USB 3 port and cable"
else report "head camera" ok "RealSense on USB 3"; fi

wrists="$(count_usb 6366:3370)"
if [ "$wrists" = 2 ]; then report "wrist cameras" ok "2 found"; else report "wrist cameras" FAIL "$wrists of 2 found"; fi
gloves="$(count_usb 1a86:7523)"
if [ "$gloves" = 2 ]; then report "glove boards" ok "2 found"; else report "glove boards" FAIL "$gloves of 2 found"; fi

lidar="$(sudo -n sed -n 's/^FM_RECORDER_LIDAR=//p' /etc/fm-recorder.env 2>/dev/null | tail -1)"
if [ "$lidar" = on ]; then report lidar warn "expected (FM_RECORDER_LIDAR=on) — see the stream check"
else report lidar skip "not fitted yet"; fi

# Bus-powered budget: what hangs off a hub that draws from one upstream port, against
# that port's 500 mA. A self-powered hub (bmAttributes bit 6) has its own supply — the
# Jetson carrier's built-in hub behind its four sockets is one, and warning about it
# was a false alarm (fm-rec-01, 2026-09-17).
for hub in /sys/bus/usb/devices/*; do
  [ "$(cat "$hub/bDeviceClass" 2>/dev/null)" = 09 ] || continue
  case "$(basename "$hub")" in usb*) continue ;; esac
  [ "$(cat "$hub/speed")" = 480 ] || continue
  (( 0x$(cat "$hub/bmAttributes" 2>/dev/null || echo 40) & 0x40 )) && continue
  draw=0
  for child in "$hub"/"$(basename "$hub")".*; do
    [ -f "$child/bMaxPower" ] || continue
    draw=$(( draw + $(tr -dc 0-9 < "$child/bMaxPower") ))
  done
  [ "$draw" -gt 500 ] && report "usb power $(basename "$hub")" warn "${draw} mA requested through a bus-powered hub (budget 500) — use a powered hub"
done

wedged="$(journalctl -k --since -10min --no-pager -o cat 2>/dev/null | grep -cE 'failed to (send|receive) control message: -110|urb stopped')"
if [ "${wedged:-0}" -gt 0 ]; then report "usb errors" FAIL "$wedged kernel timeouts in 10 min — a device stopped answering; re-plug it"
else report "usb errors" ok "none in 10 min"; fi

for dev in /dev/video*; do
  [ -e "$dev" ] || continue
  [ "$(cat "/sys/class/video4linux/$(basename "$dev")/index" 2>/dev/null)" = 0 ] || continue
  grep -q "USB 2.0 Camera" "/sys/class/video4linux/$(basename "$dev")/name" 2>/dev/null || continue
  b="$(v4l2-ctl -d "$dev" --get-ctrl brightness 2>/dev/null | tr -dc 0-9-)"
  [ -n "$b" ] && [ "$b" != 0 ] && report "wrist exposure $dev" warn "brightness $b (want 0) — highlights clip"
done

# --- links -----------------------------------------------------------------------
if ip -br link 2>/dev/null | awk '$1 ~ /^en/ && $2 == "UP"' | grep -q .; then report ethernet ok up
else report ethernet warn "down — Wi-Fi only; camera streaming to the app will be poor"; fi
if [ "$(ss -tn 2>/dev/null | grep -c ':7447 ')" -gt 0 ]; then report "zenoh router" ok connected
else report "zenoh router" warn "no router link — robot and episode queries are unavailable; recording still works"; fi
if ss -ltn 2>/dev/null | grep -q ':8765 '; then report "app bridge" ok "listening on 8765"
else report "app bridge" FAIL "nothing listening on 8765 — the app cannot connect"; fi

# --- streams ---------------------------------------------------------------------
config="$ROOT/src/fm_data/fm_data_record/config/egocentric_head.yaml"
if [ -f /opt/ros/humble/setup.bash ] && [ -f "$ROOT/install/setup.bash" ] && [ -f "$config" ]; then
  set +u
  # shellcheck disable=SC1091
  source /opt/ros/humble/setup.bash
  # shellcheck disable=SC1091
  source "$ROOT/install/setup.bash"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/env/comms.sh" >/dev/null 2>&1
  set -u
  while IFS='|' read -r name state detail; do
    [ -n "$name" ] && report "$name" "$state" "$detail"
  done < <(python3 - "$config" "$lidar" <<'PY' 2>/dev/null
import sys, time, yaml, rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from rosidl_runtime_py.utilities import get_message

# The lidar slot is in the recorder's contract already; until one is fitted its
# streams are not a finding.
lidar_fitted = sys.argv[2] == "on"
topics = [
    t for t in yaml.safe_load(open(sys.argv[1]))["capture_topics"]
    if t.get("expected_hz") and (lidar_fitted or not t["topic"].startswith("/lidar/"))
]
rclpy.init()
node = Node("fm_rig_health")
seen = {t["topic"]: [] for t in topics}

def watch(topic):
    def on_message(message):
        now = node.get_clock().now().nanoseconds * 1e-9
        stamp = getattr(getattr(message, "header", None), "stamp", None)
        age = now - (stamp.sec + stamp.nanosec * 1e-9) if stamp and stamp.sec else None
        seen[topic].append((time.monotonic(), age))
    return on_message

for t in topics:
    node.create_subscription(get_message(t["type"]), t["topic"], watch(t["topic"]), qos_profile_sensor_data)
end = time.monotonic() + 5.0
while time.monotonic() < end:
    rclpy.spin_once(node, timeout_sec=0.05)
for t in topics:
    got, want = seen[t["topic"]], float(t["expected_hz"])
    name = "stream " + t["topic"]
    if len(got) < 2:
        # The recorder's own contract decides: a required stream missing blocks a take.
        print(f"{name}|{'FAIL' if t.get('required') else 'warn'}|no messages in 5 s")
        continue
    rate = (len(got) - 1) / (got[-1][0] - got[0][0])
    ages = sorted(a for _, a in got if a is not None)
    late = f", frames arrive {ages[len(ages) // 2] * 1000:.0f} ms after capture" if ages else ""
    state = "ok" if rate >= 0.8 * want else "warn"
    print(f"{name}|{state}|{rate:.1f} Hz (expect {want:g}){late}")
rclpy.shutdown()
PY
)
else
  report streams skip "ROS workspace not built here"
fi

# --- report ----------------------------------------------------------------------
failed=0
for s in "${states[@]}"; do [ "$s" = FAIL ] && failed=$((failed + 1)); done
if $JSON; then
  printf '{"schema_version":1,"verb":"rig-health","host":"%s","ok":%s,"checks":[' "$(hostname)" "$([ "$failed" = 0 ] && echo true || echo false)"
  for i in "${!names[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    printf '{"name":"%s","state":"%s","detail":"%s"}' "${names[$i]}" "${states[$i]}" "$(printf '%s' "${details[$i]}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  done
  printf ']}\n'
else
  echo "rig health — $(hostname), $(date '+%F %T')"
  for i in "${!names[@]}"; do printf '  %-4s  %-46s %s\n' "${states[$i]}" "${names[$i]}" "${details[$i]}"; done
  if [ "$failed" = 0 ]; then echo "ready: nothing failed"; else echo "not ready: $failed check(s) failed"; fi
fi
[ "$failed" = 0 ]
