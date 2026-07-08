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
# 0 → a build/install tree baked for a prefix NOT under <expected_ws_root> exists
#     (the other toolchain built here); 1 → no tree, or the tree is ours.
#
# Two anchors, because a *partial* rebuild leaves a mixed tree — the failure mode
# that motivated this guard:
#   1. The top-level install/ prefix (fm_buildtree_prefix). Catches a fully
#      generated tree of the other toolchain. The baked prefix carries the
#      /install leaf (e.g. /ws/install), so a prefix under the root matches
#      "<root>/*".
#   2. The per-package build/<pkg>/colcon_command_prefix_*.sh scripts, which
#      source each dependency's install tree by ABSOLUTE path. colcon reuses these
#      at build time, and a rebuild that regenerates the top-level setup can still
#      leave them pointing at the other toolchain's prefix — colcon then aborts
#      with "The build time path ... doesn't exist". Flag any sourced
#      /.../install/... path that is not under <expected_ws_root>. This is the
#      authoritative anchor; (1) is a fast path.
fm_buildtree_is_foreign() {
  local expected="$1" prefix f p
  prefix=$(fm_buildtree_prefix)
  if [ -n "$prefix" ]; then
    case "$prefix" in
      "$expected"|"$expected"/*) : ;;
      *) return 0 ;;
    esac
  fi
  while IFS= read -r f; do
    while IFS= read -r p; do
      p=${p#\"}; p=${p%\"}                 # strip the surrounding quotes
      case "$p" in
        "$expected"/*) : ;;                # sources our own workspace — fine
        /*/install/*) return 0 ;;          # sources another prefix — foreign
      esac
    done < <(grep -oE '"/[^"]+/install/[^"]+"' "$f" 2>/dev/null)
  done < <(find build -maxdepth 2 -name 'colcon_command_prefix_*.sh' 2>/dev/null)
  return 1
}

# Drop the regenerable colcon outputs. Gitignored; rebuilt by the next build.
fm_buildtree_clear() {
  rm -rf build install log
}
