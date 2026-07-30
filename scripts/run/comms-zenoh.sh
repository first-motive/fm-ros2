#!/usr/bin/env bash
# comms-zenoh.sh — the zenoh comms profile.
#
# SOURCED by comms.sh; never source this directly (comms.sh owns which profile a
# host runs, and sourcing this by hand bypasses that decision).
#
# Under this profile DDS stops crossing the network entirely: every host keeps a
# loopback-only DDS graph, and a zenoh-bridge-ros2dds per host republishes the
# allowed topics to the one zenohd router. That inverts the foxglove profile's
# problem — dds-lan.sh exists only because FastDDS announces every NIC, and with
# nothing to announce there is nothing to pin.
#
# The bridge and the router are NOT started here. They are services, installed
# and run by fm-comms (comms/); this script only shapes the ROS environment the
# rest of the workspace inherits. Import the repo with:
#     vcs import < fm-ros2.repos
#
# Override the domain as usual:
#     ROS_DOMAIN_ID=7 FM_COMMS=zenoh source scripts/run/comms.sh

_fm_zenoh_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

# Keep FastDDS for this first cut. Cyclone is the better fit under a bridge and
# lands as its own step; changing the transport and the RMW at once would leave
# any regression with two possible causes.
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp

# Confine DDS to loopback. Cross-host traffic is the bridge's job now, so a DDS
# participant that reaches the LAN would duplicate what Zenoh already carries —
# and re-introduce the multi-NIC delivery failures the foxglove profile has to
# work around.
export ROS_LOCALHOST_ONLY=1

# A profile left over from a previous `source comms.sh` in this shell would still
# pin FastDDS to a LAN interface, quietly contradicting the line above.
unset FASTRTPS_DEFAULT_PROFILES_FILE

# Where the configs live, so a rig can point systemd or the compose overlay at
# them without hunting. Absent when the repo has not been imported yet — say so
# rather than exporting a path to nothing.
if [ -d "$_fm_zenoh_root/comms" ]; then
  export FM_COMMS_DIR="$_fm_zenoh_root/comms"
  echo "comms: zenoh profile (domain ${ROS_DOMAIN_ID}, DDS on loopback) — configs in $FM_COMMS_DIR"
else
  echo "comms: zenoh profile (domain ${ROS_DOMAIN_ID}, DDS on loopback)" >&2
  echo "comms: comms/ is not imported — run 'vcs import < fm-ros2.repos' to get the configs." >&2
fi

unset _fm_zenoh_root
