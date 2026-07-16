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
# CMake's FindPython is pointed at the env interpreter — rosidl_generator_py cannot
# otherwise locate the conda Python's dev component on osx-arm64 and the failure
# aborts the whole build. Extra args passed to this script are forwarded to colcon.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

args=(--symlink-install --cmake-args
      -DPython_EXECUTABLE="$CONDA_PREFIX/bin/python"
      -DPython3_EXECUTABLE="$CONDA_PREFIX/bin/python")

if [ "$(uname)" = "Darwin" ]; then
  # Heal the controller_manager macOS bug before building (no-op if already patched).
  bash "$here/../install/patch-ros2-control-macos.sh" || true
  args+=(-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs
         -DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip_dylibs)
fi

exec colcon build "${args[@]}" "$@"
