# fm_bringup

Launch files and runtime configs. Brings up the First Motive graph.

## Role

```
fm_bringup -> launches: foxglove_bridge + fm_control + fm_orchestration
```

## Run

```bash
ros2 launch fm_bringup bringup.launch.py
```

Starts the foxglove bridge on `ws://0.0.0.0:8765` plus the control and
orchestration node stubs. Launch files live in `launch/`.

## Build type

`ament_python`.
