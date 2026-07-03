# Foxglove

The dev container runs `foxglove_bridge`; Foxglove Studio on the host connects at
`ws://localhost:8765`. Plain `docker compose ... up` opens a shell, not the bridge —
use the helper to serve the port:

```bash
./scripts/run/foxglove.sh           # shared stack (default)
./scripts/run/foxglove.sh -t        # throwaway container, auto-cleans on exit
./scripts/run/foxglove.sh -p 9000   # custom in-container bridge port
```

| Mode | Command | Container | ROS graph |
|------|---------|-----------|-----------|
| shared (default) | `up -d` + `exec` | long-lived | shared with sim / other `exec` sessions |
| throwaway (`-t`) | `run --rm` | fresh, auto-clean | isolated |

Shared keeps one container, so the bridge sees topics from sim and other `exec`
sessions with no extra DDS config. Tear it down with
`docker compose -f docker/compose.yaml -f docker/compose.macos.yaml down`. Throwaway
runs an isolated bridge that cleans up on exit.

To view a robot URDF in Foxglove, run `./scripts/run/view-robot.sh` (default Unitree;
`--robot so101`, `--robot axol`, or `--robot openarm` for the others) — it starts
robot_state_publisher plus the bridge with meshes. See the
[fm-robot repo](https://github.com/first-motive/fm-robot) (`fm_description`) for the
robot table, variants, and caveats.

## Joint Control

Every robot description opens with a joint-control surface seeded at the robot's
home pose, so movable joints move smoothly — no flicker, no bent humanoid.

- **Foxglove**: the imported layout (`fm_description/foxglove/<robot>_view.json`)
  is a 3D panel beside the **First Motive Joint State Publisher** panel. The panel
  reads `/robot_description`, draws one slider per movable joint seeded from the
  live `/joint_states`, and publishes `sensor_msgs/JointState` on `/joint_command`.
  The launch runs `joint_state_publisher` as the sole `/joint_states` publisher,
  subscribed to `/joint_command` via `source_list` — the panel feeds it, never
  races it. Two publishers on `/joint_states` flip the robot between poses; this
  keeps one consistent stream.
- **rviz**: `joint_state_publisher_gui` carries its own slider window (rviz has no
  joint panel of its own). `view_robot.launch.py` picks it automatically on the
  rviz path — `use_jsp_gui` defaults to `auto` and follows the viewer, so **every**
  entryway (TUI, CLI, `run.sh`, FM Desktop) gets rviz joint control from the viewer
  choice alone, no per-frontend flag. The launch keeps exactly one `/joint_states`
  publisher either way. Force it with `use_jsp_gui:=true|false` if needed.

### Installing the Panel

The Joint State Publisher panel ships in the same `fm-teleop` extension as the
teleop panel. Build and install it once:

```bash
cd src/fm_teleop/fm_teleop_panel
npm install
npm run local-install   # builds + installs into the local Foxglove Studio
```

`npm run package` produces a `.foxe` to hand to other operators; drag it onto
Foxglove Studio (Settings → Extensions) to install without the toolchain. Foxglove
loads extensions at startup, so quit fully (Cmd+Q) and reopen to pick up a new or
updated build.

### Re-importing a Layout

The `*_view.json` layouts carry the 3D-plus-joint-panel split, so a fresh import
lands with joint control already in place: Foxglove Studio → Layouts → import
`fm_description/foxglove/<robot>_view.json`. An already-imported copy keeps the
previous layout until you re-import. The layouts reference the panel by its
Foxglove type `firstmotive.fm-teleop.First Motive Joint State Publisher`. That
type is `<publisher>.<name>.<panel name>`, where Foxglove normalizes the
publisher — `toLowerCase()` then strip non-word chars — so `first-motive` in
`package.json` becomes `firstmotive` here (the `-` is dropped). If the panel shows
as unknown after import, confirm the extension is installed and that this type
still matches the installed extension id (its dir under
`~/.foxglove-studio/extensions/`), updating the type in each `*_view.json` if it
differs.

### Never Run a Standalone jsp Against the Sim

The joint-control panel and `use_jsp_gui` are for the description-view path only.
On the sim path (`sim.launch.py`), `joint_state_broadcaster` publishes
`/joint_states` from the controllers. A second publisher — a manual
`joint_state_publisher`, `joint_state_publisher_gui`, or this panel pointed at
`/joint_states` — fights the broadcaster and the robot flips between poses. Drive
sim joints through the controllers (or the teleop panel), never a standalone jsp.

## Viewer Preference — Foxglove vs rviz

The `fm_tui` launcher remembers which viewer to start for **Robot Description**.
The `V` hotkey flips `foxglove ⇄ rviz` and persists the choice to a small JSON
file:

```json
// .fm_tui.json  (repo root, gitignored)
{ "viewer": "foxglove" }
```

`run.sh` sets `FM_TUI_CONFIG=/ws/.fm_tui.json` — the container path for the
mounted repo root — so the file survives a container teardown and reads the same
on the host as `.fm_tui.json` at the repo root. A missing file means the
`foxglove` default.

At dispatch the choice rides into `view_robot.launch.py` as `use_foxglove` /
`use_rviz`, so `rviz` starts RViz instead of the bridge. `sim` and `teleop` carry
no rviz node, so they ignore the preference and always serve Foxglove.

### rviz on macOS — VNC in the Browser

rviz has no native macOS build, and its Ogre GL backend cannot render over
XQuartz's indirect GLX on Apple Silicon (X connects, GL fails). So on a Mac rviz
renders **inside the container** against a virtual X server (Xvfb) with software
GL (llvmpipe), and a VNC bridge streams the framebuffer to the browser:

```
rviz2 → Xvfb :99 (llvmpipe GL) → x11vnc → noVNC :6080 → browser
        all inside the container            OrbStack routes host → container
```

No host viewer install and no XQuartz. When `rviz` is the default on macOS,
`run.sh`:

1. runs [`scripts/run/rviz-vnc.sh`](../scripts/run/rviz-vnc.sh) in the container to start
   Xvfb + x11vnc + noVNC,
2. launches rviz on `DISPLAY=:99` with `LIBGL_ALWAYS_SOFTWARE=1`,
3. opens the browser at `http://<container-ip>:6080/vnc.html`, and
4. skips the Foxglove auto-open.

The browser is blank until you pick a robot description in the launcher — rviz
starts on selection, then appears in the tab.

The VNC deps (`xvfb`, `x11vnc`, `websockify`, `novnc`, mesa) are baked into the
fm-app image. On an image built before they were added, `rviz-vnc.sh` installs
them once at first use.

**Software GL, no GPU.** OrbStack exposes no GPU, so Mesa uses `llvmpipe` (software
rendering). rviz is usable for URDF inspection but slow for point clouds and heavy
scenes. Foxglove renders on the host GPU in the browser, so it stays the faster
macOS path and the default. Reach for `rviz` when you need an rviz-only panel;
otherwise keep `foxglove`.

**Security note.** x11vnc runs with `-nopw` on a container-local display, reachable
only through OrbStack's host↔container routing on your machine — no password, so do
not expose the container's `6080` beyond the host.

## Live SO101 Task Environments

For a live MuJoCo-backed SO101 scene, start the simulator with a task
environment and then connect Foxglove Studio to the shared bridge:

```bash
./scripts/run/sim.sh --robot so101 --backend mujoco --task-env pick_place
./scripts/run/sim.sh --robot so101 --backend mujoco --task-env table_reach
./scripts/run/sim.sh --robot so101 --backend mujoco --task-env bin_sort
```

`sim.sh` prints the selected task environment and ensures Docker is running on
macOS before it launches the graph.

After the scene is up, verify the bridge can see the robot and task props:

```bash
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml exec -T fm_ros2 \
  /ros_entrypoint.sh ros2 topic list | sort
```

Useful topics for the 3D panel:

- `/joint_states`
- `/robot_description`
- `/tf`
- `/tf_static`
- `/task_env_markers`

`/task_env_markers` carries the non-robot scene props such as the table, cube,
goal pad, and bins. In Foxglove's 3D panel, enable `/tf`, `/tf_static`,
`/robot_description`, `/joint_states`, and `/task_env_markers`, then set the
fixed frame to `base_link`.
