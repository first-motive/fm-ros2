# fm_description

Robot description: URDF, xacro, and meshes. Feeds robot state / URDF to the graph.

## Role

```
fm_description -> robot_state_publisher -> /tf, /robot_description
```

## Layout

```
urdf/     fm_robot.urdf.xacro   (placeholder — replace with the real robot)
meshes/   visual + collision geometry
launch/   description-only launch helpers
```

## Build type

`ament_cmake`. Installs `urdf/`, `meshes/`, `launch/` to the package share.
