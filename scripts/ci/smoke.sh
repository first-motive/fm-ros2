#!/usr/bin/env bash
# End-to-end smoke check. Runs headless inside the container:
#   1. build the workspace
#   2. launch the sim loop (MuJoCo) + foxglove bridge
#   3. assert /joint_states publishes and the bridge port is listening
#   4. tear everything down
# Exit 0 = green. Run from the macOS host with:
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm ./scripts/ci/smoke.sh
set -euo pipefail

usage() {
  cat <<'EOF'
smoke.sh — end-to-end smoke check, headless inside the container

Builds the workspace, launches the sim loop + foxglove bridge, asserts
/joint_states publishes and the bridge port listens, then tears down.

Usage: ./scripts/ci/smoke.sh [-h]

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
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$ROOT"
  # Keep the smoke on the same endpoint contract as appliance services. CI has
  # no /etc/fm-bridge.env, so this resolves to the compatibility default 8765.
  # shellcheck disable=SC1091
  source "$ROOT/scripts/env/bridge.sh"

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
  ros2 run foxglove_bridge foxglove_bridge --ros-args \
    -p "port:=$FM_BRIDGE_PORT" -p address:=0.0.0.0 &
  PIDS+=($!)

  echo "==> wait for graph to settle"
  sleep 8

  echo "==> assert /joint_states publishes"
  timeout 15 ros2 topic echo /joint_states sensor_msgs/msg/JointState --once >/dev/null
  echo "    /joint_states OK"

  echo "==> assert foxglove bridge port $FM_BRIDGE_PORT listening"
  timeout 10 bash -c "until (exec 3<>/dev/tcp/127.0.0.1/$FM_BRIDGE_PORT) 2>/dev/null; do sleep 1; done"
  echo "    ws://localhost:$FM_BRIDGE_PORT OK"

  echo "==> SMOKE GREEN"
}

main "$@"
