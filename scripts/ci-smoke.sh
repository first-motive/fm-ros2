#!/usr/bin/env bash
# Headless smoke asserts for the three-robot teleop stack. Runs inside the built
# container, after `colcon build` — CI calls it, and it runs locally the same way:
#
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm_ros2 ./scripts/ci-smoke.sh
#
# Each check is bounded (timed waits, not fixed sleeps) and prints PASS/FAIL. All
# checks run; the script exits non-zero if any failed. These cover the deterministic,
# no-GPU, no-hardware items of the test plan: mock controller bringup per robot, the
# G1 arm_sdk bridge, and the G1 base AGV command. The mujoco-render, Linux/GPU, and
# real-hardware items stay manual.
set -uo pipefail  # not -e: run every check, aggregate failures at the end

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

set +u
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source install/setup.bash
set -u

READY_TIMEOUT=40    # seconds to wait for a controller to reach "active"
TEARDOWN_TIMEOUT=15 # seconds to wait for a torn-down control node to exit

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# Kill a backgrounded launch and the control/state nodes it spawned, then wait
# (bounded) until the control node has actually exited — a fixed sleep races the next
# robot's controller_manager on a slow CI box, leaving a duplicate /controller_manager.
teardown() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
  pkill -f ros2_control_node 2>/dev/null || true
  pkill -f robot_state_publisher 2>/dev/null || true
  pkill -f spawner 2>/dev/null || true
  for _ in $(seq 1 "$TEARDOWN_TIMEOUT"); do
    pgrep -f ros2_control_node >/dev/null 2>&1 || break
    sleep 1
  done
}

# Launch a robot's mock sim and assert a named controller reaches "active".
assert_mock_controllers() {
  local robot="$1" controller="$2"
  ros2 launch fm_bringup sim.launch.py \
    robot:="$robot" sim_backend:=mock use_foxglove:=false >"/tmp/${robot}_sim.log" 2>&1 &
  local pid=$!
  local ok=false
  for _ in $(seq 1 "$READY_TIMEOUT"); do
    if ros2 control list_controllers 2>/dev/null | grep -E "${controller}.*active" >/dev/null; then
      ok=true
      break
    fi
    sleep 1
  done
  if $ok; then
    pass "${robot} mock: ${controller} active"
  else
    fail "${robot} mock: ${controller} never reached active"
    tail -8 "/tmp/${robot}_sim.log" || true
  fi
  teardown "$pid"
}

# Assert the G1 arm_sdk bridge turns both arms' JointTrajectory streams into one LowCmd:
# each commanded joint lands on its motor index (right 22..28, left 15..21) and the
# engagement weight rides motor 29.
assert_g1_arm_bridge() {
  ros2 run fm_control g1_arm_sdk_bridge \
    --ros-args -p output_topic:=/ci_arm_sdk -p weight_ramp_seconds:=0.0 >/tmp/bridge.log 2>&1 &
  local bpid=$!
  sleep 3
  ros2 topic pub --rate 10 /g1_right_arm_controller/joint_trajectory \
    trajectory_msgs/msg/JointTrajectory \
    "{joint_names: [right_elbow_joint], points: [{positions: [0.5]}]}" >/dev/null 2>&1 &
  local rpid=$!
  ros2 topic pub --rate 10 /g1_left_arm_controller/joint_trajectory \
    trajectory_msgs/msg/JointTrajectory \
    "{joint_names: [left_elbow_joint], points: [{positions: [-0.3]}]}" >/dev/null 2>&1 &
  local lpid=$!
  sleep 2
  ros2 topic echo --once /ci_arm_sdk unitree_hg/msg/LowCmd >/tmp/lowcmd.yaml 2>/dev/null || true
  kill "$bpid" "$rpid" "$lpid" 2>/dev/null || true
  wait "$bpid" "$rpid" "$lpid" 2>/dev/null || true
  if python3 - <<'PY'
import sys, yaml
try:
    d = list(yaml.safe_load_all(open("/tmp/lowcmd.yaml")))[0]
    mc = d["motor_cmd"]
    # right_elbow_joint -> motor 25; left_elbow_joint -> motor 18; weight -> motor 29.
    ok = (abs(mc[25]["q"] - 0.5) < 1e-3 and abs(mc[18]["q"] + 0.3) < 1e-3 and
          mc[29]["q"] > 0.0 and len(mc) == 35)
    sys.exit(0 if ok else 1)
except Exception as exc:
    print(exc)
    sys.exit(1)
PY
  then
    pass "g1 arm_sdk bridge: R elbow->motor[25]=0.5, L elbow->motor[18]=-0.3, weight->motor[29]>0"
  else
    fail "g1 arm_sdk bridge: LowCmd mapping wrong or absent"
    tail -5 /tmp/bridge.log || true
  fi
  sleep 2
}

# Assert the G1 base teleop turns a Twist into the AGV Move request (api_id 1001).
assert_g1_base_teleop() {
  ros2 run fm_control g1_base_teleop \
    --ros-args -p output_topic:=/ci_agv >/tmp/base.log 2>&1 &
  local bpid=$!
  sleep 3
  ros2 topic pub --rate 10 /cmd_vel geometry_msgs/msg/Twist \
    "{linear: {x: 0.3}, angular: {z: 0.2}}" >/dev/null 2>&1 &
  local ppid=$!
  sleep 2
  ros2 topic echo --once /ci_agv unitree_api/msg/Request >/tmp/agv.yaml 2>/dev/null || true
  kill "$bpid" "$ppid" 2>/dev/null || true
  wait "$bpid" "$ppid" 2>/dev/null || true
  if python3 - <<'PY'
import sys, yaml
try:
    d = list(yaml.safe_load_all(open("/tmp/agv.yaml")))[0]
    ok = d["header"]["identity"]["api_id"] == 1001 and "vx" in d["parameter"]
    sys.exit(0 if ok else 1)
except Exception as exc:
    print(exc)
    sys.exit(1)
PY
  then
    pass "g1 base teleop: Twist->AGV Move request (api_id 1001)"
  else
    fail "g1 base teleop: AGV request wrong or absent"
    tail -5 /tmp/base.log || true
  fi
  sleep 2
}

echo "==> ci-smoke: three-robot headless asserts"
assert_mock_controllers so101 so101_arm_controller
assert_mock_controllers g1_d g1_right_arm_controller
assert_g1_arm_bridge
assert_g1_base_teleop

echo "==> ci-smoke: ${fails} failure(s)"
[ "$fails" -eq 0 ]
