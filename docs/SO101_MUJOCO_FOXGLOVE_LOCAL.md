# SO101 MuJoCo + Foxglove Local Runbook

This is the quickest verified path to view a LeRobot SO101 in MuJoCo and
Foxglove on a local Mac.

Verified on macOS + OrbStack on 2026-06-24 from this repo checkout.

## What this gives you

- A live SO101 MuJoCo scene running in the repo's macOS container path
- A Foxglove bridge exposed on `ws://localhost:8765`
- Live robot topics like `/joint_states`, `/tf`, and `/robot_description`
- Live task props on `/task_env_markers` for the SO101 scene

For the validated scene below, the task environment was `pick_place`.

## One-time setup

From the repo root:

```bash
cd /Users/retief/Documents/git-work/fm-polyrepo/fm-ros2
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml build
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml run --rm fm_ros2 ./scripts/import-externals.sh
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml run --rm fm_ros2 colcon build --symlink-install
```

Notes:

- OrbStack must be installed and running.
- The vendored SO101 MuJoCo model comes from `external/so_arm`.
- On this macOS path, Gazebo packages are skipped intentionally; MuJoCo is the
  validated local simulator.

## Start the SO101 scene

Run:

```bash
cd /Users/retief/Documents/git-work/fm-polyrepo/fm-ros2
./scripts/sim.sh --robot so101 --backend mujoco --task-env pick_place
```

What to expect in the terminal:

- `Foxglove Studio: connect to ws://localhost:8765`
- `Loading 'mujoco_model' from: '/ws/external/so_arm/Simulation/SO101/fm_task_env_pick_place.xml'`
- `Publishing live MuJoCo task-env markers for pick_place on /task_env_markers`

You do not need to start `./scripts/foxglove.sh` separately for this workflow.
The current SO101 sim launch already starts `foxglove_bridge`.

## Open Foxglove

1. Open Foxglove Studio on macOS.
2. Create or open a layout with a `3D` panel.
3. Connect to `ws://localhost:8765`.
4. In the 3D panel, add these topics:
   - `/tf`
   - `/tf_static`
   - `/robot_description`
   - `/joint_states`
   - `/task_env_markers`
5. Set the fixed frame to `base_link`.

What you should see:

- The SO101 arm
- The table and pick-place props from `/task_env_markers`
- Live joint-state updates from the running MuJoCo graph

## Quick verification

In another terminal, you can verify the live graph with:

```bash
cd /Users/retief/Documents/git-work/fm-polyrepo/fm-ros2
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml exec -T fm_ros2 /ros_entrypoint.sh ros2 topic list | sort
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml exec -T fm_ros2 /ros_entrypoint.sh ros2 control list_controllers
```

The validated topic list included:

- `/joint_states`
- `/robot_description`
- `/tf`
- `/tf_static`
- `/task_env_markers`

The validated controller state was:

- `joint_state_broadcaster` active
- `so101_arm_controller` active
- `so101_gripper_controller` active

## Other SO101 scenes

Swap `pick_place` for:

```bash
./scripts/sim.sh --robot so101 --backend mujoco --task-env table_reach
./scripts/sim.sh --robot so101 --backend mujoco --task-env bin_sort
```

## Stop everything

Stop the foreground sim with `Ctrl-C`, then tear the shared stack down:

```bash
cd /Users/retief/Documents/git-work/fm-polyrepo/fm-ros2
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml down
```

## Troubleshooting

- If `sim.sh` fails before launch, rebuild with `colcon build --symlink-install`.
- If Foxglove cannot connect, confirm OrbStack is listening on port `8765`.
- If the robot appears but the table/cubes do not, check that `/task_env_markers`
  appears in `ros2 topic list`.
- If you only want a robot model and not the task scene, use
  `./scripts/view-robot.sh --robot so101` instead.
