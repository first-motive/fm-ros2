#!/usr/bin/env bash
# macOS: symlink workspace-built rosidl message dylibs into $CONDA_PREFIX/lib.
#
# The RMW resolves a message package's typesupport library with a bare-name
# dlopen ("libX__rosidl_typesupport_introspection_cpp.dylib"). On macOS a
# bare-name dlopen searches DYLD_LIBRARY_PATH (stripped by SIP across exec of
# protected binaries, so effectively absent) and the RPATHs of the main
# executable — never the colcon install tree. Nodes built here carry
# $CONDA_PREFIX/lib on their rpath, so a symlink there makes the workspace
# message libraries resolvable, mirroring where an apt/conda install of the
# same package would land them. Applies to every workspace message package
# (mujoco_ros2_control_msgs, unitree_*, fm custom msgs, ...); self-healing:
# re-run after every build, and stale links from removed packages are pruned.
#
# Linux resolves the same dlopen through LD_LIBRARY_PATH + RUNPATH, so this is
# macOS-only. No-op elsewhere.
set -euo pipefail

[ "$(uname)" = "Darwin" ] || exit 0
: "${CONDA_PREFIX:?CONDA_PREFIX not set — run inside the pixi env}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

# Prune dangling links left behind by renamed or removed workspace packages.
for link in "$CONDA_PREFIX"/lib/lib*__rosidl_*.dylib; do
  [ -L "$link" ] || continue
  case "$(readlink "$link")" in
    "$root"/install/*) [ -e "$link" ] || rm -f "$link" ;;
  esac
done

linked=0
for lib in "$root"/install/*/lib/lib*__rosidl_*.dylib; do
  [ -e "$lib" ] || continue
  dest="$CONDA_PREFIX/lib/$(basename "$lib")"
  # Never shadow a real conda-provided library, only manage our own symlinks.
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo "link-typesupport: skipping $(basename "$lib") — a real file exists in \$CONDA_PREFIX/lib" >&2
    continue
  fi
  ln -sfn "$lib" "$dest"
  linked=$((linked + 1))
done

[ "$linked" -gt 0 ] && echo "link-typesupport: $linked workspace message dylibs linked into \$CONDA_PREFIX/lib"
exit 0
