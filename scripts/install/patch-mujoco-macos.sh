#!/usr/bin/env bash
# macOS: materialize the MuJoCo sim backend's two source packages for the native
# build. The container installs ros-humble-mujoco-ros2-control from apt; RoboStack
# has no osx-arm64 build, so the native Mac builds both from source:
#
#   1. external/mujoco_vendor — a shim CMake package (from scripts/install/shims/).
#      Upstream's mujoco_vendor hard-fails on Darwin; the shim re-exports conda's
#      libmujoco and symlinks opt/mujoco_vendor -> $CONDA_PREFIX so upstream's
#      conda-install code path finds libsimulate.dylib + simulate.h.
#
#   2. external/mujoco_ros2_control (tag 0.0.3, imported via external.repos) —
#      patched by scripts/install/patches/mujoco-ros2-control-macos.patch:
#      GNU-ld-only link flags guarded off, namespaced CMake targets downgraded to
#      the ros2_control 2.51 old-style ament vars (the py311 RoboStack env caps
#      ros2_control below the 2.54 the tag expects), Mach-O rpaths (@loader_path +
#      link-path rpath so $CONDA_PREFIX/lib resolves), a %lu format fix, and
#      camera rendering gated off in headless mode (its GLFW window is illegal off
#      the main thread under Cocoa).
#
# Idempotent and self-healing: the shim copy is a plain overwrite, the patch is
# skipped when already applied, and a checkout that matches neither state (a
# re-pin without a patch refresh) fails loud. No-op off macOS.
set -euo pipefail

[ "$(uname)" = "Darwin" ] || exit 0

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
shim_src="$here/shims/mujoco_vendor"
patch_file="$here/patches/mujoco-ros2-control-macos.patch"
target="$root/external/mujoco_ros2_control"

# 1. mujoco_vendor shim — always (re)written, cheap and idempotent.
mkdir -p "$root/external/mujoco_vendor"
cp -f "$shim_src/CMakeLists.txt" "$shim_src/package.xml" "$root/external/mujoco_vendor/"
echo "patch-mujoco: mujoco_vendor shim in place"

# 2. mujoco_ros2_control source patch.
if [ ! -d "$target" ]; then
  echo "patch-mujoco: external/mujoco_ros2_control not imported yet — skipping (run import-externals.sh first)" >&2
  exit 0
fi

if git -C "$target" apply --reverse --check "$patch_file" 2>/dev/null; then
  echo "patch-mujoco: mujoco_ros2_control already patched"
elif git -C "$target" apply --check "$patch_file" 2>/dev/null; then
  git -C "$target" apply "$patch_file"
  echo "patch-mujoco: mujoco_ros2_control patched for macOS"
else
  echo "ERROR: mujoco-ros2-control-macos.patch applies neither forward nor reverse." >&2
  echo "       external/mujoco_ros2_control has drifted from the pinned 0.0.3 state —" >&2
  echo "       re-import it (or refresh the patch) and re-run." >&2
  exit 1
fi
