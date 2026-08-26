#!/usr/bin/env bash
# The stack's up/down question is "does anything PUBLISH the surface", not "does
# the name exist" (#136). A LAN subscriber — the Jetson recorder and watchdog
# both subscribe to /joint_states — puts the name on a container that is running
# nothing, and the old test read that as a stack already up.
#
#   ./scripts/ci/test-stack-publisher.sh
#
# `ros2` is stubbed with the exact output the workstation reported, so this runs
# on a bare runner in a second: the fixture participant is a subscriber-only
# entry in `ros2 topic info`, which is what a remote recorder looks like here.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../internal/lib-stack.sh disable=SC1091
source scripts/internal/lib-stack.sh

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# The stub stands in for the container: fm_stack_exec is the one door every ROS
# command in the library goes through, so replacing it swaps the whole graph.
# FIXTURE holds what `ros2 topic info <topic>` answers.
FIXTURE=""
fm_stack_exec() {
  shift # overlay
  case "$*" in
    "ros2 topic info "*) printf '%s\n' "$FIXTURE" ;;
    *) return 0 ;;
  esac
}

# A fixture participant that only subscribes — the fm-ws-01 reading from #136.
SUBSCRIBER_ONLY='Type: sensor_msgs/msg/JointState
Publisher count: 0
Subscription count: 2'
PUBLISHED='Type: sensor_msgs/msg/JointState
Publisher count: 1
Subscription count: 2'
# Ten publishers: the count is a number, not a digit, and a two-digit graph must
# not read as absent.
MANY='Type: sensor_msgs/msg/JointState
Publisher count: 10
Subscription count: 0'

FIXTURE="$SUBSCRIBER_ONLY"
if fm_stack_has_publisher overlay /joint_states; then
  fail "a subscriber-only /joint_states counts as up"
else
  pass "a subscriber-only /joint_states does not count as up"
fi

FIXTURE="$PUBLISHED"
if fm_stack_has_publisher overlay /joint_states; then
  pass "a published /joint_states counts as up"
else
  fail "a published /joint_states does not count as up"
fi

FIXTURE="$MANY"
if fm_stack_has_publisher overlay /joint_states; then
  pass "ten publishers count as up"
else
  fail "a two-digit publisher count is misread as none"
fi

# The bounded wait must give up on a graph that never publishes, rather than
# returning the subscriber as success.
FIXTURE="$SUBSCRIBER_ONLY"
if fm_stack_wait_publisher overlay /joint_states 1 2>/dev/null; then
  fail "the wait returns success on a subscriber-only topic"
else
  pass "the wait times out on a subscriber-only topic"
fi

# The verb itself must ask the new question. `ros2 topic list | grep` was the
# bug; it is fine in fm_stack_wait_topic, which episode.sh uses for a status
# topic, but stack.sh must not decide the stack's state that way.
if grep -qE 'ros2 topic list.*grep -qx' scripts/run/stack.sh; then
  fail "stack.sh still decides the stack's state from the topic name"
else
  pass "stack.sh decides the stack's state from a publisher"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "stack publisher detection: all checks passed"
