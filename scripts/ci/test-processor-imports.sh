#!/usr/bin/env bash
# The supervisors' Python deps are healed on the side that runs them (#134, #127).
#
#   ./scripts/ci/test-processor-imports.sh
#
# fm_data declares these deps and rosdep installs them where its database is
# usable. Inside the published Humble image it is not, and the miss does not
# surface at install — it surfaces at boot, as process_supervisor dying on
# `No module named 'jsonschema'` while systemd reports the service started.
#
# On a container-runtime host the install-time heal runs against the HOST's
# interpreter, which the nodes never use, so the boot path has to ask again inside
# the container. Both callers must reach one implementation, or the two answers
# drift.
#
# Every install is stubbed — this installs nothing and needs no ROS.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../internal/lib-processor.sh disable=SC1091
source scripts/internal/lib-processor.sh

fails=0
# The stubs below are called by the library, not from this file.
# shellcheck disable=SC2329
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# assert_installed <description> <expected>  (reads the stub's record)
assert_installed() {
  if [[ "$installed" == "$2" ]]; then
    pass "$1"
  else
    fail "$1 — installed '$installed', expected '$2'"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/install"
: > "$WORK/install/setup.bash"

echo "== a clean import needs no install =="
installed=""
# shellcheck disable=SC2329  # invoked by the library under test
fm_processor_install_for_ros_python() { installed="$installed $1|$2"; }
# shellcheck disable=SC2329  # invoked by the library under test
fm_processor_supervisor_import_error() { echo ""; }
if fm_processor_heal_imports "$WORK"; then
  pass "supervisors that import cleanly are left alone"
else
  fail "a clean import was reported as broken"
fi
assert_installed "nothing was installed" ""

echo "== a missing module is installed, then rechecked =="
installed=""
# The probe is called through $(...), so its state must live outside the subshell.
: > "$WORK/looks"
# shellcheck disable=SC2329  # invoked by the library under test
fm_processor_supervisor_import_error() {
  echo x >> "$WORK/looks"
  # Missing on the first look, clean once the install has run.
  if [[ "$(wc -l < "$WORK/looks")" -le 1 ]]; then
    echo "ModuleNotFoundError: No module named 'jsonschema'"
  fi
}
if fm_processor_heal_imports "$WORK"; then
  pass "the module named in the error is installed and the role proceeds"
else
  fail "the heal did not recover after installing the missing module"
fi
assert_installed "it installed exactly what was missing in the persistent workspace" " $WORK|jsonschema"

echo "== a missing WORKSPACE package is a build problem, not a pip one =="
installed=""
# shellcheck disable=SC2329  # invoked by the library under test
fm_processor_supervisor_import_error() {
  echo "ModuleNotFoundError: No module named 'fm_data_dataset'"
}
fm_processor_heal_imports "$WORK" >/dev/null 2>&1
assert_installed "no workspace package is pulled from an index to paper over a bad build" ""

echo "== a broken build is reported, not retried forever =="
installed=""
# shellcheck disable=SC2329  # invoked by the library under test
fm_processor_supervisor_import_error() { echo "SyntaxError: invalid syntax"; }
if fm_processor_heal_imports "$WORK" >/dev/null 2>&1; then
  fail "a syntax error was reported as healthy"
else
  pass "an error that is not a missing module fails the heal"
fi
assert_installed "nothing was installed for it" ""

echo "== both sides of the container boundary use the one implementation =="
for caller in scripts/install/setup-processor.sh scripts/service/processor-boot.sh; do
  if grep -q "fm_processor_heal_imports" "$caller"; then
    pass "$(basename "$caller") heals through the shared helper"
  else
    fail "$(basename "$caller") does not call fm_processor_heal_imports"
  fi
  if grep -q "_supervisor_import_error()" "$caller"; then
    fail "$(basename "$caller") carries its own copy of the probe"
  fi
done

echo "== the bag tier is installed on the side that runs the engine =="
# rosbags present: nothing to do.
installed=""
# shellcheck disable=SC2329  # invoked by the library under test
python3() { if [ "$2" = "import rosbags" ]; then return 0; fi; command python3 "$@"; }
fm_processor_heal_bag_tier "$WORK" >/dev/null 2>&1
assert_installed "a container that already has the tier installs nothing" ""
unset -f python3

echo "== the module name is parsed out of a REAL interpreter error =="
# The stubs above feed hand-written error text, which would keep passing if
# CPython changed how it words the failure. Ask the interpreter for the real
# thing: a format change then fails here rather than silently healing nothing.
real="$(python3 -c 'import fm_no_such_module_xyz' 2>&1 >/dev/null)"
parsed="$(printf '%s' "$real" | sed -n "s/.*No module named '\([^']*\)'.*/\1/p" | head -1)"
if [[ "$parsed" == "fm_no_such_module_xyz" ]]; then
  pass "the heal reads the module name this interpreter actually reports"
else
  fail "parsed '$parsed' from a real error — the heal would install nothing: $real"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "processor imports: all checks passed"
