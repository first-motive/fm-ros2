#!/usr/bin/env bash
# monitors-boot.sh — non-interactive bring-up of ONE rig monitor, for the
# fm-watchdog.service / fm-episode-qa.service systemd units (installed by
# install-monitors-service.sh).
#
#   bash scripts/service/monitors-boot.sh watchdog
#   bash scripts/service/monitors-boot.sh episode_qa
#
# Same shape as recorder-boot.sh: a systemd unit reads NONE of ~/.bashrc, so this
# sources ROS + the colcon overlay + the DDS LAN profile explicitly before exec'ing
# the node. The DDS profile is not optional — this appliance pins FastDDS to one LAN
# interface (scripts/env/dds-lan.sh), and a monitor started without it silently joins
# a different discovery scope: its nodes run, publish nothing anyone sees, and the
# operator surface shows no health at all. That exact mistake cost an afternoon on
# 2026-08-11.
#
# WHY SEPARATE UNITS, not entries in the recorder launch:
# a monitor composed into egocentric_record.launch.py shares the recorder's fate —
# on 2026-08-11 a launch entry naming a package the appliance did not build made
# ros2 launch exit 1 and systemd restart-looped the RECORDER, taking capture down to
# add health monitoring. A monitor must never be able to stop the thing it watches.
# Its own unit fails alone, restarts alone, and can be masked without touching
# capture.
#
# Knobs (set in /etc/fm-monitors.env, the units' EnvironmentFile):
#   FM_MONITORS_WATCHDOG=true|false     run the rig-health watchdog
#   FM_MONITORS_EPISODE_QA=true|false   run the per-episode capture QA node
#   FM_LAN_IP=<ip>                      pin the DDS LAN interface (else auto-detected)
#
# No `set -e`: this is a bring-up wrapper and ends in `exec`, so the node's exit is
# the service's exit (systemd restarts it per the unit's Restart= policy).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ROLE="${1:-}"
case "$ROLE" in
	watchdog)
		PKG=fm_data_watchdog
		EXECUTABLE=watchdog
		ENABLED="${FM_MONITORS_WATCHDOG:-true}"
		;;
	episode_qa)
		PKG=fm_data_episode_qa
		EXECUTABLE=episode_qa
		ENABLED="${FM_MONITORS_EPISODE_QA:-true}"
		;;
	*)
		echo "usage: monitors-boot.sh watchdog|episode_qa" >&2
		exit 2
		;;
esac

# A disabled monitor exits 0 rather than failing: systemd should read "asked not to
# run" as success, not restart-loop it. Turning one off is an env-file edit plus a
# restart, with no unit surgery.
if [ "$ENABLED" != true ]; then
	echo "monitors-boot: $ROLE disabled via /etc/fm-monitors.env — exiting cleanly"
	exit 0
fi

# ROS setup.bash references unset AMENT_*/COLCON_* vars, which `set -u` treats as an
# error — drop nounset just around the sources, then restore it (recorder-boot.sh
# pattern).
set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# The comms profile — foxglove (dds-lan.sh) unless FM_COMMS or .fm_ros2.json says
# otherwise. This is what puts the monitor on the same discovery scope as the
# recorder and the foxglove bridge.
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh"
set -u

# Fail loudly and immediately if the package is not built, rather than letting
# systemd restart-loop an unresolvable exec. setup-recorder.sh builds both monitors;
# a missing one means the workspace is behind, and the journal should say so in one
# line instead of a repeating stack trace.
if ! ros2 pkg prefix "$PKG" >/dev/null 2>&1; then
	echo "monitors-boot: package $PKG is not built in $ROOT/install — run" >&2
	echo "  ./scripts/install/setup-recorder.sh   (builds the monitors)" >&2
	exit 1
fi

echo "monitors-boot: starting $PKG/$EXECUTABLE"
exec ros2 run "$PKG" "$EXECUTABLE"
