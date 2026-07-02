# Foxglove

The dev container runs `foxglove_bridge`; Foxglove Studio on the host connects at
`ws://localhost:8765`. Plain `docker compose ... up` opens a shell, not the bridge —
use the helper to serve the port:

```bash
./scripts/foxglove.sh           # shared stack (default)
./scripts/foxglove.sh -t        # throwaway container, auto-cleans on exit
./scripts/foxglove.sh -p 9000   # custom in-container bridge port
```

| Mode | Command | Container | ROS graph |
|------|---------|-----------|-----------|
| shared (default) | `up -d` + `exec` | long-lived | shared with sim / other `exec` sessions |
| throwaway (`-t`) | `run --rm` | fresh, auto-clean | isolated |

Shared keeps one container, so the bridge sees topics from sim and other `exec`
sessions with no extra DDS config. Tear it down with
`docker compose -f docker/compose.yaml -f docker/compose.macos.yaml down`. Throwaway
runs an isolated bridge that cleans up on exit.

To view a robot URDF in Foxglove, run `./scripts/view-robot.sh` (default G1-D;
`--robot so101`, `--robot axol`, or `--robot openarm` for the others) — it starts
robot_state_publisher plus the bridge with meshes. See the
[fm-robot repo](https://github.com/first-motive/fm-robot) (`fm_description`) for the
robot table, variants, and caveats.

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

1. runs [`scripts/rviz-vnc.sh`](../scripts/rviz-vnc.sh) in the container to start
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
./scripts/sim.sh --robot so101 --backend mujoco --task-env pick_place
./scripts/sim.sh --robot so101 --backend mujoco --task-env table_reach
./scripts/sim.sh --robot so101 --backend mujoco --task-env bin_sort
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
