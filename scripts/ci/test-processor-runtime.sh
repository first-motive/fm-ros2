#!/usr/bin/env bash
# The processor runtime resolution (#127): native on Humble or 22.04, container on
# a Linux host with docker, a plain refusal otherwise, and an explicit pin wins.
# The host checks are stubbed so this runs on any CI guest.
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. scripts/internal/lib-processor.sh

fail=0
check() {  # label expected  (stubs set by the caller)
  local got
  got="$(fm_processor_runtime 2>/dev/null)" || got=error
  if [ "$got" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 — got '$got', want '$2'"; fail=1; fi
}

uname() { echo Linux; }
fm_processor_is_jammy() { return 1; }
fm_processor_has_docker() { return 1; }

if [ -f /opt/ros/humble/setup.bash ]; then
  check "humble on the host resolves native" native
else
  check "no humble, no jammy, no docker refuses" error
  fm_processor_has_docker() { return 0; }
  check "linux + docker resolves container" container
  uname() { echo Darwin; }
  check "docker on macos still refuses" error
  fm_processor_is_jammy() { return 0; }
  check "jammy resolves native" native
fi
FM_PROCESSOR_RUNTIME=container check "an explicit pin wins" container

# The container side stacks three compose files; each must exist or be imported.
[ -f compose.processor.yaml ] && echo "PASS: processor overlay present" || { echo "FAIL: compose.processor.yaml missing"; fail=1; }
grep -q 'container-exec.sh' scripts/install/install-processor-service.sh \
  && echo "PASS: processor unit knows the container runtime" || { echo "FAIL: unit ignores runtime"; fail=1; }

[ "$fail" = 0 ] && echo "processor runtime: all checks passed"
exit "$fail"
