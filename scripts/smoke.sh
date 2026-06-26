#!/usr/bin/env bash
# End-to-end smoke check. Runs headless inside the container:
#   1. build the workspace
#   2. launch the sim loop (MuJoCo) + foxglove bridge
#   3. assert /joint_states publishes and the bridge port is listening
#   4. tear everything down
# Exit 0 = green. Run from the macOS host with:
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm ./scripts/smoke.sh
set -euo pipefail

usage() {
  cat <<'EOF'
smoke.sh — end-to-end smoke check, headless inside the container

Builds the workspace, launches the sim loop + foxglove bridge, asserts
/joint_states publishes and the bridge port listens, then tears down.

Usage: ./scripts/smoke.sh [-h]

  -h, --help   show this help
EOF
}

# Backgrounded PIDs and their teardown stay at top level so the EXIT trap set in
# main() still sees them after main returns.
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$ROOT"

  # ROS setup files reference unbound vars; relax `set -u` only across sourcing.
  set +u
  # shellcheck source=/dev/null
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
  set -u

  echo "==> build"
  colcon build --symlink-install
  set +u
  # shellcheck source=/dev/null
  source install/setup.bash
  set -u

  trap cleanup EXIT

  echo "==> launch sim_loop + foxglove bridge"
  ros2 run fm_sim_core sim_loop &
  PIDS+=($!)
  ros2 run foxglove_bridge foxglove_bridge --ros-args -p port:=8765 -p address:=0.0.0.0 &
  PIDS+=($!)

  echo "==> wait for graph to settle"
  sleep 8

  echo "==> assert /joint_states publishes"
  timeout 15 ros2 topic echo /joint_states sensor_msgs/msg/JointState --once >/dev/null
  echo "    /joint_states OK"

  echo "==> assert foxglove bridge port 8765 listening"
  timeout 10 bash -c 'until (exec 3<>/dev/tcp/127.0.0.1/8765) 2>/dev/null; do sleep 1; done'
  echo "    ws://localhost:8765 OK"

  echo "==> SMOKE GREEN"
}

main "$@"
