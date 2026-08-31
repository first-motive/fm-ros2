#!/usr/bin/env bash
# The dataset verbs run where the engine is (#145).
#
#   ./scripts/ci/test-dataset-runtime.sh
#
# `fm dataset process` resolved the SIM stack's compose project, so on a
# workstation it ran the engine inside a container built without it and reported
# `Package 'fm_data_dataset' not found` — while the processor container sat beside
# it with the engine built and the data directories mounted. The routing is the
# whole bug, so the routing is what is asserted.
#
# Every host check is stubbed, so this runs on any CI guest with no Docker, no ROS
# and no processor role installed.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../internal/lib-processor.sh disable=SC1091
source scripts/internal/lib-processor.sh

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/uv-python"
# The merged processor compose contract requires the provisioned host's managed
# Python tree. This test stubs that prerequisite because it verifies routing only.
export FM_PROCESSOR_UV_PYTHON_ROOT="$WORK/uv-python"

echo "== the role marker decides =="
FM_PROCESSOR_ENV_FILE="$WORK/absent.env"
if fm_processor_installed; then
  fail "a host with no processor EnvironmentFile claimed the role"
else
  pass "a host with no processor role falls back to the stack"
fi

FM_PROCESSOR_ENV_FILE="$WORK/fm-processor.env"
touch "$FM_PROCESSOR_ENV_FILE"
if fm_processor_installed; then
  pass "a host with the processor EnvironmentFile owns the role"
else
  fail "the processor role went undetected with its EnvironmentFile present"
fi

echo "== the command lands in the processor's runtime =="
# The runtime picker reads this; the point here is the routing, not the picking.
# shellcheck disable=SC2034  # read by fm_processor_runtime, through the library
FM_PROCESSOR_RUNTIME=native
got="$(fm_processor_exec "$PWD" echo landed-native)"
if [[ "$got" == "landed-native" ]]; then
  pass "a Humble host runs the engine in place"
else
  fail "the native runtime did not run the command — got '$got'"
fi

# Container: the invocation must address the processor's OWN compose project, and
# route through the image entrypoint so ROS and the overlay are sourced.
# shellcheck disable=SC2034  # read by fm_processor_runtime, through the library
FM_PROCESSOR_RUNTIME=container
# shellcheck disable=SC2329  # invoked by the library, which resolves it as a command
docker() { printf '%s\n' "$*"; }
got="$(fm_processor_exec /workspace echo landed-container)"
unset -f docker

case "$got" in
  *"-p fm-processor"*) pass "the processor container is addressed, not the sim stack's" ;;
  *) fail "the invocation names the wrong compose project: $got" ;;
esac
case "$got" in
  *"compose.processor.yaml"*) pass "the processor overlay is stacked in" ;;
  *) fail "the processor overlay is missing: $got" ;;
esac
case "$got" in
  *"/ros_entrypoint.sh echo landed-container"*) pass "the command routes through the image entrypoint" ;;
  *) fail "the command bypasses the entrypoint: $got" ;;
esac

echo "== the verb itself routes, not only the library =="
# The checks above exercise the library. This one exercises dataset.sh, so a
# regression that stops calling the wrapper is caught where it happens.
# The marker path is exported INSIDE the substitution: a `VAR=x got=$(...)`
# prefix sets a second variable, it does not reach the command.
got="$(FM_PROCESSOR_ENV_FILE="$WORK/absent.env" FM_SELFTEST=1 \
  ./scripts/run/dataset.sh process 2>/dev/null | tail -1)"
case "$got" in
  *"runtime=stack"*) pass "a host with no processor role runs the verb on the stack" ;;
  *) fail "the verb did not fall back to the stack: $got" ;;
esac

got="$(FM_PROCESSOR_ENV_FILE="$WORK/fm-processor.env" FM_SELFTEST=1 \
  ./scripts/run/dataset.sh process 2>/dev/null | tail -1)"
case "$got" in
  *"runtime=processor"*) pass "a host with the processor role runs the verb there" ;;
  *) fail "the verb ignored the processor role: $got" ;;
esac

# Every engine call must go through the wrapper. A call site left on
# fm_stack_exec reintroduces the bug in one verb while the others are fixed.
before="$fails"
# The wrapper's own fallback line is the one legitimate use; match it literally.
# shellcheck disable=SC2016  # deliberate: this is a pattern, not an expansion
while IFS= read -r line; do
  fail "an engine call bypasses dataset_exec: $line"
done < <(grep -n 'fm_stack_exec' scripts/run/dataset.sh \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vF 'fm_stack_exec "$overlay" "$@"')
[[ "$fails" == "$before" ]] && pass "no engine call bypasses the wrapper"

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "dataset runtime: all checks passed"
