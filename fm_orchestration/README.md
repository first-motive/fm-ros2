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
```

## Nodes

### orchestrator

Task-brain stub — replace with real arbitration logic. No params yet.

## Build type

`ament_python`. The headless MuJoCo sim loop that used to live here now lives in
[`fm_sim_core`](../fm_sim/fm_sim_core).
