#!/usr/bin/env bash
# Vendor external dependencies into external/ from external.repos.
# Pins are placeholders (see external.repos) — failures are loud, never silent.
# external/ is gitignored; this is a local working copy, not committed.
set -euo pipefail

# Silence the child-process noise the imports spew: git's detached-HEAD advice
# (repeated once per imported repo) and vcstool's pkg_resources deprecation
# warning. Scoped to this process env and inherited by vcs -> git/python children
# — no global git-config mutation.
export GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false
export PYTHONWARNINGS=ignore::UserWarning:pkg_resources

usage() {
  cat <<'EOF'
import-externals.sh — vendor external dependencies into external/ from external.repos

Imports externals, marks all but the built repos COLCON_IGNORE, and reports
versions. external/ is gitignored — a local working copy, not committed.

Usage: ./scripts/import-externals.sh [-h] [--verbose]

  -h, --help   show this help
  --verbose    also print the per-repo external version dump
EOF
}

item() { echo "$1"; }  # status line — mirrors install.sh, one place to restyle later

main() {
  local verbose=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --verbose) verbose=true; shift ;;
      *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
    esac
  done

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$ROOT"

  if ! command -v vcs >/dev/null 2>&1; then
    echo "ERROR: vcstool not found. Run inside the container, or: pip install vcstool" >&2
    return 1
  fi

  mkdir -p external
  item "Importing externals into external/ ..."
  vcs import external < external.repos

  # Selective workspace build: externals are sources to read or file-vendor, NOT to
  # build — except real ament packages whose code or xacro we consume directly:
  #   openarm_description  — xacro needs $(find openarm_description) + package://
  #   openarm_ros2         — bringup + bimanual MoveIt config (launch/config only)
  #   unitree_ros2         — the unitree_hg/go/api DDS message packages; unitree_hg
  #                          carries LowCmd, which the G1 arm_sdk bridge publishes
  # Everything else is file-vendored, reference-only, or Linux-only, so it gets a
  # COLCON_IGNORE marker:
  #   lerobot, so_arm, openarm_mujoco   file-vendored (URDF/MJCF/assets, not built)
  #   ros2_so_arm                       reference for the SO101 MoveIt config values
  #   unitree_sdk2, unitree_mujoco      reference for the arm_sdk loop + DDS sim
  #   feetech_ros2_driver, openarm_can  Linux + real-hardware backends only
  #   unitree_ros                       G1 description (flat URDF + meshes, file-vendored)
  local BUILD_DIRS=(openarm_description openarm_ros2 unitree_ros2)
  # Sub-packages inside a built repo that must stay OUT of the build. openarm_hardware
  # is C++ SocketCAN (Linux-only, needs openarm_can) and joins the build only on the
  # real backend; unitree_ros2/example/src is the C++ DDS demo set, which needs the full
  # CycloneDDS SDK — drop nested markers so the rest of each repo still builds.
  local NESTED_IGNORE=(openarm_ros2/openarm_hardware unitree_ros2/example/src)
  # Drop any blanket top-level ignore from an earlier import — markers are per-dir now.
  rm -f external/COLCON_IGNORE
  item "Marking externals COLCON_IGNORE (keeping ${BUILD_DIRS[*]} in the build) ..."
  local dir name keep b sub
  for dir in external/*/; do
    name="$(basename "$dir")"
    keep=false
    for b in "${BUILD_DIRS[@]}"; do
      [ "$name" = "$b" ] && keep=true && break
    done
    if [ "$keep" = true ]; then
      rm -f "$dir/COLCON_IGNORE"  # ensure it builds even on re-import
      continue
    fi
    touch "$dir/COLCON_IGNORE"
  done

  # Nested ignores: skip individual packages within a built repo.
  for sub in "${NESTED_IGNORE[@]}"; do
    if [ -d "external/${sub}" ]; then
      touch "external/${sub}/COLCON_IGNORE"
    fi
  done

  # Each built repo must exist post-import or its capability cannot build — fail loud.
  for b in "${BUILD_DIRS[@]}"; do
    if [ ! -d "external/${b}" ]; then
      echo "ERROR: external/${b} missing after import — its packages cannot build." >&2
      echo "       Check the ${b} entry in external.repos and re-run." >&2
      return 1
    fi
  done

  # Gravity-compensate the OpenArm MuJoCo model (for the vision mirror teleop path). The
  # vendored MJCF runs under full gravity, but MoveIt Servo does NO gravity compensation —
  # so while servoing the 7-DOF arm sags out of its 'ready' pose into the straight-elbow
  # singularity and locks there (the JTC's static hold masks this when idle). A real
  # OpenArm's joint drivers gravity-compensate; the simplest faithful equivalent in sim is
  # a weightless arm. Insert <option gravity="0 0 0"/> (idempotent).
  local openarm_mjcf="external/openarm_mujoco/v2/openarm_bimanual.xml"
  local mjcf_anchor='<compiler angle="radian" meshdir="assets" />'
  if [ -f "$openarm_mjcf" ] && ! grep -q 'gravity="0 0 0"' "$openarm_mjcf"; then
    # Insert <option gravity="0 0 0"/> after the compiler line. awk (not sed -i) for
    # macOS/Linux portability: BSD sed -i needs a backup-suffix arg and does not expand
    # \n in the replacement, so a sed one-liner silently corrupts the file on macOS.
    awk -v anchor="$mjcf_anchor" '
      { print }
      index($0, anchor) {
        print "  <option gravity=\"0 0 0\" />  <!-- gravity comp (Servo has none); see scripts/import-externals.sh -->"
      }
    ' "$openarm_mjcf" > "$openarm_mjcf.tmp" && mv "$openarm_mjcf.tmp" "$openarm_mjcf"
    item "Patched OpenArm MuJoCo model with gravity compensation (option gravity=0)."
  fi

  if [ "$verbose" = true ]; then
    item "Current versions:"
    vcs custom external --git --args rev-parse --short HEAD 2>/dev/null || vcs status external
  fi
  item "Done. ${BUILD_DIRS[*]} join the workspace build; other externals are COLCON_IGNORE'd."
  item "Reminder: pins in external.repos are placeholders — pin real tags."
}

main "$@"
