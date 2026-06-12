#!/usr/bin/env bash
# End-to-end smoke check. Runs headless inside the container:
#   1. build the workspace
#   2. launch the sim loop (MuJoCo) + foxglove bridge
#   3. assert /joint_states publishes and the bridge port is listening
#   4. tear everything down
# Exit 0 = green. Run from the macOS host with:
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm_ros2 ./scripts/smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ROS setup files reference unbound vars; relax `set -u` only across sourcing.
set +u
source "/opt/ros/${ROS_DISTRO}/setup.bash"
set -u

echo "==> build"
colcon build --symlink-install
set +u
source install/setup.bash
set -u

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
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
