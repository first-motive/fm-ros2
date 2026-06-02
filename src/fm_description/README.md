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

## View the Unitree G1

`launch/view_g1.launch.py` loads a Unitree G1 URDF (the G1-D reference) as
`robot_description` and serves it to Foxglove Studio with meshes. The G1 sources
come from the `unitree_ros` repo, vendored into `src/external/` via vcs, then
installed into this package's share at build (so meshes resolve as `package://`).

```
unitree_ros (vcs, gitignored)
  robots/g1_description/<variant>.urdf  +  meshes/*.STL
        │  colcon build → install into share/fm_description/g1_description/
        │  launch reads URDF, rewrites meshes/ → package://fm_description/...
        ▼
robot_state_publisher → /robot_description, /tf
joint_state_publisher → /joint_states (default pose)
foxglove_bridge       → ws://8765  (Foxglove Studio on the host renders it)
```

Setup, then launch:

```bash
./scripts/import-externals.sh    # clone unitree_ros into src/external/ (once)
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm_ros2 colcon build --symlink-install
./scripts/view-g1.sh             # then connect Foxglove Studio to ws://localhost:8765
```

### Variant

`variant` is a launch arg because the G1-D hand is not yet locked (Inspire U6
leading). Default is the clean 29 DOF body; swap with one flag:

```bash
./scripts/view-g1.sh variant:=g1_29dof_rev_1_0_with_inspire_hand_FTP
./scripts/view-g1.sh use_rviz:=true        # RViz instead of / alongside Foxglove (needs X display)
```

| Arg | Default | Meaning |
|-----|---------|---------|
| `variant` | `g1_29dof_rev_1_0` | G1 URDF basename in `g1_root` |
| `g1_root` | `<share>/fm_description/g1_description` | dir holding the URDF + `meshes/` |
| `use_foxglove` | `true` | start foxglove_bridge on `ws://8765` |
| `use_rviz` | `false` | start RViz (needs an X display) |
| `use_jsp` | `true` | start joint_state_publisher so non-fixed joints get TF |

### Mesh resolution

G1 URDFs reference meshes as relative `meshes/foo.STL`, which RViz and Foxglove
cannot resolve alone. The launch rewrites them to
`package://fm_description/g1_description/meshes/foo.STL`. Foxglove Studio routes
`package://` (and only `package://`) to foxglove_bridge, which resolves it inside
the container and streams the bytes to Studio. Other schemes (`file://`, `http://`)
are fetched host-side by Studio and cannot see container files, so they fail.
CMakeLists installs the G1 description into the package share to make the
`package://` path resolve; the bridge's default `asset_uri_allowlist` already
permits it.

### Caveats

- **Hand undecided.** The variant arg defaults to a no-hand body. Lock the hand
  (Inspire / BrainCo) before treating any variant as canonical.
- **Wheeled-base mismatch.** Every upstream G1 URDF is bipedal; no wheeled-base
  G1 description exists. This renders the closest reference body, not the actual
  G1-D wheeled platform.
