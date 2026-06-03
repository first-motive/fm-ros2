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

`launch/view_g1.launch.py` loads a Unitree G1 URDF as `robot_description` and
serves it to Foxglove Studio with meshes. Default is **g1_d** — the wheeled G1-D
(AGV base, two wheels, dual arms). Sources come from the `unitree_ros` repo,
vendored into `src/external/` via vcs, then installed into this package's share at
build (so meshes resolve as `package://`).

```
unitree_ros (vcs, gitignored)
  robots/g1_d_description/g1_d.urdf  +  meshes/*.STL
        │  colcon build → install into share/fm_description/g1_d_description/
        │  launch reads URDF, rewrites meshes/ → package://fm_description/...
        ▼
robot_state_publisher → /robot_description, /tf, /tf_static
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

### Variants

Both the wheeled G1-D and the bipedal body are installed. Switch with launch args:

```bash
./scripts/view-g1.sh                                          # g1_d (wheeled, default)
./scripts/view-g1.sh g1_root:=$(ros2 pkg prefix fm_description)/share/fm_description/g1_description variant:=g1_29dof_rev_1_0
./scripts/view-g1.sh use_rviz:=true                           # RViz (needs an X display)
```

| Arg | Default | Meaning |
|-----|---------|---------|
| `variant` | `g1_d` | URDF basename in `g1_root` |
| `g1_root` | `<share>/fm_description/g1_d_description` | dir holding the URDF + `meshes/` |
| `use_foxglove` | `true` | start foxglove_bridge on `ws://8765` |
| `use_rviz` | `false` | start RViz (needs an X display) |
| `use_jsp` | `true` | start joint_state_publisher so non-fixed joints get TF |

The bipedal `g1_description` ships hand variants too (e.g.
`g1_29dof_rev_1_0_with_inspire_hand_FTP`); the G1-D hand is not yet locked
(Inspire U6 leading).

### Mesh resolution

G1 URDFs reference meshes as relative `meshes/foo.STL`, which RViz and Foxglove
cannot resolve alone. The launch rewrites them to
`package://fm_description/<desc>/meshes/foo.STL` (`<desc>` = the `g1_root` dir
name). Foxglove Studio routes `package://` (and only `package://`) to
foxglove_bridge, which resolves it inside the container and streams the bytes to
Studio. Other schemes (`file://`, `http://`) are fetched host-side by Studio and
cannot see container files, so they fail. CMakeLists installs the descriptions
into the package share to make the `package://` path resolve; the bridge's
default `asset_uri_allowlist` already permits it.

### Foxglove gotcha: meshes tipped 90° about X

If the robot renders with correct link positions but every mesh rotated 90° about
X, set the Foxglove 3D panel's mesh up-axis to match ROS. Foxglove defaults to
Y-up and rotates STL meshes +90° about X; Unitree STLs are Z-up, so they end up
over-rotated. This is a display setting, not a URDF/TF issue (RViz is unaffected):

```
3D panel → settings → Scene → Mesh "up" axis → Z-up   (then Ctrl-R to refresh)
```

To skip this each time, import the ready-made layout `foxglove/g1_view.json`
(Foxglove Studio → Layouts → import from file). It pre-sets the 3D panel:
Z-up meshes, follow `AGV_link`, `/robot_description` visible.

## View the SO101

`launch/view_so101.launch.py` loads the LeRobot **SO101** arm URDF as
`robot_description` and serves it to Foxglove Studio with meshes. The SO101
upstream (`TheRobotStudio/SO-ARM100`) ships as plain files — a flat
`so101_new_calib.urdf` plus `assets/*.stl` — not a ROS package. This is the same
shape as the G1: the files are vendored into this package's share at build, then
the launch rewrites relative mesh paths to `package://` so they resolve.

```
SO-ARM100 (vcs, gitignored)
  Simulation/SO101/so101_new_calib.urdf  +  assets/*.stl
        │  colcon build → install into share/fm_description/so101_description/
        │  launch reads URDF, rewrites assets/ → package://fm_description/...
        ▼
robot_state_publisher → /robot_description, /tf, /tf_static
joint_state_publisher → /joint_states (default pose)
foxglove_bridge       → ws://8765  (Foxglove Studio on the host renders it)
```

Setup, then launch:

```bash
./scripts/import-externals.sh    # clone SO-ARM100 into src/external/ (once)
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm_ros2 colcon build --symlink-install
./scripts/view-so101.sh          # then connect Foxglove Studio to ws://localhost:8765
```

| Arg | Default | Meaning |
|-----|---------|---------|
| `so101_root` | `<share>/fm_description/so101_description` | dir holding `so101_new_calib.urdf` + `assets/` |
| `use_foxglove` | `true` | start foxglove_bridge on `ws://8765` |
| `use_rviz` | `false` | start RViz (needs an X display) |
| `use_jsp` | `true` | start joint_state_publisher so non-fixed joints get TF |

### Mesh resolution

The SO101 URDF references meshes as relative `assets/foo.stl`. The launch rewrites
them to `package://fm_description/so101_description/assets/foo.stl`. CMakeLists
installs the description into the package share so the `package://` path resolves
through foxglove_bridge — identical to the G1 path. The same Z-up mesh gotcha
applies (see above) if meshes render tipped 90° about X.

## View the OpenArm

`launch/view_openarm.launch.py` loads the Enactic **OpenArm** as
`robot_description`. This path differs from the G1 and SO101 on purpose — it
proves the viewing setup adapts to a vendor that ships a real ROS package rather
than flat files.

```
G1 / SO101                          OpenArm
─────────────────────────────────   ─────────────────────────────────────────
flat URDF vendored into             built ament_cmake package
  fm_description share                (openarm_description, NOT vendored)
file copy at build                  colcon build compiles the package; the
                                      build also converts its visual meshes
launch rewrites assets/ → package://  launch rewrites visual .dae refs →
  (path rewrite)                       package://fm_description/openarm_meshes/*.stl
STL meshes, plain paths             DAE meshes under a dotted dir (openarm_v2.0),
                                      mixed up-axes → baked into STL via assimp +
                                      a wider bridge asset allowlist
```

`openarm_description` is the one external left out of `COLCON_IGNORE` (see
`scripts/import-externals.sh`), so `colcon build` compiles it into the workspace.
The launch then processes its xacro at runtime with `xacro.process_file`. The
xacro references meshes as `package://openarm_description/...`. Collision meshes
are already STL and resolve in-container as-is. The visual meshes are COLLADA
(`.dae`) with mixed up-axes that Foxglove cannot read, so the build converts them
to STL (baking each file's up_axis) and the launch rewrites each visual reference
to `package://fm_description/openarm_meshes/...stl` (see [up-axis
baking](#visual-mesh-up-axis-baking) below).

One bridge tweak is required, too (see the [allowlist
note](#foxglove-asset-allowlist-dotted-paths) below): the mesh paths run through a
dotted directory, which the bridge's default asset allowlist rejects.

```
openarm_description (vcs, built — NOT COLCON_IGNORE'd)
  assets/robot/openarm_v2.0/urdf/openarm_v20.urdf.xacro  +  visual *.dae (mixed up-axes)
        │  colcon build → openarm_description on the overlay; fm_description build
        │    converts visual .dae → STL into share/fm_description/openarm_meshes/
        │  launch: xacro.process_file(...) → URDF, then rewrites visual refs
        │    package://openarm_description/*.dae → package://fm_description/openarm_meshes/*.stl
        ▼
robot_state_publisher → /robot_description, /tf, /tf_static
joint_state_publisher → /joint_states (default pose)
foxglove_bridge       → ws://8765  (Foxglove Studio on the host renders it)
```

Setup, then launch:

```bash
./scripts/import-externals.sh    # imports openarm_description WITHOUT COLCON_IGNORE
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm_ros2 colcon build --symlink-install   # must build the package
./scripts/view-openarm.sh        # then connect Foxglove Studio to ws://localhost:8765
```

| Arg | Default | Meaning |
|-----|---------|---------|
| `robot_preset` | `right_arm` | v2.0 preset: `right_arm`, `left_arm`, `default_bimanual`, `right_arm_with_pinch_gripper`, `left_arm_with_pinch_gripper` |
| `use_foxglove` | `true` | start foxglove_bridge on `ws://8765` |
| `use_rviz` | `false` | start RViz (needs an X display) |
| `use_jsp` | `true` | start joint_state_publisher so non-fixed joints get TF |

`robot_preset` is the only model arg the v2.0 xacro takes (mirrors upstream
`display_openarm.launch.py`). The default `right_arm` disables the body and left
arm, leaving a single right arm. The preset's ros2_control include runs with fake
hardware and is harmless for a view, so no disable flag is needed.

### Visual mesh up-axis baking

OpenArm's upstream visual meshes are COLLADA (`.dae`) with **inconsistent declared
up-axes**: the arm and pinch-gripper meshes are `Y_UP`, the body mesh is `Z_UP`.

```
RViz                                Foxglove Studio
honours each file's <up_axis>       ignores per-file <up_axis>,
  → renders upright                   shows raw .dae geometry
                                    → mixed up-axes render mis-rotated,
                                      no single mesh-up toggle fixes them
```

The fix is to bake each file's `up_axis` into the geometry, so the meshes no longer
depend on a reader honouring `<up_axis>`. assimp does this on load: it applies the
declared `up_axis` and exports STL in that resolved frame — the same orientation
RViz presents. So the conversion is a plain DAE → STL export per visual mesh, with
**no extra rotation**:

```
.dae (declared up_axis)  ──assimp export (bakes up_axis)──▶  STL
```

`fm_description`'s build (see `CMakeLists.txt` +
`scripts/convert_openarm_visual_meshes.py`) runs this for every visual mesh and
installs the results into `share/fm_description/openarm_meshes/`, mirroring the
upstream path; the launch rewrites visual references onto them. The URDF's own
`<visual>` origins then orient each mesh exactly as in RViz — adding a rotation
here would double-rotate the meshes and scatter the assembled robot. Collision
meshes are already STL and are not rendered by default, so they are left pointing at
`openarm_description`.

Set the Foxglove 3D panel's mesh up-axis to Z-up (the same setting the G1/SO101
views use) and the robot renders upright for every preset.

### Foxglove asset allowlist: dotted paths

OpenArm's mesh URIs run through a dotted directory, e.g.
`package://openarm_description/assets/robot/openarm_v2.0/meshes/arm/visual/link1.dae`.
foxglove_bridge's default `asset_uri_allowlist` regex permits only `[\w-]` in
path segments, so the dot in `openarm_v2.0` makes it reject every mesh with
`Asset URI not allowed` — the links show load errors and nothing appears. The
launch widens the allowlist to permit dots (`[-\w.]`). The G1/SO101 paths have no
dotted dirs, so they need no override.

### Foxglove send-buffer limit

The launch also raises foxglove_bridge's `send_buffer_limit` from its 10 MB
default to 128 MB. The `default_bimanual` preset includes a ~10.8 MB body mesh
(`body_link0.dae`) that exceeds the default; over the limit the bridge silently
drops that asset and resets the asset channel, so neighbouring meshes fail to
load too. The default `right_arm` preset stays well under 10 MB, but the raised
limit lets every preset render.
