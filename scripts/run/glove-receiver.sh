#!/usr/bin/env bash
# glove-receiver.sh — read or set the tactile glove receivers (on|off).
#
# Each hand is its own unit, fm-tactile@left and fm-tactile@right. `on` enables and
# starts both, `off` stops and disables both, so an off rig stays off after a reboot and
# after an appliance update. --hand sets one hand and leaves the other as it is, e.g. a
# glove away for repair. Status always reports both hands: whether the unit runs, which
# glove port it holds, and whether /glove_<hand>/tactile is publishing.
#
#   scripts/run/glove-receiver.sh                     # on the rig: print the state
#   scripts/run/glove-receiver.sh on|off              # start+enable or stop+disable both
#   scripts/run/glove-receiver.sh off --hand left     # one hand only
#   scripts/run/glove-receiver.sh off --host fmrec    # from any machine, over ssh
#   scripts/run/glove-receiver.sh status --json       # one JSON object for Desktop
#
# A set refuses (exit 3) while a take is recording: it would cut or add a stream
# mid-take. Setting the state it already has changes nothing. Exit 0 done, 2 usage,
# 3 refused.
set -uo pipefail

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

HOST="" JSON=false WANT="" HAND=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    status) WANT=""; shift ;;
    on|off) WANT="$1"; shift ;;
    --host)
      [[ "${2:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { echo "error: --host needs one SSH host or alias" >&2; exit 2; }
      HOST="$2"; shift 2 ;;
    --hand)
      [[ "${2:-}" =~ ^(left|right)$ ]] || { echo "error: --hand needs left or right" >&2; exit 2; }
      HAND="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$HOST" ]; then
  remote_args=(${WANT:+"$WANT"}); $JSON && remote_args+=(--json); [ -n "$HAND" ] && remote_args+=(--hand "$HAND")
  exec ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$HOST" bash -s -- "${remote_args[@]+"${remote_args[@]}"}" < "${BASH_SOURCE[0]}"
fi

HANDS=(left right)
# The hands a set touches: both, or the one --hand names.
if [ -n "$HAND" ]; then TARGETS=("$HAND"); else TARGETS=("${HANDS[@]}"); fi
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# on when both run, off when neither does, mixed otherwise.
overall() {
  local up=0 hand
  for hand in "${HANDS[@]}"; do [ "$(systemctl is-active "fm-tactile@$hand" 2>/dev/null)" = active ] && up=$((up + 1)); done
  case "$up" in 0) echo off ;; "${#HANDS[@]}") echo on ;; *) echo mixed ;; esac
}

# The glove port a hand's receiver holds open, found through the unit's cgroup. Boards
# share one udev name pattern, so the port alone cannot say which hand it is.
held_device() {  # hand
  local cg link target dev
  cg="$(systemctl show -p ControlGroup --value "fm-tactile@$1" 2>/dev/null)"
  [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ] || return 0
  while read -r pid; do
    for link in /proc/"$pid"/fd/*; do
      target="$(readlink "$link" 2>/dev/null)" || continue
      for dev in /dev/fm-tactile-*; do
        [ -e "$dev" ] && [ "$(readlink -f "$dev")" = "$target" ] && { echo "$dev"; return 0; }
      done
    done
  done < "/sys/fs/cgroup$cg/cgroup.procs"
}

# Hands whose tactile topic delivered at least two messages in three seconds.
publishing_hands() {
  local root
  root="$(systemctl show fm-tactile@left -p WorkingDirectory --value 2>/dev/null)"
  [ -f /opt/ros/humble/setup.bash ] && [ -f "$root/install/setup.bash" ] || return 0
  (
    set +u
    # shellcheck disable=SC1091
    source /opt/ros/humble/setup.bash
    # shellcheck disable=SC1091
    source "$root/install/setup.bash"
    # shellcheck disable=SC1091
    source "$root/scripts/env/comms.sh" >/dev/null 2>&1
    python3 - "${HANDS[@]}" <<'PY' 2>/dev/null
import sys, time, rclpy
from rclpy.qos import qos_profile_sensor_data
from fm_tactile_msgs.msg import TactileSample

rclpy.init()
node = rclpy.create_node("fm_glove_receiver_status")
counts = {hand: 0 for hand in sys.argv[1:]}
for hand in counts:
    node.create_subscription(TactileSample, f"/glove_{hand}/tactile",
                             lambda _m, h=hand: counts.__setitem__(h, counts[h] + 1),
                             qos_profile_sensor_data)
end = time.monotonic() + 3.0
while time.monotonic() < end:
    rclpy.spin_once(node, timeout_sec=0.05)
print(" ".join(hand for hand, n in counts.items() if n >= 2))
PY
  )
}

# Print the result and exit. Refusals carry a stable code for Desktop.
finish() {  # code(ok|<refusal>)  detail  changed
  local ok=true status=0 state hand active enabled device publishing="" devices="" sep=""
  [ "$1" = ok ] || { ok=false; status=3; }
  state="$(overall)"
  [ "$state" = off ] || publishing="$(publishing_hands)"
  if $JSON; then
    printf '{"schema_version":1,"verb":"glove-receiver","host":"%s","ok":%s,' "$(hostname)" "$ok"
    $ok || printf '"error":{"code":"%s","detail":"%s"},' "$1" "$(json_escape "$2")"
    for device in /dev/fm-tactile-*; do [ -e "$device" ] && { devices+="$sep\"$(json_escape "$device")\""; sep=,; }; done
    printf '"data":{"receiver":"%s","changed":%s,"devices":[%s],"hands":{' "$state" "${3:-false}" "$devices"
    sep=""
    for hand in "${HANDS[@]}"; do
      active="$(systemctl is-active "fm-tactile@$hand" 2>/dev/null)"
      enabled="$(systemctl is-enabled "fm-tactile@$hand" 2>/dev/null)"
      device="$(held_device "$hand")"
      printf '%s"%s":{"unit":"%s","enabled":%s,"device":%s,"publishing":%s}' "$sep" "$hand" "${active:-unknown}" \
        "$([ "$enabled" = enabled ] && echo true || echo false)" \
        "$([ -n "$device" ] && echo "\"$(json_escape "$device")\"" || echo null)" \
        "$([[ " $publishing " == *" $hand "* ]] && echo true || echo false)"
      sep=,
    done
    printf '}}}\n'
  else
    for hand in "${HANDS[@]}"; do
      device="$(held_device "$hand")"
      printf 'glove %-5s  %-8s  %-8s  %-34s  %s\n' "$hand" \
        "$(systemctl is-active "fm-tactile@$hand" 2>/dev/null)" "$(systemctl is-enabled "fm-tactile@$hand" 2>/dev/null)" \
        "${device:-no glove port}" "$([[ " $publishing " == *" $hand "* ]] && echo publishing || echo silent)"
    done
    if $ok; then echo "glove receivers: $state ($2)"; else echo "glove receivers: $state — refused: $2" >&2; fi
  fi
  exit "$status"
}

systemctl cat fm-tactile@.service >/dev/null 2>&1 \
  || finish not_installed "fm-tactile@.service is missing; install the tactile receivers first"

[ -n "$WANT" ] || finish ok "from systemd"

# Settled is running and enabled for on, stopped and disabled for off, so an off rig
# stays off across a reboot.
settled=true
for hand in "${TARGETS[@]}"; do
  active=false enabled=false
  systemctl is-active -q "fm-tactile@$hand" && active=true
  systemctl is-enabled -q "fm-tactile@$hand" && enabled=true
  if [ "$WANT" = on ]; then $active && $enabled || settled=false
  else ! $active && ! $enabled || settled=false; fi
done
what="$WANT${HAND:+ for the $HAND hand}"
! $settled || finish ok "already $what, nothing changed"

# A take in flight holds its .mcap open, as the recorder's user; see recorder-tracker.sh.
recdir="$(sed -n 's/^FM_RECORDER_RECORDINGS_DIR=//p' /etc/fm-recorder.env 2>/dev/null | tail -1)"
recdir="${recdir:-$HOME/recordings}"
open_bag="$(find /proc/[0-9]*/fd -lname "$recdir/*.mcap*" -print -quit 2>/dev/null)"
[ -z "$open_bag" ] || finish recording "a take is recording (open .mcap under $recdir); stop it first"

sudo -n true 2>/dev/null || finish no_sudo "$(id -un) has no passwordless sudo on $(hostname)"
units=("${TARGETS[@]/#/fm-tactile@}")
if [ "$WANT" = on ]; then
  sudo systemctl enable -q --now "${units[@]}" || finish start_failed "the receivers did not start; see journalctl -u 'fm-tactile@*'"
else
  sudo systemctl disable -q --now "${units[@]}" || finish stop_failed "the receivers did not stop; see journalctl -u 'fm-tactile@*'"
fi
finish ok "set $what" true
