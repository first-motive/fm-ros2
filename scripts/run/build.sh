#!/usr/bin/env bash
# The build verb: build this whole workspace, wherever it is being built.
#
#   ./scripts/run/build.sh                 # everything
#   ./scripts/run/build.sh --packages-select fm_control
#
# It exists because "build the workspace" was not one command. A bare
# `colcon build` from the workspace root misses the packages nested inside a repo
# that ships a metapackage at its root — colcon stops descending at the first
# package.xml — so `fm_data_dataset` and its siblings silently never built, and the
# absence surfaced much later as `Package 'fm_data_dataset' not found` when the
# loop tried to record (fm-ros2#147). CI had learned to spell the extra paths out;
# nothing a person types had.
#
# Extra arguments are forwarded to colcon, so `--packages-select`, `--cmake-args`
# and the rest work as they always do.
#
# The native (pixi) path has its own entry point, scripts/internal/native-build.sh,
# because it carries macOS toolchain fixes. Both resolve the base paths through the
# same helper, so neither can drift into building a different workspace.
set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=../internal/lib-buildtree.sh disable=SC1091
source scripts/internal/lib-buildtree.sh
# shellcheck source=../../lib.sh disable=SC1091
source lib.sh

usage() {
  cat <<'USAGE'
build.sh — build every package in this workspace

Usage: ./scripts/run/build.sh [colcon args...] [-h]

  -h, --help   show this help

Any other argument is passed straight to `colcon build`.
USAGE
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      return 0
      ;;
  esac

  # Resolved before the toolchain check so the selftest runs on a host that has no
  # colcon — which is every CI runner outside the container job.
  fm_buildtree_base_paths "$PWD"

  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: build resolved ${#FM_BASE_PATHS[@]} base path(s)"
    return 0
  fi

  if ! command -v colcon >/dev/null 2>&1; then
    echo "error: colcon is not on PATH — run this inside the container" >&2
    echo "       (./run.sh) or inside the pixi env (pixi run build)." >&2
    return 1
  fi

  item "building ${#FM_BASE_PATHS[@]} base path(s) — src/, external/, and the nested package repos"
  colcon build --symlink-install --base-paths "${FM_BASE_PATHS[@]}" "$@"
}

main "$@"
