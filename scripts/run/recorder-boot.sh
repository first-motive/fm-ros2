#!/usr/bin/env bash
# recorder-boot.sh — non-interactive bring-up of the egocentric recorder appliance,
# for the fm-recorder.service systemd unit (installed by install-recorder-service.sh).
#
# A systemd unit reads NONE of ~/.bashrc, so this sources ROS + the colcon overlay +
# the DDS LAN profile explicitly, then execs the recorder launch. It is the boot-time
# equivalent of the three `source` lines setup-recorder.sh prints for an interactive
# terminal, so the screenless camera host (a Linux box now, a Jetson later) starts the
# whole stack itself. Runnable by hand too: `bash scripts/run/recorder-boot.sh`.
#
# Knobs (set in /etc/fm-recorder.env, the unit's EnvironmentFile):
#   FM_RECORDER_TRACKER=on|off      run the hand tracker (off for a MediaPipe-less host)
#   FM_RECORDER_RECORD=true|false   arm the recorder (true = armed+idle, waits for REC)
#   FM_RECORDER_FOXGLOVE=true|false run the foxglove bridge here (:8765)
#   FM_LAN_IP=<ip>                  pin the DDS LAN interface (else auto-detected)
#
# No `set -e`: this is a long-lived bring-up wrapper, and a non-matching grep in the
# wait loop must not abort it. It ends in `exec ros2 launch`, so the launch's exit is
# the service's exit (systemd restarts it per the unit's Restart= policy).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TRACKER="${FM_RECORDER_TRACKER:-on}"
RECORD="${FM_RECORDER_RECORD:-true}"
FOXGLOVE="${FM_RECORDER_FOXGLOVE:-true}"

# At boot the LAN interface may not be up yet, so dds-lan.sh would find no IP to pin
# and fall back to default DDS. Wait (bounded, ~30s) for a private-LAN address before
# sourcing it. FM_LAN_IP short-circuits the wait (dds-lan.sh honours it directly).
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
# shellcheck disable=SC1091
source "$ROOT/scripts/run/dds-lan.sh"
set -u

exec ros2 launch fm_data_record egocentric_record.launch.py \
  tracker:="$TRACKER" record:="$RECORD" use_foxglove:="$FOXGLOVE"
