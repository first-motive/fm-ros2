#!/usr/bin/env bash
# The processor service must fail when its supervisors die (#134). `ros2 launch`
# exits 0 even when every node it started is dead, so the boot wrapper reported
# success, systemd logged `status=0/SUCCESS`, and Restart=on-failure never fired
# — the host looked provisioned while the processor was gone.
#
#   ./scripts/ci/test-processor-service-exit.sh
#
# `ros2` is stubbed, so the wrapper's exit policy is graded without ROS: a launch
# that returns at all has failed, unless it was stopped.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

WRAPPER=scripts/service/processor-boot.sh
UNIT_INSTALLER=scripts/install/install-processor-service.sh

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
# shellcheck disable=SC2016  # deliberate: the stub reads STUB_EXIT when it runs
printf '#!/usr/bin/env bash\nexit "${STUB_EXIT:-0}"\n' >"$stub_dir/ros2"
chmod +x "$stub_dir/ros2"

# assert_exit <description> <stub exit> <expected wrapper exit>
assert_exit() {
  local description="$1" stub="$2" expected="$3" got
  # FM_LAN_IP short-circuits the wrapper's bounded wait for a LAN address, which
  # a CI guest may never satisfy.
  STUB_EXIT="$stub" FM_LAN_IP=127.0.0.1 PATH="$stub_dir:$PATH" \
    bash "$WRAPPER" >/dev/null 2>&1
  got=$?
  if [[ "$got" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description — wrapper exited $got, expected $expected"
  fi
}

# The bug: a launch whose nodes all died still returns 0.
assert_exit "a launch that returns 0 is reported as a failure" 0 1
# A launch that fails outright keeps its own status, so the journal keeps it.
assert_exit "a launch that fails keeps its exit code" 2 2
# 143 = SIGTERM: the unit's ExecStop kills the launch by name under the container
# runtime, and a deliberate stop must not read as a failure.
assert_exit "a launch stopped with SIGTERM is a clean stop" 143 0

# systemd parses the unit's Exec lines itself and warned "Ignoring unknown escape
# sequences" on the escaped dot in the stop pattern.
if grep -q 'process_session\\\.launch' "$UNIT_INSTALLER"; then
  fail "the unit's stop pattern still carries a backslash escape"
else
  pass "the unit's stop pattern carries no backslash escape"
fi

# A stop must reach the wrapper, whose trap ends the launch and exits clean.
# Signalling only the launch left a deliberate stop in `failed (exit-code)`,
# because `ros2 launch` exits 0 on SIGTERM — the case the wrapper now reports as
# a failure.
if grep -q "stop 'processor-boot.sh'" "$UNIT_INSTALLER"; then
  pass "the unit stops the wrapper by name"
else
  fail "the unit's stop never reaches the wrapper"
fi

# The restart policy is the other half: a real failure must be acted on.
if grep -q '^Restart=on-failure' "$UNIT_INSTALLER"; then
  pass "the unit restarts on failure"
else
  fail "the unit has no Restart=on-failure"
fi

# The deps the supervisors import are checked at install time, under the ROS
# interpreter — the engine venv is not what the nodes run on.
if grep -q '_supervisor_import_error' scripts/install/setup-processor.sh; then
  pass "the installer verifies the supervisors' imports"
else
  fail "the installer never verifies the supervisors' imports"
fi

# The processor installer owns a separate, atomic Ohio service env file. This
# keeps the opt-in values out of the general host config and refuses conflicting
# pre-existing selectors instead of silently appending a partial route.
if grep -q '^AWS_ENVFILE=/etc/fm-processor-aws.env' "$UNIT_INSTALLER" && \
   grep -q '_check_aws_env_conflicts' "$UNIT_INSTALLER" && \
   grep -q '_write_aws_service_env' "$UNIT_INSTALLER" && \
   grep -q 'EnvironmentFile=-\$AWS_ENVFILE' "$UNIT_INSTALLER"; then
  pass "the installer uses an atomic, conflict-checked Ohio service env file"
else
  fail "the installer does not persist Ohio service settings safely"
fi
preflight_line="$(grep -n '_preflight_aws_service_env || return 1' "$UNIT_INSTALLER" | head -1 | cut -d: -f1)"
unit_write_line="$(grep -n 'sudo tee "\$UNIT"' "$UNIT_INSTALLER" | head -1 | cut -d: -f1)"
if [ -n "$preflight_line" ] && [ -n "$unit_write_line" ] && [ "$preflight_line" -lt "$unit_write_line" ] && \
   grep -q 'Refusing to overwrite it' "$UNIT_INSTALLER"; then
  pass "conflicting Ohio settings are rejected before unit writes"
else
  fail "conflicting Ohio settings could mutate the service before rejection"
fi

# Container boot resolves the host-owned nested data package commit before Docker
# entry (container root is intentionally rejected by Git ownership checks).
if grep -q 'FM_PROCESSOR_ANNOTATE_GIT_COMMIT' scripts/service/container-exec.sh && \
   grep -q 'src/fm_data.*rev-parse' scripts/service/container-exec.sh && \
   grep -q 'FM_AWS_INFERENCE_SERVICE_MODE' scripts/service/container-exec.sh; then
  pass "container entry forwards a validated host data package commit"
else
  fail "container entry does not establish source identity before launch"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "processor service exit policy: all checks passed"
