#!/usr/bin/env bash
# The build verb sees the whole workspace (#147).
#
#   ./scripts/ci/test-build-verb.sh
#
# colcon stops descending at the first package.xml, so a repo that ships a
# metapackage at its root hides every package nested inside it. A bare
# `colcon build` therefore built neither fm_data_dataset nor its siblings, and the
# absence surfaced an hour later as `Package 'fm_data_dataset' not found` when the
# loop tried to record. The fix is a discovered list of base paths; this asserts it
# discovers, rather than that someone remembered to type a directory.
#
# Runs against a synthetic workspace, so it needs neither colcon nor a populated
# src/ and cannot go stale as the real one changes shape.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../internal/lib-buildtree.sh disable=SC1091
source scripts/internal/lib-buildtree.sh

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

manifest() {  # dir
  mkdir -p "$1"
  printf '<package format="3"><name>%s</name></package>\n' "$(basename "$1")" > "$1/package.xml"
}

# A repo with a metapackage at its root, hiding two packages.
manifest "$WORK/src/fm_data"
manifest "$WORK/src/fm_data/fm_data_dataset"
manifest "$WORK/src/fm_data/fm_data_record"
# A repo with no root manifest: colcon finds its packages unaided.
manifest "$WORK/src/fm_robot/fm_control"
# An external, reached through the root base path.
manifest "$WORK/external/openarm_description"

fm_buildtree_base_paths "$WORK"
paths="${FM_BASE_PATHS[*]}"

case " $paths " in
  *" $WORK "*) pass "the workspace root is a base path" ;;
  *) fail "the workspace root is not a base path" ;;
esac

for nested in fm_data_dataset fm_data_record; do
  case "$paths" in
    *"src/fm_data/$nested"*) pass "$nested is reachable behind its metapackage" ;;
    *) fail "$nested is hidden by src/fm_data's root manifest" ;;
  esac
done

# A repo without a root manifest must NOT be expanded: naming its packages as base
# paths as well would register each of them twice, which colcon refuses outright.
case "$paths" in
  *fm_control*) fail "fm_control was named separately though nothing hides it" ;;
  *) pass "a repo with no root manifest is left to the root base path" ;;
esac

# Discovery, not a list: a package added today must need no edit here.
manifest "$WORK/src/fm_data/fm_data_tomorrow"
fm_buildtree_base_paths "$WORK"
case "${FM_BASE_PATHS[*]}" in
  *fm_data_tomorrow*) pass "a newly added nested package is found without an edit" ;;
  *) fail "the base paths are a hardcoded list, not a discovery" ;;
esac

echo "== the assembled CI build uses the same discovery =="
if grep -q 'fm_buildtree_base_paths /ws' .github/workflows/ci.yml \
  && grep -q 'colcon build --symlink-install --base-paths' .github/workflows/ci.yml \
  && grep -q 'colcon list --base-paths' .github/workflows/ci.yml; then
  pass "CI build and test can see packages hidden by a repo metapackage"
else
  fail "CI bypasses the shared nested-package discovery"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "build verb: all checks passed"
