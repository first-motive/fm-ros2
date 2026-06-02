#!/usr/bin/env bash
# Launch foxglove_bridge in the macOS dev container so Foxglove Studio on the
# host can connect at ws://localhost:<port>.
#
# Two models:
#   shared (default)  up -d + exec — one long-lived container. The bridge shares
#                     a single ROS graph with sim/other exec sessions, so Foxglove
#                     sees their topics without cross-container DDS config. Free it
#                     later with: docker compose -f ... down
#   throwaway (-t)    run --rm — fresh isolated container that auto-cleans on exit.
#                     The bridge runs alone; it will not see topics from a separate
#                     sim container without extra DDS plumbing.
#
# Note: the macOS overlay publishes the fixed host port 8765. Passing -p changes
# only the in-container bridge port, so non-default ports are reachable from the
# host in throwaway mode (--service-ports remaps) but not in shared mode.
set -euo pipefail

# Run from the repo root so the relative compose paths resolve.
cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker/compose.yaml -f docker/compose.macos.yaml)
SERVICE=fm_ros2
MODE=shared
PORT=8765

usage() {
  cat <<'EOF'
Usage: scripts/foxglove.sh [-t] [-p PORT]
  -t        throwaway container (run --rm); default is the shared stack (up -d + exec)
  -p PORT   in-container bridge port (default 8765)
  -h        show this help
EOF
}

while getopts ":tp:h" opt; do
  case "$opt" in
    t) MODE=throwaway ;;
    p) PORT="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 2 ;;
    :)  echo "Option -$OPTARG needs a value" >&2; usage; exit 2 ;;
  esac
done

BRIDGE=(ros2 launch foxglove_bridge foxglove_bridge_launch.xml "port:=${PORT}")

if [[ "$MODE" == "throwaway" ]]; then
  echo ">> throwaway bridge on port ${PORT} — Ctrl-C to stop and clean up"
  exec "${COMPOSE[@]}" run --rm --service-ports "$SERVICE" "${BRIDGE[@]}"
else
  echo ">> shared stack — bringing container up (idempotent)"
  "${COMPOSE[@]}" up -d
  echo ">> bridge on port ${PORT} — Ctrl-C stops the bridge, stack stays up"
  echo ">> tear down with: ${COMPOSE[*]} down"
  # `exec` skips the image ENTRYPOINT, so route through it to source ROS first.
  exec "${COMPOSE[@]}" exec "$SERVICE" /ros_entrypoint.sh "${BRIDGE[@]}"
fi
