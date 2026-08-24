#!/usr/bin/env bash
# Guards for the stack / episode / dataset lifecycle verbs — the argument layer
# only, which is the half that needs no ROS, no Docker, and no hardware.
#
#   ./scripts/ci/test-lifecycle-verbs.sh
#
# FM_SELFTEST makes each verb stop after resolving its flags, so this asserts the
# resolution rather than the behaviour: sim is the default, `--real` reaches the
# hardware backend and the Linux overlay, a nonsense backend is refused, and the
# two ways of naming a backend cannot silently disagree.
#
# The loop itself is graded by scripts/ci/loop.sh inside the built container.
# This runs on a bare runner in a second, which is why the two are separate:
# a broken flag should not need a twenty-minute build to surface.
set -uo pipefail # not -e: run every check, aggregate failures at the end

usage() {
  cat <<'EOF'
test-lifecycle-verbs.sh — argument-layer guards for the lifecycle verbs

Usage: ./scripts/ci/test-lifecycle-verbs.sh [-h]

Every check runs; the script exits non-zero if any failed.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
  usage
  exit 0
}

cd "$(dirname "$0")/../.." || exit 1

export FM_SELFTEST=1

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# assert_resolves <description> <expected substring> <script> <args...>
assert_resolves() {
  local description="$1" expected="$2"
  shift 2
  local output
  if ! output=$("$@" 2>&1); then
    fail "$description — exited non-zero: $output"
    return
  fi
  if [[ "$output" != *"$expected"* ]]; then
    fail "$description — expected '$expected' in: $output"
    return
  fi
  pass "$description"
}

# assert_refuses <description> <expected exit code> <script> <args...>
assert_refuses() {
  local description="$1" expected="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local code=$?
  if [[ "$code" -ne "$expected" ]]; then
    fail "$description — exited $code, expected $expected"
    return
  fi
  pass "$description"
}

# Sim is the default everywhere, and it is the mujoco backend specifically —
# the claim the onboarding demo and the loop job both rest on.
assert_resolves "stack up defaults to mujoco" "backend=mujoco" \
  ./scripts/run/stack.sh up
assert_resolves "episode record defaults to mujoco" "backend=mujoco" \
  ./scripts/run/episode.sh record
assert_resolves "sim defaults to mujoco" "backend=mujoco" \
  ./scripts/run/sim.sh

# --real is the flag, and it reaches the Linux overlay rather than just renaming
# the backend.
assert_resolves "stack --real selects the hardware backend" "backend=real" \
  ./scripts/run/stack.sh up --real
assert_resolves "stack --real selects the Linux overlay" "overlay=compose.linux.yaml" \
  ./scripts/run/stack.sh up --real

# Two answers to one question are refused rather than resolved by flag order.
assert_refuses "stack refuses --real with an explicit --backend" 2 \
  ./scripts/run/stack.sh up --real --backend gazebo
assert_refuses "episode refuses --real with an explicit --backend" 2 \
  ./scripts/run/episode.sh record --real --backend gazebo
assert_refuses "dataset refuses --real with an explicit --backend" 2 \
  ./scripts/run/dataset.sh process --real --backend gazebo

# An unknown backend is refused by every verb, from the one shared list.
assert_refuses "stack refuses an unknown backend" 1 \
  ./scripts/run/stack.sh up --backend nope
assert_refuses "episode refuses an unknown backend" 1 \
  ./scripts/run/episode.sh record --backend nope
assert_refuses "dataset refuses an unknown backend" 1 \
  ./scripts/run/dataset.sh process --backend nope

# A missing action is a usage error, not a default action — `fm stack` with no
# verb must never be read as `fm stack up`.
assert_refuses "stack refuses a missing action" 2 ./scripts/run/stack.sh
assert_refuses "episode refuses a missing action" 2 ./scripts/run/episode.sh
assert_refuses "dataset refuses a missing action" 2 ./scripts/run/dataset.sh

# Every verb this repo mounts onto `fm` must be declared, or it is unreachable.
for verb in stack episode dataset; do
  if grep -q "\"$verb\"" fm.json; then
    pass "fm.json declares $verb"
  else
    fail "fm.json does not declare $verb"
  fi
done

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "lifecycle verbs: all checks passed"
