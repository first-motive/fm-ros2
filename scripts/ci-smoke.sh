#!/usr/bin/env bash
# Headless smoke asserts for the four-robot teleop stack. Runs inside the built
# container, after `colcon build` — CI calls it, and it runs locally the same way:
#
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm ./scripts/ci-smoke.sh
#
# Each check is bounded (timed waits, not fixed sleeps) and prints PASS/FAIL. All
# checks run; the script exits non-zero if any failed. These cover the deterministic,
# no-GPU, no-hardware items of the test plan: mock controller bringup per robot, the
# G1 arm_sdk bridge, and the G1 base AGV command. The mujoco-render, Linux/GPU, and
# real-hardware items stay manual.
set -uo pipefail  # not -e: run every check, aggregate failures at the end

usage() {
  cat <<'EOF'
ci-smoke.sh — headless smoke asserts for the four-robot teleop stack

Runs inside the built container, after `colcon build`. Every check runs;
the script exits non-zero if any failed.

Usage: ./scripts/ci-smoke.sh [-h]

  -h, --help   show this help
EOF
}

READY_TIMEOUT=40    # seconds to wait for a controller to reach "active"
TEARDOWN_TIMEOUT=15 # seconds to wait for a torn-down control node to exit

# Bounded wait: a plain `wait <pid>` blocks forever when a ros2 launch child
# ignores SIGTERM, which can hang CI for hours. Poll for exit up to TEARDOWN_TIMEOUT,
# then SIGKILL — never block indefinitely.
bwait() {
  local pid
  for pid in "$@"; do
    for _ in $(seq 1 "$TEARDOWN_TIMEOUT"); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  done
}

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# CycloneDDS can interleave notices ("A message was lost!!!", QoS fallback warnings)
# onto stdout, which corrupt a captured YAML document or numeric value. Drop them.
strip_dds_noise() { grep -vE 'message was lost|but not all, publishers'; }

# Kill a backgrounded launch and the control/state nodes it spawned, then wait
# (bounded) until the control node has actually exited — a fixed sleep races the next
# robot's controller_manager on a slow CI box, leaving a duplicate /controller_manager.
teardown() {
  kill "$1" 2>/dev/null || true
  bwait "$1" 2>/dev/null || true
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
  ros2 topic echo --once /ci_arm_sdk unitree_hg/msg/LowCmd 2>/dev/null | strip_dds_noise >/tmp/lowcmd.yaml || true
  kill "$bpid" "$rpid" "$lpid" 2>/dev/null || true
  bwait "$bpid" "$rpid" "$lpid" 2>/dev/null || true
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

# Assert the G1 sim diff-drive base: a /cmd_vel Twist reaches g1_base_controller (via the
# cmd_vel_unstamped -> /cmd_vel remap) and the open-loop odometry tracks vx + vyaw.
assert_g1_base_diff_drive() {
  ros2 launch fm_bringup sim.launch.py \
    robot:=g1_d sim_backend:=mock use_foxglove:=false >/tmp/g1_base.log 2>&1 &
  local pid=$!
  local up=false
  for _ in $(seq 1 "$READY_TIMEOUT"); do
    if ros2 control list_controllers 2>/dev/null | grep -E "g1_base_controller.*active" >/dev/null; then
      up=true
      break
    fi
    sleep 1
  done
  ros2 topic pub --rate 20 /cmd_vel geometry_msgs/msg/Twist \
    "{linear: {x: 0.3}, angular: {z: 0.5}}" >/dev/null 2>&1 &
  local ppid=$!
  sleep 3
  # --field dodges the tab-laden covariance arrays that break a full YAML parse; the
  # numeric grep drops any DDS notice line that lands on stdout before the value.
  local vx vyaw
  vx=$(ros2 topic echo --once --field twist.twist.linear.x \
    /g1_base_controller/odom 2>/dev/null | grep -E '^-?[0-9]' | head -1)
  vyaw=$(ros2 topic echo --once --field twist.twist.angular.z \
    /g1_base_controller/odom 2>/dev/null | grep -E '^-?[0-9]' | head -1)
  kill "$ppid" 2>/dev/null || true
  # open_loop odometry integrates the commanded vx + vyaw.
  if $up && python3 - "$vx" "$vyaw" <<'PY'
import sys
try:
    vx, vyaw = float(sys.argv[1]), float(sys.argv[2])
    ok = abs(vx - 0.3) < 0.05 and abs(vyaw - 0.5) < 0.1
    sys.exit(0 if ok else 1)
except Exception as exc:
    print(exc)
    sys.exit(1)
PY
  then
    pass "g1 base diff-drive: /cmd_vel -> g1_base_controller odom tracks vx=0.3, vyaw=0.5"
  else
    fail "g1 base diff-drive: controller inactive or odom did not track /cmd_vel"
    tail -8 "/tmp/g1_base.log" || true
  fi
  teardown "$pid"
}

# Assert the G1 Dex3 hand bridge turns a hand JointTrajectory into a HandCmd: the
# commanded finger lands on its motor index with the packed enable mode (0x10 | id).
assert_g1_hand_bridge() {
  ros2 run fm_control g1_hand_sdk_bridge \
    --ros-args -p left_output_topic:=/ci_dex3_left >/tmp/hand.log 2>&1 &
  local bpid=$!
  sleep 3
  # Full 7-joint left-hand point (the JTC + bridge use the Dex3 motor order).
  ros2 topic pub --rate 10 /g1_left_hand_controller/joint_trajectory \
    trajectory_msgs/msg/JointTrajectory \
    "{joint_names: [left_hand_thumb_0_joint, left_hand_thumb_1_joint, left_hand_thumb_2_joint, left_hand_middle_0_joint, left_hand_middle_1_joint, left_hand_index_0_joint, left_hand_index_1_joint], points: [{positions: [0.0, 0.0, 0.8, 0.0, 0.0, 0.0, 0.0]}]}" >/dev/null 2>&1 &
  local ppid=$!
  sleep 2
  ros2 topic echo --once /ci_dex3_left unitree_hg/msg/HandCmd 2>/dev/null | strip_dds_noise >/tmp/handcmd.yaml || true
  kill "$bpid" "$ppid" 2>/dev/null || true
  bwait "$bpid" "$ppid" 2>/dev/null || true
  if python3 - <<'PY'
import sys, yaml
try:
    d = list(yaml.safe_load_all(open("/tmp/handcmd.yaml")))[0]
    mc = d["motor_cmd"]
    # thumb_2 -> motor 2 = 0.8; mode packs id 2 + enable (0x10 | 2 = 18); 7 motors.
    ok = len(mc) == 7 and abs(mc[2]["q"] - 0.8) < 1e-3 and mc[2]["mode"] == 18
    sys.exit(0 if ok else 1)
except Exception as exc:
    print(exc)
    sys.exit(1)
PY
  then
    pass "g1 hand bridge: thumb_2->motor[2].q=0.8, mode=0x12, 7 motors"
  else
    fail "g1 hand bridge: HandCmd mapping wrong or absent"
    tail -5 /tmp/hand.log || true
  fi
  sleep 2
}

# Assert the G1 hand teleop turns a named preset into a full 7-joint hand trajectory:
# "close" on the left hand publishes all 7 finger joints with thumb_2 at its flexed limit.
assert_g1_hand_teleop() {
  ros2 run fm_teleop_device g1_hand_teleop >/tmp/hand_teleop.log 2>&1 &
  local npid=$!
  sleep 3
  ros2 topic pub --rate 5 /g1_hand_teleop/left/preset std_msgs/msg/String \
    "{data: close}" >/dev/null 2>&1 &
  local ppid=$!
  sleep 2
  ros2 topic echo --once /g1_left_hand_controller/joint_trajectory \
    trajectory_msgs/msg/JointTrajectory 2>/dev/null | strip_dds_noise >/tmp/hand_traj.yaml || true
  kill "$npid" "$ppid" 2>/dev/null || true
  bwait "$npid" "$ppid" 2>/dev/null || true
  if python3 - <<'PY'
import sys, yaml
try:
    d = list(yaml.safe_load_all(open("/tmp/hand_traj.yaml")))[0]
    names = d["joint_names"]
    pos = d["points"][0]["positions"]
    # All 7 finger joints named; thumb_2 (index 2) flexed to ~1.745 by the close preset.
    ok = len(names) == 7 and len(pos) == 7 and abs(pos[2] - 1.74532925) < 1e-3
    sys.exit(0 if ok else 1)
except Exception as exc:
    print(exc)
    sys.exit(1)
PY
  then
    pass "g1 hand teleop: close preset -> 7-joint trajectory, thumb_2 flexed"
  else
    fail "g1 hand teleop: preset did not map to a full hand trajectory"
    tail -5 /tmp/hand_teleop.log || true
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
  ros2 topic echo --once /ci_agv unitree_api/msg/Request 2>/dev/null | strip_dds_noise >/tmp/agv.yaml || true
  kill "$bpid" "$ppid" 2>/dev/null || true
  bwait "$bpid" "$ppid" 2>/dev/null || true
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

# Bring up the headless rviz VNC path (scripts/rviz-vnc.sh) and assert its two
# halves: the noVNC HTTP port binds, and rviz renders on the virtual display with
# software GL. This covers the container-side of the macOS rviz viewer; the host
# browser-open in run.sh is not exercised here.
assert_rviz_vnc() {
  if ! bash "$ROOT/scripts/rviz-vnc.sh" >/tmp/rviz_vnc.log 2>&1; then
    fail "rviz-vnc: server did not start (see /tmp/rviz_vnc.log)"
    return
  fi
  if ! (exec 3<>/dev/tcp/127.0.0.1/6080) 2>/dev/null; then
    fail "rviz-vnc: noVNC not listening on 6080"
    return
  fi
  exec 3>&- 2>/dev/null || true

  # rviz renders on the Xvfb display; a broken GL/display path prints a known
  # marker, so assert the process is alive and none of those markers appeared.
  DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 timeout 12 ros2 launch fm_description \
    view_robot.launch.py robot:=axol variant:=bimanual use_rviz:=true \
    use_foxglove:=false >/tmp/rviz_render.log 2>&1 &
  local pid=$!
  sleep 6
  if grep -qE "could not connect to display|null not valid|No matching fbConfig" /tmp/rviz_render.log; then
    fail "rviz-vnc: rviz failed to render on the virtual display"
  elif pgrep -f "lib/rviz2/rviz2" >/dev/null 2>&1; then
    pass "rviz-vnc: noVNC bound + rviz rendering on Xvfb"
  else
    fail "rviz-vnc: rviz not running after launch (see /tmp/rviz_render.log)"
  fi
  kill "$pid" 2>/dev/null || true
  pkill -f "lib/rviz2/rviz2" 2>/dev/null || true
  pkill -f "Xvfb :99" 2>/dev/null || true
  pkill x11vnc 2>/dev/null || true
  pkill -f "websockify.*6080" 2>/dev/null || true
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$ROOT" || return 1

  set +u
  # shellcheck source=/dev/null
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
  # shellcheck source=/dev/null
  source install/setup.bash
  set -u

  echo "==> ci-smoke: four-robot headless asserts"
  assert_mock_controllers so101 so101_arm_controller
  assert_mock_controllers g1_d g1_right_arm_controller
  assert_mock_controllers axol axol_right_arm_controller
  assert_g1_base_diff_drive
  assert_g1_arm_bridge
  assert_g1_hand_bridge
  assert_g1_hand_teleop
  assert_g1_base_teleop

  echo "==> ci-smoke: headless rviz VNC viewer"
  assert_rviz_vnc

  echo "==> ci-smoke: ${fails} failure(s)"
  [ "$fails" -eq 0 ]
}

main "$@"
