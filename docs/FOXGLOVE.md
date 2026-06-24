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
`--robot so101` or `--robot openarm` for the others) — it starts
robot_state_publisher plus the bridge with meshes. See the
[fm-robot repo](https://github.com/first-motive/fm-robot) (`fm_description`) for the
robot table, variants, and caveats.

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
