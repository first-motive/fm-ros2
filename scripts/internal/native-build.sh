#!/usr/bin/env bash
# Native colcon build (the pixi `build` task, run inside `pixi run`). Two macOS-only
# concerns are handled here so `./run.sh --native` and a fresh install just work:
#
#   1. controller_manager: RoboStack's Humble binary crashes on controller activation
#      (a std::condition_variable waited with the mutex unlocked — ros2_control #604).
#      patch-ros2-control-macos.sh rebuilds the one-line-fixed dylib and swaps it in.
#      Self-healing: it re-applies if a `pixi install` restored the stock binary.
#
#   2. -dead_strip_dylibs: colcon links the ROS message packages'
#      *__rosidl_generator_py Python-extension libraries into C++ nodes (e.g.
#      pose_tracking_node); those load-crash inside a non-Python process on macOS.
#      The flag drops dylibs whose symbols are never used, matching how RoboStack
#      itself builds. Linux/Windows use their own linkers, so the flag is macOS-only.
#
#   3. Workspace message typesupport: the RMW bare-name dlopens a message package's
#      typesupport dylib, which on macOS only resolves through the node's rpath
#      ($CONDA_PREFIX/lib) — never the colcon install tree. link-typesupport-macos.sh
#      symlinks the workspace-built rosidl dylibs into $CONDA_PREFIX/lib after every
#      build so custom messages (mujoco_ros2_control_msgs, ...) work in C++ nodes.
#
# CMake's FindPython is pointed at the env interpreter — rosidl_generator_py cannot
# otherwise locate the conda Python's dev component on osx-arm64 and the failure
# aborts the whole build. Extra args passed to this script are forwarded to colcon.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

# The fm_data checkout ships a metapackage package.xml at its REPO ROOT. colcon stops
# descending the moment it finds a package.xml, so `src/fm_data` registers as the single
# package `fm_data` and the six nested packages inside it (fm_data_record,
# fm_data_sensors, …) are never built. Nothing errors — they are simply absent, and a
# launch that needs one dies later with a bare "package 'fm_data_sensors' not found".
#
# Name those directories as extra base paths so they are discovered too. This mirrors
# the data engine's own README and scripts/install/setup-recorder.sh, which pass the
# same dirs explicitly. Discovered rather than hardcoded so a new fm_data_* package is
# picked up without touching this script.
base_paths=("$root")
for candidate in "$root"/src/fm_data/*/; do
  [ -f "${candidate}package.xml" ] && base_paths+=("${candidate%/}")
done

args=(--symlink-install --base-paths "${base_paths[@]}" --cmake-args
      -DPython_EXECUTABLE="$CONDA_PREFIX/bin/python"
      -DPython3_EXECUTABLE="$CONDA_PREFIX/bin/python")

if [ "$(uname)" = "Darwin" ]; then
  # Heal the controller_manager macOS bug before building (no-op if already patched).
  bash "$here/../install/patch-ros2-control-macos.sh" || true
  # Re-assert the MuJoCo macOS patch set + mujoco_vendor shim (no-op when applied).
  bash "$here/../install/patch-mujoco-macos.sh" || true
  args+=(-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs
         -DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip_dylibs)
fi

colcon build "${args[@]}" "$@"

if [ "$(uname)" = "Darwin" ]; then
  # Expose the freshly built workspace message dylibs to bare-name dlopen.
  bash "$here/../install/link-typesupport-macos.sh"
fi
