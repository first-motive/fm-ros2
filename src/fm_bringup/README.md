# fm_bringup

Launch files and runtime configs for the First Motive graph: the original stub
bringup, plus the OpenArm simulation and teleop stacks. `ament_python`.

## Launches

```
launch/
  bringup.launch.py             foxglove_bridge + control/orchestration stubs
  sim.launch.py                 unified sim: robot + variant + sim_backend
  servo.launch.py               MoveIt Servo for the right_arm group
  teleop.launch.py              Servo + selected input (foxglove | joy | spacenav)
  controllers.launch.py         reusable controller spawners (+ optional standalone CM)
  sim_backends/
    mujoco.launch.py            MuJoCo hosts the controller_manager (Mac daily driver)
    gazebo.launch.py            gz-sim + spawn (Linux/GPU)
    isaac.launch.py             standalone CM + Isaac topic bridge (Linux/NVIDIA)
```

`sim.launch.py` builds the description from `fm_control`'s backend-selectable xacro,
starts `robot_state_publisher` + `foxglove_bridge`, brings up the controller_manager
for the chosen backend, then spawns the controllers. mock/real use a standalone
`ros2_control_node`; mujoco/gazebo host the controller_manager inside the sim; isaac
bridges to an externally-running Isaac Sim over ROS topics.

```bash
ros2 launch fm_bringup sim.launch.py robot:=openarm variant:=right_arm sim_backend:=mujoco
ros2 launch fm_bringup teleop.launch.py input:=foxglove sim_backend:=mujoco
```

Prefer `scripts/sim.sh` and `scripts/teleop.sh` from the host — they pick the compose
overlay from the backend.

## Configs

```
config/openarm/
  right_arm.controllers.yaml         jsb + arm JTC + forward (no gripper joint)
  default_bimanual.controllers.yaml  jsb + 2× arm JTC + 2× gripper JTC
  servo.yaml                         MoveIt Servo params for the right_arm group
```

The controller set is identical across sim backends; only the `<ros2_control>` System
plugin in the description swaps. Joint names match the description geometry.

## Teleop Input Adapters

```
fm_bringup/joy_to_servo.py        gamepad Joy → TwistStamped on Servo's delta topic
fm_bringup/spacenav_to_servo.py   SpaceMouse Twist → TwistStamped on Servo's delta topic
```

The primary input is the browser-side Foxglove panel (`foxglove_teleop/` at the repo
root); the adapters cover physical-HID inputs on Linux hosts.

## Build Type

`ament_python`.
