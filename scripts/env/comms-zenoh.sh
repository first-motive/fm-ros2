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

# Give Cyclone room for a real graph on loopback, because the line above alone
# is not enough.
#
# Confined to `lo`, Cyclone finds the interface is not multicast-capable and
# falls back to unicast discovery. Unicast needs a distinct participant index per
# process, and the default ceiling is nine. A stack is well past that — the
# controller manager, the broadcaster, two spawners, robot_state_publisher, the
# foxglove bridge, then every `ros2` command run against it — and the tenth
# participant does not degrade, it fails outright:
#
#   Failed to find a free participant index for domain 0
#   rmw_create_node: failed to create domain, error Error
#
# The shape that reaches an operator is worse than that message suggests. The
# early nodes start and advertise, so the graph looks healthy and `stack up`
# passes; the process that fails is whichever one came last — the recorder, or a
# `ros2 topic echo`. This is how the sim-first loop failed the first time this
# profile became the default: publishers up, topics advertised, and
# `no /joint_states message within 20s`.
#
# So the ceiling is raised, multicast is turned off explicitly rather than being
# discovered to be unavailable, and localhost is named as a unicast peer.
#
# Do NOT add an <Interfaces> block here. ROS_LOCALHOST_ONLY already selects `lo`,
# and naming it again is refused: "lo: the same interface may not be selected
# twice", which takes down every node in the stack.
#
# The same shape as the dds-lan profile's FastDDS XML, for the same reason: the
# middleware needs a file, and generating it here keeps the host's transport a
# single `source` away rather than a setup step someone has to remember.
mkdir -p "$HOME/.ros"
_fm_zenoh_cyclone="$HOME/.ros/fm_cyclonedds_localhost.xml"
cat > "$_fm_zenoh_cyclone" <<'XML'
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain id="any">
    <General>
      <!-- Loopback has no multicast. Say so, rather than letting Cyclone
           discover it and log a warning on every node start. -->
      <AllowMulticast>false</AllowMulticast>
    </General>
    <Discovery>
      <!-- What replaces multicast: probe localhost for peers. -->
      <Peers>
        <Peer address="localhost"/>
      </Peers>
      <!-- The ceiling that matters. Nine is the default and a stack exceeds it. -->
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

unset _fm_zenoh_root _fm_zenoh_cyclone
