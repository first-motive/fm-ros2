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

## View Robots

One entry point renders any supported robot. `scripts/view-robot.sh` brings the
container stack up and serves the view to Foxglove Studio on the host;
`launch/view_robot.launch.py` holds an inline `ROBOTS` registry, one entry per
robot. Default robot is **g1_d** (the wheeled G1-D). Adding a robot is one new
registry entry plus one row in the table below — no new launch file or wrapper.

```
scripts/view-robot.sh --robot <key>
        │  docker compose up -d  →  ros2 launch fm_description view_robot.launch.py robot:=<key>
        ▼
ROBOTS[<key>].build_description(share, variant)  →  URDF (mesh refs rewritten to package://)
        ▼
robot_state_publisher → /robot_description, /tf, /tf_static
joint_state_publisher → /joint_states (default pose; source_list ← /joint_command)
foxglove_bridge       → ws://8765  (Foxglove Studio on the host renders it)
```

### Usage

Vendor the sources and build once, then launch any robot:

```bash
./scripts/import-externals.sh    # vendor / import robot sources into external/ (once)
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm_ros2 colcon build --symlink-install
./scripts/view-robot.sh                                  # g1_d wheeled G1-D (default)
./scripts/view-robot.sh --robot g1_d --variant g1_29dof_rev_1_0   # bipedal body
./scripts/view-robot.sh --robot so101
./scripts/view-robot.sh --robot openarm                  # right_arm
./scripts/view-robot.sh --robot openarm --variant default_bimanual
./scripts/view-robot.sh use_rviz:=true                   # RViz (needs an X display)
```

Then connect Foxglove Studio to `ws://localhost:8765`. `--robot` accepts hyphen
or underscore (`g1-d` == `g1_d`); any extra args pass straight through to
`ros2 launch`.

### Robots

| `--robot` | `--variant` (default first) | Source | Mesh rewrite |
|-----------|------------------------------|--------|--------------|
| `g1_d` | `g1_d`, `g1_29dof_rev_1_0` | `unitree_ros` flat URDF, vendored into share | `meshes/` → `package://fm_description/<desc>/meshes/` |
| `so101` | _(none — single description)_ | `SO-ARM100` flat URDF, vendored into share | `assets/` → `package://fm_description/so101_description/assets/` |
| `openarm` | `right_arm`, `left_arm`, `default_bimanual`, `*_with_pinch_gripper` | `openarm_description` built ament_cmake package | visual `.dae` → `package://fm_description/openarm_meshes/*.stl` |

- **g1_d** — both the wheeled G1-D and the bipedal 29 DOF body are installed; pick
  with `--variant`. The bipedal `g1_description` ships hand variants too (e.g.
  `g1_29dof_rev_1_0_with_inspire_hand_FTP`); the G1-D hand is not yet locked
  (Inspire U6 leading).
- **so101** — the upstream (`TheRobotStudio/SO-ARM100`) ships plain files, not a
  ROS package; `--variant` is ignored.
- **openarm** — `--variant` is the xacro `robot_preset` (mirrors upstream
  `display_openarm.launch.py`). The default `right_arm` disables the body and left
  arm. The preset's ros2_control include runs with fake hardware and is harmless
  for a view, so no disable flag is needed.

Common launch args (every robot):

| Arg | Default | Meaning |
|-----|---------|---------|
| `robot` | `g1_d` | registry key: `g1_d`, `so101`, `openarm` |
| `variant` | _(empty → entry default)_ | robot sub-form (see the table above) |
| `use_foxglove` | `true` | start foxglove_bridge on `ws://8765` |
| `use_rviz` | `false` | start RViz (needs an X display) |
| `use_jsp` | `true` | start joint_state_publisher so non-fixed joints get TF |
| `panel_topic` | `/joint_command` | topic jsp subscribes to (point the Foxglove panel here) |

An unknown `--robot` key (shell) or `robot:=` value (launch) fails loud, listing
the valid keys.

### Mesh resolution

Every registry entry rewrites its mesh references to `package://fm_description/...`
before publishing the URDF. Foxglove Studio routes `package://` (and only
`package://`) to foxglove_bridge, which resolves it inside the container and
streams the bytes to Studio. Other schemes (`file://`, `http://`) are fetched
host-side by Studio and cannot see container files, so they fail. CMakeLists
installs every description into the package share to make the `package://` path
resolve; the bridge's default `asset_uri_allowlist` permits the simple paths
(OpenArm widens it — see below).

The g1_d and so101 entries read a flat vendored URDF and do a relative-path
rewrite (`meshes/` or `assets/` → `package://`). OpenArm instead ships as a built
ament_cmake package, so its entry processes the xacro at launch with
`xacro.process_file` and rewrites visual `.dae` references onto a converted STL
set — detailed below.

### Foxglove gotcha: meshes tipped 90° about X

If a robot renders with correct link positions but every mesh rotated 90° about X,
set the Foxglove 3D panel's mesh up-axis to match ROS. Foxglove defaults to Y-up
and rotates meshes +90° about X; the vendored meshes are Z-up, so they end up
over-rotated. This is a display setting, not a URDF/TF issue (RViz is unaffected):

```
3D panel → settings → Scene → Mesh "up" axis → Z-up   (then Ctrl-R to refresh)
```

To skip this each time, import the ready-made layout `foxglove/g1_view.json`
(Foxglove Studio → Layouts → import from file). It pre-sets the 3D panel: Z-up
meshes, follow `AGV_link`, `/robot_description` visible.

### Foxglove gotcha: Joint State Publisher panel flips between poses

If the robot oscillates between two poses when you open Foxglove's **Joint State
Publisher** panel, the panel and the headless `joint_state_publisher` node are both
publishing `/joint_states`, and `robot_state_publisher` interleaves them:

```
joint_state_publisher node ──► /joint_states (default pose, 10 Hz)
                                  ▲
Foxglove panel ───────────────────┘ (slider values)   → two publishers race → flip-flop
```

The launch wires `joint_state_publisher` with `source_list:=[/joint_command]`, so it
is the only `/joint_states` publisher and the panel feeds it instead. Point the panel
at that topic once:

```
Joint State Publisher panel → settings → Publish topic → /joint_command
```

Now the panel publishes `/joint_command`, jsp holds the last value and republishes a
single consistent `/joint_states`, and the flip-flop is gone. Override the topic with
`panel_topic:=<topic>` if you prefer a different name.

### OpenArm: visual mesh up-axis baking

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

### OpenArm: Foxglove asset allowlist and send-buffer limit

OpenArm's mesh URIs run through a dotted directory, e.g.
`package://openarm_description/assets/robot/openarm_v2.0/meshes/arm/visual/link1.dae`.
foxglove_bridge's default `asset_uri_allowlist` regex permits only `[\w-]` in path
segments, so the dot in `openarm_v2.0` makes it reject every mesh with `Asset URI
not allowed` — the links show load errors and nothing appears. The openarm entry's
`bridge_params` widen the allowlist to permit dots (`[-\w.]`). The g1_d/so101 paths
have no dotted dirs, so they keep the default.

The same entry raises `send_buffer_limit` from its 10 MB default to 128 MB. The
`default_bimanual` preset includes a ~10.8 MB body mesh (`body_link0.dae`) that
exceeds the default; over the limit the bridge silently drops that asset and
resets the asset channel, so neighbouring meshes fail to load too. The default
`right_arm` preset stays well under 10 MB, but the raised limit lets every preset
render.

### Adding a robot

Each robot is one entry in the `ROBOTS` dict in `launch/view_robot.launch.py`:

1. Vendor or build the source — flat URDF into the package share (like g1_d /
   so101), or a built ROS package left out of `COLCON_IGNORE` (like openarm) —
   and ensure the meshes install into the package share so `package://` resolves.
2. Add a `build_description(share, variant) -> urdf_xml` callable that reads the
   source and rewrites its mesh references to `package://fm_description/...`.
3. Register an entry: `label`, `default_variant`, `build_description`, and
   `bridge_params` (start from the default `{port, address}`; extend only if the
   vendor needs it, as openarm does for the dotted-path allowlist and send buffer).
4. Add a row to the [Robots](#robots) table here, and update the valid-key list in
   `scripts/view-robot.sh`.
