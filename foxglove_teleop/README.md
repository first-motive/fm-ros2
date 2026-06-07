# First Motive Teleop Panel

A Foxglove Studio panel that jogs a registered robot through MoveIt Servo. It is the
primary, fleet-scalable teleop input: a new operator opens a Foxglove URL — no
per-operator hardware to ship.

The joint set, command frame, and whether Cartesian jogging is offered are read from a
per-robot config selected in the panel settings (mirrors `fm_bringup`'s robot
registry). Adding a robot is one entry in the `ROBOTS` map in `src/panel.tsx`.

## What It Publishes

```
geometry_msgs/TwistStamped -> /servo_node/delta_twist_cmds   Cartesian jog (held = sustained)
control_msgs/JointJog      -> /servo_node/delta_joint_cmds   per-joint jog
```

Commands are unitless ([-1, 1]); MoveIt Servo scales them (see
`fm_bringup/config/openarm/servo.yaml`). Buttons re-publish on a 50 ms timer while
held so motion is continuous and stops on release.

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
