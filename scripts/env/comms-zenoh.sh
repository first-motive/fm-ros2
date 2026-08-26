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
#     ROS_DOMAIN_ID=7 FM_COMMS=zenoh source scripts/env/comms.sh

_fm_zenoh_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

# Cyclone, not FastDDS. Under a bridge the DDS graph is loopback-only and small,
# which is where Cyclone is the better fit — and zenoh-bridge-ros2dds is developed
# and tested against it upstream. The foxglove profile keeps FastDDS, so the two
# profiles differ in RMW as well as transport; that is deliberate, and it is why
# a host must not mix them in one graph.
#
# Available natively via pixi (ros-humble-rmw-cyclonedds-cpp in pixi.toml) and in
# the container (fm-docker's Dockerfile.base). A host missing it fails loudly at
# node start rather than silently falling back.
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

# Confine DDS to loopback. Cross-host traffic is the bridge's job now, so a DDS
# participant that reaches the LAN would duplicate what Zenoh already carries —
# and re-introduce the multi-NIC delivery failures the dds-lan profile has to
# work around.
export ROS_LOCALHOST_ONLY=1

# Tell Cyclone how to discover peers on loopback, because the line above is not
# enough on its own.
#
# Cyclone discovers over multicast by default. Confined to loopback it therefore
# needs multicast ON the loopback interface — and `lo` inside a container has it
# disabled, as it does on several Linux hosts. The result is the worst shape a
# failure can take: every node starts, every publisher advertises, and no
# subscriber ever matches. Nothing errors; the graph is simply empty. That is
# exactly how the sim-first loop failed the first time this profile became the
# default (publishers up, `no /joint_states message within 20s`).
#
# So multicast is turned off and discovery is pointed at an explicit localhost
# peer instead. Unicast on loopback needs no interface support and behaves the
# same in a container, on a rig, and on a laptop.
#
# The same shape as the dds-lan profile's FastDDS XML, for the same reason: the
# middleware needs a file, and generating it here keeps the host's transport a
# single `source` away rather than a setup step someone has to remember.
_fm_zenoh_iface=lo
[ "$(uname -s)" = Darwin ] && _fm_zenoh_iface=lo0

mkdir -p "$HOME/.ros"
_fm_zenoh_cyclone="$HOME/.ros/fm_cyclonedds_localhost.xml"
cat > "$_fm_zenoh_cyclone" <<XML
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="any">
    <General>
      <!-- Loopback only. ROS_LOCALHOST_ONLY says the same thing; naming the
           interface here means Cyclone does not have to guess which one it
           meant on a host with several. -->
      <Interfaces>
        <NetworkInterface name="${_fm_zenoh_iface}" multicast="false"/>
      </Interfaces>
      <AllowMulticast>false</AllowMulticast>
    </General>
    <Discovery>
      <!-- The unicast peer that replaces multicast discovery. -->
      <Peers>
        <Peer address="localhost"/>
      </Peers>
      <ParticipantIndex>auto</ParticipantIndex>
      <MaxAutoParticipantIndex>60</MaxAutoParticipantIndex>
    </Discovery>
  </Domain>
</CycloneDDS>
XML
export CYCLONEDDS_URI="file://$_fm_zenoh_cyclone"

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

unset _fm_zenoh_root _fm_zenoh_iface _fm_zenoh_cyclone
