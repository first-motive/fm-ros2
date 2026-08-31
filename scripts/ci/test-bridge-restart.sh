#!/usr/bin/env bash
# A replaced container does not leave the host bridge routing twice.
#
#   ./scripts/ci/test-bridge-restart.sh
#
# The bridge keeps the routes it held for a container's old DDS participants, so
# after a recreate every sample crosses the fabric twice. Measured on fm-ws-01
# (2026-08-31): /joint_states 90 Hz against a 50 Hz cap, /tf 36 Hz against a 17 Hz
# source — both exactly halved by restarting the bridge. Nothing errors, which is
# why this is asserted rather than watched for.
#
# Every path that creates a container needs it, so the wiring is checked too: one
# verb fixed and another left out is the shape this bug already took.
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== reading compose's own report =="
printf ' Container fm-sim-fm-1  Recreated\n' > "$WORK/recreated.log"
printf ' Container fm-sim-fm-1  Created\n' > "$WORK/created.log"
printf ' Container fm-sim-fm-1  Running\n' > "$WORK/running.log"
printf ' Container fm-sim-fm-1  Started\n' > "$WORK/started.log"

if fm_compose_created_container "$WORK/recreated.log"; then
  pass "a recreated container is noticed"
else
  fail "missed a Recreated container"
fi
if fm_compose_created_container "$WORK/created.log"; then
  pass "a newly created container is noticed"
else
  fail "missed a Created container"
fi
if fm_compose_created_container "$WORK/running.log"; then
  fail "a reused container was treated as replaced — needless fabric churn"
else
  pass "a warm re-run that reuses a container leaves the fabric alone"
fi
if fm_compose_created_container "$WORK/started.log"; then
  fail "a merely started container was treated as replaced"
else
  pass "starting an existing container is not a replacement"
fi

echo "== the restart is scoped to the profile that shares the host's island =="
# No FM_CYCLONEDDS_XML: the container is not in the host's DDS island, so there is
# nothing for a stale route to duplicate.
restarted=""
# shellcheck disable=SC2329  # invoked by the library under test
systemctl() { restarted="yes"; return 0; }
# shellcheck disable=SC2329  # invoked by the library under test
sudo() { restarted="yes"; return 0; }
unset FM_CYCLONEDDS_XML
fm_compose_restart_bridge >/dev/null 2>&1
if [[ -z "$restarted" ]]; then
  pass "no bridge is touched off the zenoh profile"
else
  fail "the bridge was restarted with no host island to share"
fi
unset -f systemctl sudo

echo "== a fresh container gets the packages the image lacks =="
# The recorder needs the MCAP storage plugin to open a bag at all, and the loop
# creates its container through stack.sh, not the launcher — so the heal has to
# run on every creating path, not just one (gate 3.5).
for caller in scripts/internal/container.sh scripts/run/stack.sh; do
  if grep -q 'fm_compose_heal_stack_deps' "$caller"; then
    pass "$(basename "$caller") installs what the running image lacks"
  else
    fail "$(basename "$caller") creates a container and never heals its packages"
  fi
done
if grep -q 'rosbag2-storage-mcap' scripts/internal/lib-compose.sh; then
  pass "the MCAP storage plugin is one of them"
else
  fail "the MCAP storage plugin is not installed — the recorder cannot open a bag"
fi

echo "== every path that creates a container restarts the bridge =="
for caller in scripts/internal/container.sh scripts/run/stack.sh scripts/service/container-exec.sh; do
  if grep -q 'fm_compose_restart_bridge' "$caller"; then
    pass "$(basename "$caller") keeps the bridge honest"
  else
    fail "$(basename "$caller") creates a container and never restarts the bridge"
  fi
done

# The reasoning lives in one place; a second copy drifts from it.
before="$fails"
while IFS= read -r line; do
  fail "a private copy of the restart survives: $line"
done < <(grep -rn 'fm_restart_host_bridge' scripts/ 2>/dev/null \
  | grep -v "$(basename "$0")")
if [[ "$fails" == "$before" ]]; then
  pass "one implementation, shared"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "bridge restart: all checks passed"
