# run.sh — The Front Door

`./run.sh` is the single entry point for the fm_ros2 stack. It brings the dev
container up, builds the workspace, and opens the **fm_tui launcher** — an
arrow-key menu that walks action → robot → variant and dispatches the launch.

## What It Does

```
./run.sh
   │
   ├─ 1. detect overlay   host OS → macOS or Linux compose overlay
   ├─ 2. up -d            start the fm_ros2 container (idempotent)
   ├─ 3. colcon build     rebuild the workspace (incremental, --symlink-install)
   └─ 4. ros2 run         open fm_tui launcher → pick action → robot → variant
```

Every step routes through the image entrypoint (`/ros_entrypoint.sh`) so ROS and
the workspace overlay are sourced before the command runs.

## Usage

```bash
./run.sh            # auto-detect overlay, build, open the launcher
./run.sh --linux    # force the Linux overlay (GPU / hardware)
./run.sh --macos    # force the macOS overlay (OrbStack, sim only)
```

| Flag | Overlay | When |
|------|---------|------|
| (none) | auto-detect from `uname -s` | normal use |
| `--linux` | `docker/compose.linux.yaml` | GPU, robot hardware |
| `--macos` | `docker/compose.macos.yaml` | OrbStack, sim only |

Auto-detect maps `Darwin` → macOS overlay and `Linux` → Linux overlay. Any other
host OS exits with an error — pass a flag explicitly.

## Prerequisite: Vendor Robot Sources

Robot descriptions live outside the repo. Vendor them once before the first run:

```bash
./scripts/import-externals.sh    # vendor robot sources into src/external/
```

The launcher's robot list is empty until this runs.

## Every Run Rebuilds

`run.sh` runs `colcon build --symlink-install` on each invocation, so source and
console-script changes are always picked up. The build is incremental — a warm
tree returns fast.

## After the Launcher Opens

The launcher dispatches the chosen launch (robot description today; teleop and
autonomous are stubbed). Foxglove Studio connects to the running graph:

```
connect Foxglove Studio to  ws://localhost:8765
```

Tear the stack down when finished:

```bash
docker compose -f docker/compose.yaml -f docker/compose.<overlay>.yaml down
```

## Relation to view-robot.sh

`scripts/view-robot.sh` is the direct, scriptable path to the same
`view_robot.launch.py`. Use it when you want one robot without the menu;
use `run.sh` for the interactive launcher.

```
run.sh           → menu → action → robot → variant → launch
view-robot.sh    → one robot, no menu (scriptable)
```
