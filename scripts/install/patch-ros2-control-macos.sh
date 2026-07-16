#!/usr/bin/env bash
# Heal RoboStack's macOS controller_manager so ros2_control runs natively.
#
# WHY: on macOS the Humble controller_manager crashes the instant it activates a
# controller — it waits on a std::condition_variable with the switch mutex UNLOCKED
# (constructed with std::defer_lock), which macOS's libc++ rejects with
# "condition_variable::timed wait: mutex not locked". This is ros2_control issue
# #604 / PR #2391; the one-line fix (a plain lock) was merged to Rolling/Jazzy but
# NOT backported to Humble, so RoboStack's Humble binary still carries the bug and
# there is no runtime workaround. We rebuild ONLY controller_manager from the source
# tag that matches the installed version, apply the one-line fix, and swap the dylib.
#
# The rebuild uses -dead_strip_dylibs for the same reason native-build.sh does:
# colcon otherwise links the ROS message packages' *__rosidl_generator_py Python-
# extension libraries into the C++ node, and those load-crash inside a non-Python
# process on macOS. dead_strip drops dylibs whose symbols are never used.
#
# Idempotent + self-healing: safe to re-run — it skips the build when the env dylib
# is already ours, and rebuilds+swaps if a `pixi install` restored the stock binary.
# Called by run.sh's native path (scripts/run/native-build.sh) before every build and
# is a no-op off macOS. Every failure path leaves the stock binary untouched and
# exits 0 so it never blocks a build.
set -euo pipefail

[ "$(uname)" = "Darwin" ] || exit 0                 # macOS-only bug
[ -n "${CONDA_PREFIX:-}" ] || { echo "patch-ros2-control: not in the pixi env — skip" >&2; exit 0; }

ENV_DYLIB="$CONDA_PREFIX/lib/libcontroller_manager.dylib"
[ -f "$ENV_DYLIB" ] || exit 0                        # controller_manager not installed

# Installed controller_manager version -> the ros2_control git tag to patch from.
VER=$(ls "$CONDA_PREFIX"/conda-meta/ros-humble-controller-manager-*.json 2>/dev/null \
      | sed -E 's/.*controller-manager-([0-9.]+)-.*/\1/' | head -1)
[ -n "$VER" ] || { echo "patch-ros2-control: cannot read controller_manager version — skip" >&2; exit 0; }

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/fm_ros2/cm-patch/$VER"
PATCHED="$CACHE/libcontroller_manager.dylib"

# Build the patched dylib for this version once; a cache hit skips straight to the
# swap below (the expensive step is the build, not the copy). Re-copying every build
# is what makes this self-healing: a `pixi install` that restored the stock binary is
# corrected on the next run.
if [ ! -f "$PATCHED" ]; then
  echo "==> patching controller_manager $VER for macOS (ros2_control #604 / PR #2391)"
  SRC="$CACHE/src"
  rm -rf "$SRC"; mkdir -p "$SRC/ws/src"
  if ! git clone --depth 1 --branch "$VER" \
        https://github.com/ros-controls/ros2_control.git "$SRC/ros2_control" >/dev/null 2>&1; then
    echo "    could not clone ros2_control @ $VER — leaving the stock binary" >&2; exit 0
  fi
  CM="$SRC/ros2_control/controller_manager/src/controller_manager.cpp"
  # The fix: acquire the switch mutex (plain lock) instead of deferring it. Matches by
  # content so it is version-robust; if a future tag already dropped defer_lock the sed
  # is a harmless no-op (and the rebuilt-but-unpatched dylib is still correct).
  sed -i '' 's/switch_params_\.mutex, std::defer_lock)/switch_params_.mutex)/' "$CM"
  cp -r "$SRC/ros2_control/controller_manager" "$SRC/ws/src/"
  if ! ( cd "$SRC/ws" && colcon build --packages-select controller_manager \
          --cmake-args -DPython_EXECUTABLE="$CONDA_PREFIX/bin/python" \
          -DPython3_EXECUTABLE="$CONDA_PREFIX/bin/python" -DBUILD_TESTING=OFF \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs \
          -DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip_dylibs >/dev/null 2>&1 ); then
    echo "    patched build failed — leaving the stock binary" >&2; exit 0
  fi
  BUILT="$SRC/ws/install/controller_manager/lib/libcontroller_manager.dylib"
  [ -f "$BUILT" ] || { echo "    patched dylib not produced — skip" >&2; exit 0; }
  install_name_tool -id "@rpath/libcontroller_manager.dylib" "$BUILT" 2>/dev/null || true
  cp "$BUILT" "$PATCHED"
  rm -rf "$SRC"                                       # keep only the built dylib
fi

# Swap it in, backing up the stock binary once so `.orig` restores it.
[ -f "$ENV_DYLIB.orig" ] || cp "$ENV_DYLIB" "$ENV_DYLIB.orig"
cp "$PATCHED" "$ENV_DYLIB"
echo "==> controller_manager patched for macOS (restore: mv libcontroller_manager.dylib{.orig,})"
