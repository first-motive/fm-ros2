# fm_robot

Robot layer for the fm_ros2 workspace. Groups the URDF description, the
`ros2_control` controllers, and the sensor drivers — the packages that model and
drive the physical robot. Split-ready: this whole group extracts cleanly into its
own repo later.

## Sub-Packages

| Package | Build | Role |
|---------|-------|------|
| [`fm_description`](fm_description/README.md) | ament_cmake | URDF/xacro robot model, meshes, and the `view_robot` launch |
| [`fm_control`](fm_control/README.md) | ament_cmake | `ros2_control` controllers and the G1 SDK bridges (arm, hand, base) |
| [`fm_sensors`](fm_sensors/README.md) | ament_python | Sensor driver nodes |

## How the Pieces Connect

`fm_description` owns the robot model: the xacro that other packages include to get
the URDF and the `ros2_control` tags. `fm_control` consumes that description to load
controllers and bridges joint commands to the hardware SDK. `fm_sensors` publishes
the sensor streams the rest of the stack consumes. See
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the full system design.

## Build Type

`ament_cmake` metapackage (exec-depends on the three sub-packages). The package
itself builds nothing; it ties the group together for a single install.
