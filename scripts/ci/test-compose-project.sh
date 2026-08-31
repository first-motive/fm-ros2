#!/usr/bin/env bash
# One compose project per role (#135). The sim stack and the dataset processor
# both run compose out of a `docker/` directory, so with no project name both
# landed on `docker` and shared one container: installing the processor
# recreated the container under a running sim and killed its launch.
#
#   ./scripts/ci/test-compose-project.sh
#
# Needs neither Docker nor ROS — the libraries only build the invocation.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../internal/lib-stack.sh disable=SC1091
source scripts/internal/lib-stack.sh
# shellcheck source=../internal/lib-processor.sh disable=SC1091
source scripts/internal/lib-processor.sh

processor_uv_root="$(mktemp -d)"
trap 'rm -rf "$processor_uv_root"' EXIT
export FM_PROCESSOR_UV_PYTHON_ROOT="$processor_uv_root"

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/uv-python"
export FM_PROCESSOR_UV_PYTHON_ROOT="$WORK/uv-python"

# assert_project <description> <expected> <invocation...>
assert_project() {
  local description="$1" expected="$2"
  shift 2
  local got="" prev="" arg
  for arg in "$@"; do
    if [[ "$prev" == "-p" ]]; then
      got="$arg"
      break
    fi
    prev="$arg"
  done
  if [[ "$got" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description — project '$got', expected '$expected'"
  fi
}

fm_stack_compose docker/compose.linux.yaml
assert_project "the sim stack runs under fm-sim" fm-sim "${FM_COMPOSE[@]}"
sim_invocation=("${FM_COMPOSE[@]}")

fm_processor_compose /workspace
assert_project "the processor runs under fm-processor" fm-processor "${FM_COMPOSE[@]}"

# The point of the two names: neither role can address the other's container.
if [[ "${sim_invocation[*]}" == "${FM_COMPOSE[*]}" ]]; then
  fail "the sim and the processor build the same compose invocation"
else
  pass "the sim and the processor address different projects"
fi

# A host running two checkouts of the SAME role needs a way out; role alone does
# not tell those apart.
# shellcheck disable=SC2034  # read by fm_compose_project, through the library
FM_COMPOSE_PROJECT=fm-sim-second
fm_stack_compose docker/compose.linux.yaml
assert_project "FM_COMPOSE_PROJECT overrides the role default" fm-sim-second "${FM_COMPOSE[@]}"
unset FM_COMPOSE_PROJECT

# Every verb that opens a container must name a project, or it reintroduces the
# collision from a different file. install.sh's teardown is checked the same way:
# a bare `down` there addresses a project nothing runs under.
before="$fails"
while IFS= read -r line; do
  fail "a compose invocation names no project: $line"
done < <(grep -rn 'COMPOSE=(docker compose\|docker compose -f docker/compose' \
  scripts/run scripts/internal install.sh |
  grep -vE ':[0-9]+:[[:space:]]*#' | grep -v -- '-p ')
[[ "$fails" == "$before" ]] && pass "every compose invocation a verb makes names a project"

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "compose projects: all checks passed"
