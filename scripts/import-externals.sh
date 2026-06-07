#!/usr/bin/env bash
# Vendor external dependencies into src/external/ from external.repos.
# Pins are placeholders (see external.repos) — failures are loud, never silent.
# src/external/ is gitignored; this is a local working copy, not committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v vcs >/dev/null 2>&1; then
  echo "ERROR: vcstool not found. Run inside the container, or: pip install vcstool" >&2
  exit 1
fi

mkdir -p src/external
echo "==> Importing externals into src/external/ ..."
vcs import src/external < external.repos

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
BUILD_DIRS=(openarm_description openarm_ros2 unitree_ros2)
# Sub-packages inside a built repo that must stay OUT of the build. openarm_hardware
# is C++ SocketCAN (Linux-only, needs openarm_can) and joins the build only on the
# real backend; unitree_ros2/example/src is the C++ DDS demo set, which needs the full
# CycloneDDS SDK — drop nested markers so the rest of each repo still builds.
NESTED_IGNORE=(openarm_ros2/openarm_hardware unitree_ros2/example/src)
# Drop any blanket top-level ignore from an earlier import — markers are per-dir now.
rm -f src/external/COLCON_IGNORE
echo "==> Marking externals COLCON_IGNORE (keeping ${BUILD_DIRS[*]} in the build) ..."
for dir in src/external/*/; do
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
  if [ -d "src/external/${sub}" ]; then
    touch "src/external/${sub}/COLCON_IGNORE"
  fi
done

# Each built repo must exist post-import or its capability cannot build — fail loud.
for b in "${BUILD_DIRS[@]}"; do
  if [ ! -d "src/external/${b}" ]; then
    echo "ERROR: src/external/${b} missing after import — its packages cannot build." >&2
    echo "       Check the ${b} entry in external.repos and re-run." >&2
    exit 1
  fi
done

echo "==> Current versions:"
vcs custom src/external --git --args rev-parse --short HEAD 2>/dev/null || vcs status src/external
echo "==> Done. ${BUILD_DIRS[*]} join the workspace build; other externals are COLCON_IGNORE'd."
echo "==> Reminder: pins in external.repos are placeholders — pin real tags."
