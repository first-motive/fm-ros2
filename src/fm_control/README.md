# fm_control

The backend-selectable `ros2_control` description for the OpenArm, plus a control
node stub. C++ (`ament_cmake`, C++17).

## Role

One control stack drives the OpenArm across every simulator and the real arm. This
package wraps `openarm_description`'s geometry and injects First Motive's own
`<ros2_control>` system, so the controllers and interfaces never change — only the
`<hardware>` System plugin swaps, chosen by the `sim_backend` arg.

```
fm_orchestration -> controllers -> ros2_control system (plugin per backend) -> sim or hardware
```

## Layout

```
urdf/
  openarm.sim.urdf.xacro        top-level: geometry + preset parse + emit systems
  openarm.ros2_control.xacro    backend→plugin macro + per-arm system macro
src/control_node.cpp            placeholder node (real hardware interface later)
include/                        reserved for headers
```

## Backend → System Plugin

```
sim_backend   plugin
  mock          mock_components/GenericSystem
  mujoco        mujoco_ros2_control/MujocoSystemInterface
  gazebo        gz_ros2_control/GazeboSimSystem
  isaac         topic_based_ros2_control/TopicBasedSystem
  real          openarm_hardware/OpenArmHW
```

## How It Is Built

The launches process the xacro per preset and backend:

```bash
xacro $(ros2 pkg prefix fm_control)/share/fm_control/urdf/openarm.sim.urdf.xacro \
  robot_preset:=right_arm sim_backend:=mujoco
```

It emits one `<ros2_control>` system per enabled arm, with joint names matching the
geometry exactly (`<prefix>joint1..7`, plus `<prefix>finger_joint1` when the arm
carries a gripper). `right_arm` yields one system; `default_bimanual` yields two.
For the gazebo backend it also emits the `<gazebo>` world plugin that hosts the
controller_manager inside the sim. The robot name is `openarm_v20`, matching the
MoveIt SRDF so Servo accepts the pair.

Consumed by `fm_bringup`'s `sim.launch.py`, `servo.launch.py`, and `teleop.launch.py`.

## control_node

```bash
ros2 run fm_control control_node
```

A stub — replace with the real `hardware_interface` plugin if a non-ros2_control path
is ever needed. The sim/real backends above do not use it.
