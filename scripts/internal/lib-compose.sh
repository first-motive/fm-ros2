#!/usr/bin/env bash
# The compose project each role owns. Sourced by the stack library, the
# processor library, and the run verbs — never executed.
#
# Compose derives a project name from the directory the compose file sits in
# when none is given. Every role here runs compose out of its checkout's
# `docker/`, so the sim stack in ~/fm/fm_ros2 and the processor in
# ~/processor/fm_ros2 both landed on the project `docker` and shared one
# container, `docker-fm-1`. Installing the processor recreated the container
# under the running sim, killing the launch and its logs; `fm stack up`
# afterwards did the same back (#135).
#
#   sim         fm-sim        the robot stack: stack / sim / teleop / foxglove / run.sh
#   processor   fm-processor  the dataset processor's own workspace
#
# One project per role, so each verb's `up`, `exec`, and `down` reach only what
# that role started. FM_COMPOSE_PROJECT overrides it for a host that runs two
# checkouts of the SAME role — role alone does not tell those apart.

# fm_compose_project <role>
# Echo the compose project name for a role.
fm_compose_project() {
  printf '%s\n' "${FM_COMPOSE_PROJECT:-fm-${1:?compose role}}"
}

# fm_compose_transport <host-overlay-path>
# Export the transport knobs docker/compose.yaml reads, resolved for THIS host and
# the overlay the container will run under. Call it before any compose invocation
# that CREATES a container — the values are baked at creation, so an `exec` into a
# container started without them cannot recover.
#
# Requires scripts/env/comms.sh to have been sourced first: this reads what the
# profile resolved rather than resolving the transport a second time.
#
# The host-networked case is the whole reason this exists. Under the zenoh profile
# the host's bridge runs Cyclone confined to loopback, discovering peers by unicast
# probes to localhost. A container sharing the host's network namespace shares that
# loopback, so it belongs in the same island and is put there explicitly. Left to
# stock Cyclone it elects some other interface and reaches the bridge only when a
# participant happens to answer a probe — which held for hours on fm-ws-01 and then
# stopped after a container recreation, with no error on either side (fm-ros2#148).
#
# Every other case exports nothing. On the macOS overlay the container is inside a
# VM with its own loopback, where confining DDS really would hide the graph from a
# bridge running natively on the Mac; under dds-lan or none there is no loopback
# island to join.
fm_compose_transport() {
  local overlay="${1:?host compose overlay}" host_xml
  export FM_COMMS_PROFILE="${FM_COMMS_PROFILE:-none}"
  # `none` means this shell's middleware is left exactly as it was found, so it
  # gets no default either — naming one here would make the profile a lie.
  if [ "$FM_COMMS_PROFILE" != none ]; then
    export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
  fi
  unset FM_CYCLONEDDS_XML FM_CYCLONEDDS_URI

  if [ "${overlay##*/}" != compose.linux.yaml ] || [ "$FM_COMMS_PROFILE" != zenoh ]; then
    unset ROS_LOCALHOST_ONLY
    return 0
  fi

  # The profile generated this file on the host; the container reads the same
  # bytes through the mount. Deriving the path from CYCLONEDDS_URI rather than
  # rebuilding it keeps one owner of where the file lives (comms-zenoh.sh).
  host_xml="${CYCLONEDDS_URI:-}"
  host_xml="${host_xml#file://}"
  if [ -z "$host_xml" ] || [ ! -f "$host_xml" ]; then
    echo "comms: no loopback Cyclone profile at '${host_xml:-<unset>}' — the container" >&2
    echo "       will run stock Cyclone and the host bridge may route nothing." >&2
    unset ROS_LOCALHOST_ONLY
    return 0
  fi

  export ROS_LOCALHOST_ONLY=1
  export FM_CYCLONEDDS_XML="$host_xml"
  # A container path, not the host's: $HOME is not mounted, and the mount target
  # is fixed by docker/compose.yaml.
  export FM_CYCLONEDDS_URI=file:///etc/fm-comms/cyclonedds.xml
}
