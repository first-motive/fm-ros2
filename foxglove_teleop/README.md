# First Motive OpenArm Teleop Panel

A Foxglove Studio panel that jogs the OpenArm through MoveIt Servo. It is the primary,
fleet-scalable teleop input: a new operator opens a Foxglove URL — no per-operator
hardware to ship.

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
2. In Foxglove Studio (connected to `ws://localhost:8765`), add the **OpenArm Teleop**
   panel and confirm it can publish (the connection must allow advertising).
3. Hold the Cartesian or per-joint buttons to jog the arm.

The command frame is `openarm_right_base_link`, matching the Servo config.
