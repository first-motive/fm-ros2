# fm_orchestration

Task brain and action arbiter. Decides what the robot does next and issues commands
to control.

## Role

```
fm_vlta_serve -> fm_orchestration -> fm_control
```

## Run

```bash
ros2 run fm_orchestration orchestrator        # task brain stub
ros2 launch fm_orchestration sim.launch.py    # headless MuJoCo sim (arm64 CPU)
```

`sim_loop` steps a MuJoCo model and publishes `sensor_msgs/JointState` on
`/joint_states`. The physics lives in `fm_orchestration.sim` (ROS-free); the node
handles comms only.

## Nodes

### sim_loop

Steps a MuJoCo model and publishes joint states at a fixed rate.

- Publishes: `/joint_states` (`sensor_msgs/JointState`)

| param        | type   | default | description                                      |
|--------------|--------|---------|--------------------------------------------------|
| `model_path` | string | `""`    | MJCF path; empty loads the built-in 1-DOF model. |
| `rate_hz`    | double | `100.0` | Step + publish rate.                             |

Defaults live in `config/sim.yaml`. Override the whole file without editing the
packaged default:

```bash
ros2 launch fm_orchestration sim.launch.py params_file:=/path/to/my.yaml
```

### orchestrator

Task-brain stub — replace with real arbitration logic. No params yet.

## Build type

`ament_python`. MuJoCo is a pip dep, installed by the base image.
