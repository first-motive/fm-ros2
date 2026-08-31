#!/usr/bin/env bash
# recorder-boot.sh — non-interactive bring-up of the egocentric recorder appliance,
# for the fm-recorder.service systemd unit (installed by install-recorder-service.sh).
#
# A systemd unit reads NONE of ~/.bashrc, so this sources ROS + the colcon overlay +
# the DDS LAN profile explicitly, then execs the recorder launch. It is the boot-time
# equivalent of the three `source` lines setup-recorder.sh prints for an interactive
# terminal, so the screenless camera host (a Linux box now, a Jetson later) starts the
# whole stack itself. Runnable by hand too: `bash scripts/service/recorder-boot.sh`.
#
# Knobs (set in /etc/fm-recorder.env, the unit's EnvironmentFile):
#   FM_RECORDER_TRACKER=on|off      run the hand tracker (off for a MediaPipe-less host)
#   FM_RECORDER_LIDAR=auto|on|off   Livox MID-360S (auto = on iff the vendor driver
#                                   overlay ~/ws_livox is built on this host)
#   FM_RECORDER_RECORD=true|false   arm the recorder (true = armed+idle, waits for REC)
#   FM_RECORDER_FOXGLOVE=true|false run the embedded foxglove bridge (default :8765)
#   FM_BRIDGE_PORT=<port>          shared endpoint from /etc/fm-bridge.env
#   FM_BRIDGE_OWNER=embedded|standalone  which process owns that endpoint
#   FM_LAN_IP=<ip>                  pin the DDS LAN interface (else auto-detected)
#
# No `set -e`: this is a long-lived bring-up wrapper, and a non-matching grep in the
# wait loop must not abort it. It ends in `exec ros2 launch`, so the launch's exit is
# the service's exit (systemd restarts it per the unit's Restart= policy).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
if ! source "$ROOT/scripts/env/bridge.sh"; then
  echo "recorder-boot: invalid bridge configuration; refusing to start" >&2
  exit 78
fi

TRACKER="${FM_RECORDER_TRACKER:-on}"
RECORD="${FM_RECORDER_RECORD:-true}"
FOXGLOVE="${FM_RECORDER_FOXGLOVE:-true}"
# The Livox vendor driver lives in its own overlay workspace (setup-recorder.sh
# provisions it best-effort). auto = run the LiDAR exactly when that overlay is
# built here, so hosts without the sensor keep booting clean.
LIDAR="${FM_RECORDER_LIDAR:-auto}"
LIVOX_OVERLAY="$HOME/ws_livox/install/setup.sh"
# auto probes the BUILT DRIVER NODE, not the overlay's setup script: a half-built
# overlay (setup.sh present, node binary absent — the first Jetson, 2026-08-13)
# would otherwise flip the LiDAR on and loop the whole appliance on "package
# 'livox_ros_driver2' not found".
LIVOX_NODE="$HOME/ws_livox/install/livox_ros_driver2/lib/livox_ros_driver2/livox_ros_driver2_node"
if [ "$LIDAR" = auto ]; then
  [ -x "$LIVOX_NODE" ] && LIDAR=on || LIDAR=off
fi

# At boot the LAN interface may not be up yet, so the foxglove profile's dds-lan.sh
# would find no IP to pin and fall back to default DDS. Wait (bounded, ~30s) for a
# private-LAN address before sourcing the profile. FM_LAN_IP short-circuits the wait
# (dds-lan.sh honours it directly).
if [ -z "${FM_LAN_IP:-}" ]; then
  for _i in $(seq 1 30); do
    if hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -Eq '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; then
      break
    fi
    sleep 1
  done
fi

# ROS setup.bash references unset AMENT_*/COLCON_* vars, which `set -u` treats as an
# error — drop nounset just around the sources, then restore it (setup-recorder.sh pattern).
set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# The Livox driver overlay, when this host has it (lidar:=on needs the package).
if [ "$LIDAR" = on ] && [ -f "$LIVOX_OVERLAY" ]; then
  # shellcheck disable=SC1091
  source "$LIVOX_OVERLAY"
fi
# The comms profile — zenoh unless this machine's identity card, or FM_TRANSPORT,
# says otherwise. A service reads the same card the rig's bridge renders from, so
# the unit and the bridge cannot end up on different middleware.
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh"
set -u

case "$FOXGLOVE" in
  true|false) ;;
  *)
    echo "recorder-boot: FM_RECORDER_FOXGLOVE must be true or false, got '$FOXGLOVE'" >&2
    exit 78
    ;;
esac

LAUNCH_ARGS=(
  tracker:="$TRACKER"
  record:="$RECORD"
  use_foxglove:="$FOXGLOVE"
  lidar:="$LIDAR"
)

if [ "$FOXGLOVE" = true ]; then
  if [ "$FM_BRIDGE_OWNER" = standalone ]; then
    echo "recorder-boot: FM_BRIDGE_OWNER=standalone but FM_RECORDER_FOXGLOVE=true;" >&2
    echo "  disable the embedded bridge so fm-foxglove.service is the only owner." >&2
    exit 78
  fi

  # The recorder package now exposes foxglove_port with validation. Keep an older checkout
  # compatible at the historic default, but never pretend it can bind a custom
  # configured port when its launch file still hard-codes 8765.
  launch_args="$(ros2 launch fm_data_record egocentric_record.launch.py --show-args 2>/dev/null || true)"
  if grep -q 'foxglove_port' <<<"$launch_args"; then
    LAUNCH_ARGS+=(foxglove_port:="$FM_BRIDGE_PORT")
  elif [ "$FM_BRIDGE_PORT" != "$FM_BRIDGE_DEFAULT_PORT" ]; then
    echo "recorder-boot: configured bridge port $FM_BRIDGE_PORT needs a newer recorder package" >&2
    echo "  (egocentric_record.launch.py has no foxglove_port argument); install" >&2
    echo "  fm-foxglove.service or update the recorder package before enabling the embedded bridge." >&2
    exit 78
  fi

  if ! fm_bridge_require_free "$FM_BRIDGE_PORT"; then
    echo "recorder-boot: embedded bridge preflight failed" >&2
    exit 78
  fi
fi

exec ros2 launch fm_data_record egocentric_record.launch.py "${LAUNCH_ARGS[@]}"
