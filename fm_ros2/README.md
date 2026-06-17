# fm_ros2

Workspace metapackage. Depends on every `fm_*` package so the whole First Motive
stack builds and installs as one unit. The four group metapackages (`fm_sim`,
`fm_teleop`, `fm_data`, `fm_policy`) pull their own sub-packages transitively, so
this manifest lists only the top-level packages.

## Build type

`ament_cmake` metapackage.
