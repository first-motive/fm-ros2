# fm_ros2

Workspace metapackage. Depends on every public `fm_*` package so the whole First
Motive stack builds and installs as one unit. The four group metapackages
(`fm_robot`, `fm_app`, `fm_sim`, `fm_teleop`) pull their own sub-packages
transitively, so this manifest lists only the top-level packages. The private
overlay (`fm_data`) is imported separately and is not depended on here.

## Build type

`ament_cmake` metapackage.
