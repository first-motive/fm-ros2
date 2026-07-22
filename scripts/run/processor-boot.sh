#!/usr/bin/env bash
# processor-boot.sh — non-interactive bring-up of the dataset-processing appliance,
# for the fm-processor.service systemd unit (installed by install-processor-service.sh).
#
# A systemd unit reads NONE of ~/.bashrc, so this sources ROS + the colcon overlay +
# the DDS LAN profile explicitly, then execs the processing launch. It is the boot-time
# equivalent of the three `source` lines setup-processor.sh prints for an interactive
# terminal, so the processor host serves /process/* itself and the desktop app's
# Process surface drives it. Runnable by hand too: `bash scripts/run/processor-boot.sh`.
#
# Knobs (set in /etc/fm-processor.env, the unit's EnvironmentFile):
#   FM_PROCESSOR_RECORDINGS_DIR=<dir>  recorder output dir with sessions.jsonl + bags
#   FM_PROCESSOR_OUTPUT_DIR=<dir>      per-episode processing output root
#   FM_PROCESSOR_CONFIG=<file>         processing profile JSON (empty = engine default)
#   FM_LAN_IP=<ip>                     pin the DDS LAN interface (else auto-detected)
#
# No `set -e`: this is a long-lived bring-up wrapper, and a non-matching grep in the
# wait loop must not abort it. It ends in `exec ros2 launch`, so the launch's exit is
# the service's exit (systemd restarts it per the unit's Restart= policy).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RECORDINGS_DIR="${FM_PROCESSOR_RECORDINGS_DIR:-~/recordings}"
OUTPUT_DIR="${FM_PROCESSOR_OUTPUT_DIR:-~/processed}"
CONFIG="${FM_PROCESSOR_CONFIG:-}"

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
# error — drop nounset just around the sources, then restore it (recorder-boot.sh pattern).
set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# shellcheck disable=SC1091
source "$ROOT/scripts/run/dds-lan.sh"
set -u

# ros2 launch rejects an empty-valued argument ("malformed launch argument
# 'config:='"), so the config override is appended only when actually set —
# absent, the launch file's empty default (= the engine default profile) holds.
# Hit live on the first processor host, 2026-07-22.
LAUNCH_ARGS=(recordings_dir:="$RECORDINGS_DIR" output_dir:="$OUTPUT_DIR")
if [ -n "$CONFIG" ]; then
  LAUNCH_ARGS+=(config:="$CONFIG")
fi
exec ros2 launch fm_data process_session.launch.py "${LAUNCH_ARGS[@]}"
