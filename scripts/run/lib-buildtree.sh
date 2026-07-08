#!/usr/bin/env bash
# Shared build-tree guard for the fm_ros2 run paths. Sourced by
# scripts/run/container.sh and scripts/run/native.sh — never executed.
#
# colcon bakes the absolute workspace prefix into the generated install/ setup
# scripts (install/setup.sh hardcodes COLCON_CURRENT_PREFIX). The container
# toolchain builds under /ws; the native (pixi/RoboStack) toolchain builds under
# the host repo path (/Users/... or C:\...). The two trees are NOT
# interchangeable: reuse the wrong one and colcon aborts on the first package with
#   The build time path "<baked>/install/<pkg>" doesn't exist
# This guard reads the baked prefix and, when it belongs to the *other*
# toolchain, clears the regenerable build/ install/ log/ so the current path
# rebuilds clean. All three are gitignored; a rebuild fully restores them.

# Echo the absolute prefix colcon baked into the install tree, or nothing when no
# tree is present. Reads the top-level generated setup script (setup.sh, then
# local_setup.sh as a fallback) and pulls the single literal-path assignment to
# the COLCON_CURRENT_PREFIX chain var — the `if [ -z "$COLCON_CURRENT_PREFIX" ]`
# lines are conditionals, not the baked value, so match only an assignment whose
# value starts with a slash.
fm_buildtree_prefix() {
  local f line val
  for f in install/setup.sh install/local_setup.sh; do
    [ -f "$f" ] || continue
    line=$(grep -m1 -E "_COLCON_CURRENT_PREFIX=[\"']?/" "$f") || continue
    val=${line#*_COLCON_CURRENT_PREFIX=}   # strip up to and including the '='
    val=${val#[\"\']}                      # drop a leading quote, if any
    val=${val%%[\"\']*}                    # drop from a trailing quote, if any
    printf '%s\n' "$val"
    return 0
  done
}

# fm_buildtree_is_foreign <expected_ws_root>
# 0 → an install tree exists whose baked prefix is NOT under <expected_ws_root>
#     (the other toolchain built here); 1 → no tree, or the tree is ours.
# The baked prefix includes the /install leaf (e.g. /ws/install), so a prefix
# under the workspace root matches "<root>/*".
fm_buildtree_is_foreign() {
  local expected="$1" prefix
  prefix=$(fm_buildtree_prefix)
  [ -n "$prefix" ] || return 1
  case "$prefix" in
    "$expected"|"$expected"/*) return 1 ;;
    *) return 0 ;;
  esac
}

# Drop the regenerable colcon outputs. Gitignored; rebuilt by the next build.
fm_buildtree_clear() {
  rm -rf build install log
}
