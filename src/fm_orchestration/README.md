# fm_orchestration

Task brain and action arbiter. Decides what the robot does next and issues commands
to control.

## Role

```
fm_vlta_serve -> fm_orchestration -> fm_control
```

## Run

```bash
ros2 run fm_orchestration orchestrator   # task brain stub
ros2 run fm_orchestration sim_loop       # headless MuJoCo sim (arm64 CPU)
```

`sim_loop` steps a MuJoCo model and publishes `sensor_msgs/JointState` on
`/joint_states`. Pass a real model with `-p model_path:=/path/to/model.xml`.

## Build type

`ament_python`. MuJoCo is a pip dep, installed by the base image.
