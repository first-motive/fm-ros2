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

# A replaced container is a new set of DDS participants, and the host's zenoh
# bridge does not always retire the routes it held for the old ones — it keeps both
# and publishes every sample twice. Nothing errors; the rate simply doubles, which
# reads like a downsample cap that stopped working. Measured on fm-ws-01
# (2026-08-31): /joint_states 90 Hz against a 50 Hz cap, /tf 36 Hz against a 17 Hz
# source, both exactly halved by restarting the bridge.
#
# This lives here rather than in one verb because every path that creates a
# container has the problem — `fm stack up`, the launcher, and the processor's
# service entry all do their own `up -d`.
#
# The real fix belongs upstream, in the bridge's own discovery: a route whose DDS
# writer is gone should be retired without anyone restarting anything.

# fm_compose_created_container <compose-log-file>
# 0 when compose reported creating or recreating a container in that run.
fm_compose_created_container() {  # compose-log-file
  local log="${1:?compose log}"
  [ -f "$log" ] || return 1
  grep -qE '(Created|Recreated)[[:space:]]*$' "$log"
}

# fm_compose_restart_bridge
# Restart this host's zenoh bridge so it rediscovers the container's graph from
# scratch. Best-effort: a laptop with no bridge unit, or one where the operator
# holds sudo, still gets its stack — it just keeps whatever routes it had.
#
# Only under the profile that put the container in the host's DDS island in the
# first place. FM_CYCLONEDDS_XML is set exactly then (see fm_compose_transport), so
# it is the condition rather than a second copy of the reasoning.
fm_compose_restart_bridge() {
  [ -n "${FM_CYCLONEDDS_XML:-}" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl is-active --quiet fm-zenoh-bridge 2>/dev/null || return 0
  if sudo -n systemctl restart fm-zenoh-bridge 2>/dev/null; then
    echo ">> restarted fm-zenoh-bridge — the container was replaced under it"
  else
    echo ">> NOTE: the container was replaced; restart the bridge to drop its stale routes:" >&2
    echo ">>       sudo systemctl restart fm-zenoh-bridge" >&2
  fi
}
