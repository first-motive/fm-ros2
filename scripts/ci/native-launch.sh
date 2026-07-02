#!/usr/bin/env bash
# Native launch smoke — proves the pixi env carries every runtime dependency the
# fm_tui launcher and its dispatch targets need. The build alone cannot catch a
# missing runtime dep (colcon ignores install_requires and launch-time packages),
# so this imports the launcher module and resolves every registry launch target
# with `ros2 launch --print` — package lookups run, no nodes start, no GUI needed.
#
# Assumes the workspace is imported and built (pixi run build). CI runs it on the
# macOS runner after a full env install; it runs locally the same way:
#
#   ./scripts/ci/native-launch.sh
set -euo pipefail

usage() {
  cat <<'EOF'
native-launch.sh — smoke the native env's runtime deps (launcher import + launch --print)

Usage: ./scripts/ci/native-launch.sh [-h]

  -h, --help   show this help
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$ROOT"

  command -v pixi >/dev/null 2>&1 || { echo "error: pixi not on PATH" >&2; exit 1; }

  echo "==> launcher module imports (textual, rich, fm-tools in the env)"
  pixi run bash -c 'source install/setup.bash && python -c "import fm_tui.launcher"'
  echo "PASS: fm_tui.launcher imports"

  # The three dispatch targets from fm_tui's registry (src/fm_app/fm_tui/fm_tui/
  # registry.py) — keep this list in sync when the registry gains an action.
  # --print builds the launch description (all package lookups resolve) without
  # starting a node, which is exactly where a missing runtime package surfaces.
  local target
  for target in \
    "fm_description view_robot.launch.py" \
    "fm_bringup sim.launch.py" \
    "fm_bringup teleop.launch.py"; do
    echo "==> ros2 launch --print $target"
    pixi run bash -c "source install/setup.bash && ros2 launch --print $target > /dev/null"
    echo "PASS: $target resolves"
  done

  echo "==> native-launch: all runtime deps resolve"
}

main "$@"
