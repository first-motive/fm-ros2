# First Motive Teleop Panel

A Foxglove Studio panel that teleoperates a registered robot. It is the primary,
fleet-scalable teleop input: a new operator opens a Foxglove URL — no per-operator
hardware to ship.

Each robot's surface is read from a per-robot config selected in the panel settings
(mirrors `fm_bringup`'s robot registry). Single-arm robots (OpenArm, SO101) expose one
arm. The G1-D exposes its full body: both 7-DOF arms (each on its own `servo_node`), the
wheeled base, and both Dex3 hands. Adding a robot is one entry in the `ROBOTS` map in
`src/panel.tsx`.

## What It Publishes

```
geometry_msgs/TwistStamped -> <servo>/delta_twist_cmds   Cartesian arm jog (held = sustained)
control_msgs/JointJog      -> <servo>/delta_joint_cmds   per-joint arm jog
geometry_msgs/Twist        -> /cmd_vel                   wheeled base (vx + vyaw)
std_msgs/String            -> /g1_hand_teleop/<side>/preset   hand preset (open/close/pinch)
std_msgs/Float64MultiArray -> /g1_hand_teleop/<side>/sliders  hand per-joint targets
```

Arm `<servo>` is `/servo_node` for the right arm and `/servo_node_left` for the G1-D left
arm. Arm + base commands are unitless ([-1, 1]); MoveIt Servo and the diff-drive
controller scale them. Jog buttons re-publish on a 50 ms timer while held so motion is
continuous and stops on release. Hand presets fire once; hand sliders publish the full
7-joint vector on change.

## Build + Install

This is a TypeScript/React Foxglove extension, built outside the ROS workspace with
the Foxglove toolchain (Node 18+ required):

```
cd foxglove_teleop
npm install
npm run local-install   # builds and installs into the local Foxglove Studio
```

`npm run package` produces a `.foxe` for distributing to other operators.

## Use

1. Start the sim and Servo: `./scripts/teleop.sh --robot openarm` (default Foxglove input).
2. In Foxglove Studio (connected to `ws://localhost:8765`), add the **First Motive Teleop**
   panel and confirm it can publish (the connection must allow advertising).
3. In the panel settings, pick the robot you launched so the joint set and command frame
   match its Servo config.
4. Hold the Cartesian or per-joint buttons to jog the arm.

Each robot's command frame must match `robot_link_command_frame` in its Servo config
(e.g. `openarm_right_base_link` for the OpenArm).
