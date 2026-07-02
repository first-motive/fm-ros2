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

usage() {
  cat <<'EOF'
Usage: scripts/run/foxglove.sh [-t] [-p PORT]
  -t        throwaway container (run --rm); default is the shared stack (up -d + exec)
  -p PORT   in-container bridge port (default 8765)
  -h        show this help
EOF
}

main() {
  local MODE=shared PORT=8765 SERVICE=fm opt
  local OPTIND=1
  while getopts ":tp:h" opt; do
    case "$opt" in
      t) MODE=throwaway ;;
      p) PORT="$OPTARG" ;;
      h) usage; return 0 ;;
      \?) echo "Unknown option: -$OPTARG" >&2; usage; return 2 ;;
      :)  echo "Option -$OPTARG needs a value" >&2; usage; return 2 ;;
    esac
  done

  # Run from the repo root so the relative compose paths resolve.
  cd "$(dirname "$0")/../.."

  # fm-ros2 consumes the published fm-app full-stack image and sources the compose
  # overlays from fm-docker (imported into docker/ on first run via fm-ros2.repos).
  [[ -d docker ]] || vcs import < fm-ros2.repos
  export FM_IMAGE="${FM_IMAGE:-ghcr.io/first-motive/fm-app:humble}"
  export FM_WS="$PWD"
  local COMPOSE=(docker compose -f docker/compose.yaml -f docker/compose.macos.yaml)

  local BRIDGE=(ros2 launch foxglove_bridge foxglove_bridge_launch.xml "port:=${PORT}")

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
}

main "$@"
