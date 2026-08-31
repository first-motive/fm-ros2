#!/usr/bin/env bash
# The container joins the host's DDS island, or deliberately does not (#148).
#
#   ./scripts/ci/test-compose-transport.sh
#
# Under the zenoh profile the host's bridge runs Cyclone confined to loopback and
# finds peers by unicast probes to localhost. A host-networked container shares
# that loopback, so it must be put in the same island explicitly — left to stock
# Cyclone it elects another interface and the bridge routes nothing, silently.
#
# The inverse matters as much: on the macOS overlay the container is inside a VM
# with a loopback of its own, and confining DDS there hides its graph from the
# bridge running natively on the Mac. One function decides both, so both are
# asserted here.
#
# Needs neither Docker nor ROS — the library only shapes an environment.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../internal/lib-compose.sh disable=SC1091
source scripts/internal/lib-compose.sh

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# assert_var <description> <name> <expected>  ("" expects unset)
assert_var() {
  local description="$1" name="$2" expected="$3" got="${!2:-}"
  if [[ "$got" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description — $name is '${got:-<unset>}', expected '${expected:-<unset>}'"
  fi
}

# The profile file comms-zenoh.sh writes on the host. Faked here so the test needs
# no sourced profile and leaves no trace in the runner's $HOME.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOST_XML="$WORK/cyclonedds.xml"
echo "<CycloneDDS/>" > "$HOST_XML"

# The two inputs are what a sourced comms profile leaves in the environment.
# shellcheck disable=SC2034  # both are read by fm_compose_transport, via the library
reset() {  # profile  host-cyclone-uri
  unset ROS_LOCALHOST_ONLY FM_CYCLONEDDS_XML FM_CYCLONEDDS_URI RMW_IMPLEMENTATION
  FM_COMMS_PROFILE="$1"
  CYCLONEDDS_URI="${2:-}"
}

echo "== zenoh, host networking =="
reset zenoh "file://$HOST_XML"
fm_compose_transport docker/compose.linux.yaml
assert_var "DDS is confined to the shared loopback" ROS_LOCALHOST_ONLY 1
assert_var "the host's profile is mounted in" FM_CYCLONEDDS_XML "$HOST_XML"
assert_var "the container reads it at the mount path" \
  FM_CYCLONEDDS_URI file:///etc/fm-comms/cyclonedds.xml
transport_overlay="$(fm_compose_transport_overlay "$WORK")"
if grep -q "${HOST_XML}:/etc/fm-comms/cyclonedds.xml:ro" "$transport_overlay" \
  && grep -q 'CYCLONEDDS_URI: "file:///etc/fm-comms/cyclonedds.xml"' "$transport_overlay"; then
  pass "compose receives the loopback profile and its container URI"
else
  fail "the resolved transport never enters the compose service"
fi

echo "== zenoh, macOS (the container has its own loopback) =="
reset zenoh "file://$HOST_XML"
fm_compose_transport docker/compose.macos.yaml
assert_var "DDS is left free to leave the container" ROS_LOCALHOST_ONLY ""
assert_var "no profile is mounted" FM_CYCLONEDDS_XML ""

echo "== dds-lan, host networking (no loopback island to join) =="
reset dds-lan ""
fm_compose_transport docker/compose.linux.yaml
assert_var "DDS is left free to leave the container" ROS_LOCALHOST_ONLY ""
assert_var "no profile is mounted" FM_CYCLONEDDS_XML ""
if [ -n "$(fm_compose_transport_overlay "$WORK")" ] || [ -f "$WORK/.fm-compose-transport.yaml" ]; then
  fail "dds-lan retained the zenoh transport overlay"
else
  pass "a profile without a loopback island gets no transport overlay"
fi

echo "== none: this shell's middleware is left exactly as it was found =="
reset none ""
fm_compose_transport docker/compose.linux.yaml
assert_var "no middleware is chosen for a profile that chooses none" \
  RMW_IMPLEMENTATION ""
assert_var "DDS is left free to leave the container" ROS_LOCALHOST_ONLY ""

echo "== zenoh, host networking, no profile sourced at all =="
# The failure this guards: `${CYCLONEDDS_URI#file://}` on an unset variable aborts
# under `set -u`, which every verb runs with.
reset zenoh ""
unset CYCLONEDDS_URI
if (
  set -u
  fm_compose_transport docker/compose.linux.yaml
) >/dev/null 2>&1; then
  pass "an unset Cyclone config does not abort the caller"
else
  fail "fm_compose_transport aborted with no CYCLONEDDS_URI in the environment"
fi

echo "== zenoh, host networking, profile file missing =="
reset zenoh "file:///nonexistent/fm_cyclonedds_localhost.xml"
warning="$(fm_compose_transport docker/compose.linux.yaml 2>&1 >/dev/null)"
assert_var "a container is not confined to an island it cannot configure" \
  ROS_LOCALHOST_ONLY ""
if [[ -n "$warning" ]]; then
  pass "the missing profile is reported rather than swallowed"
else
  fail "a missing loopback profile produced no warning"
fi

for caller in scripts/internal/lib-stack.sh scripts/internal/lib-processor.sh scripts/internal/container.sh; do
  if grep -q 'fm_compose_transport_overlay' "$caller"; then
    pass "$(basename "$caller") adds the transport overlay"
  else
    fail "$(basename "$caller") drops the resolved transport before compose"
  fi
done

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "compose transport: all checks passed"
