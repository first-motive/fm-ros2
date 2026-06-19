# fm_control

The backend-selectable `ros2_control` descriptions for the OpenArm, SO101, and G1-D,
plus the G1-D teleop bridge nodes. C++ (`ament_cmake`, C++17).

## Role

One control stack drives each robot across every simulator and the real hardware.
Each robot has a top-level xacro that wraps its geometry and injects First Motive's
own `<ros2_control>` system, so the controllers and interfaces never change — only the
`<hardware>` System plugin swaps, chosen by the `sim_backend` arg.

```
fm_bringup launches -> controllers -> ros2_control system (plugin per backend) -> sim or hardware
```

## Layout

```
urdf/
  openarm.sim.urdf.xacro / openarm.ros2_control.xacro   OpenArm (7-DOF, preset-driven)
  so101.sim.urdf.xacro   / so101.ros2_control.xacro     SO101 (5-DOF arm + gripper)
  g1.sim.urdf.xacro      / g1.ros2_control.xacro        G1-D right arm (7-DOF)
src/
  control_node.cpp        placeholder node (unused by the backends below)
  g1_arm_sdk_bridge.cpp   G1-D real arm: Servo JointTrajectory -> unitree_hg/LowCmd
  g1_base_teleop.cpp      G1-D base: Twist -> Unitree AGV Move RPC
include/fm_control/       pure command-building logic for the two bridge nodes
test/                     gtest for the bridge logic
```

## Backend → System Plugin

```
sim_backend   openarm                     so101                            g1_d
  mock          mock_components/GenericSystem (all robots)
  mujoco        mujoco_ros2_control/MujocoSystemInterface (all robots)
  gazebo        gz_ros2_control/GazeboSimSystem (all robots)
  isaac         topic_based_ros2_control/TopicBasedSystem (all robots)
  real          openarm_hardware/OpenArmHW   feetech_ros2_driver/FeetechHardwareInterface   (no plugin — bridge)
```

The sim backends are identical across robots: only the geometry + joint set differ.
The `real` backend is where the robots diverge — see the G1-D asymmetry below.

## How It Is Built

The launches process the xacro per robot + backend, e.g.:

```bash
xacro $(ros2 pkg prefix fm_control)/share/fm_control/urdf/so101.sim.urdf.xacro \
  sim_backend:=mujoco
```

Each emits its `<ros2_control>` system with joint names matching the geometry exactly,
and (for gazebo) the `<gazebo>` world plugin that hosts the controller_manager inside
the sim. SO101 and G1-D merge a vendored flat URDF from `fm_description`'s share;
OpenArm parses its preset-driven `openarm_description` xacro. The robot name matches
each MoveIt SRDF so Servo accepts the pair.

Consumed by `fm_bringup`'s `sim.launch.py`, `servo.launch.py`, and `teleop.launch.py`.

## G1-D Real Arm: a Bridge, Not a ros2_control Plugin

No `ros2_control` hardware interface exists for the Unitree G1 upstream, so the G1-D
`real` arm is **not** a System plugin. Instead `g1.ros2_control.xacro` emits no system
for `sim_backend:=real`, and two nodes drive the robot directly:

```
g1_arm_sdk_bridge   /g1_right_arm_controller/joint_trajectory (Servo)
                      -> unitree_hg/LowCmd on rt/arm_sdk, 50 Hz
                      -> right-arm joints on motor_cmd[22..28], engagement weight on [29]

g1_base_teleop      /cmd_vel (Twist) -> unitree_api/Request (AGV Move, api_id 1001)
                      -> rt/api/agv/request
```

Both mirror the `unitree_sdk2` G1 examples. Reaching real hardware needs the Unitree
CycloneDDS RMW (so `rt/...` maps to the robot's DDS topics). They are plumbed,
build-checked, and unit-tested, but **untested on hardware** — none on hand yet.

## control_node

A stub (`ros2 run fm_control control_node`) — the sim/real backends above do not use
it. Keep or replace if a non-ros2_control path is ever needed.
