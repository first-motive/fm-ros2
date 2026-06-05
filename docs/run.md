# run.sh — The Front Door

`./run.sh` is the single entry point for the fm_ros2 stack. It brings the dev
container up, builds the workspace, and opens the **fm_tui launcher** — an
arrow-key menu that walks action → robot → variant (→ backend for sim/teleop) and
dispatches the launch.

## What It Does

```
./run.sh
   │
   ├─ 1. detect overlay   host OS → macOS or Linux compose overlay
   ├─ 2. up -d            start the fm_ros2 container (idempotent)
   ├─ 3. colcon build     rebuild the workspace (incremental, --symlink-install)
   └─ 4. ros2 run         open fm_tui launcher → action → robot → variant (→ backend)
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

The launcher dispatches the chosen launch. Robot description, simulation, and
teleop are wired; autonomous is stubbed. Foxglove Studio connects to the running
graph:

```
connect Foxglove Studio to  ws://localhost:8765
```

Tear the stack down when finished:

```bash
docker compose -f docker/compose.yaml -f docker/compose.<overlay>.yaml down
```

## Simulation & Teleop

Beyond viewing a description, the launcher drives the OpenArm through `ros2_control`
in a selectable simulator, and jogs it through MoveIt Servo. One control stack; the
sim backend swaps behind a single arg, and the backend picks the compose overlay.

```
backend → overlay              hosts the controller_manager
  mock          macOS          standalone ros2_control_node (perfect state echo)
  mujoco        macOS          MuJoCo (CPU, Mac daily driver)
  gazebo        Linux/GPU      gz-sim plugin
  isaac         Linux/NVIDIA   Isaac Sim, bridged over ROS topics
```

The controllers, controller_manager, and `<ros2_control>` interfaces stay identical
across backends — only the `<hardware>` System plugin changes. Today OpenArm is the
wired robot (presets `right_arm` and `default_bimanual`); G1 and SO101 stay
description-only.

```bash
./scripts/sim.sh                              # openarm right_arm in MuJoCo (default)
./scripts/sim.sh --backend mock               # no sim; controllers on a state echo
./scripts/sim.sh --variant default_bimanual   # both arms
./scripts/sim.sh --backend gazebo             # Linux/GPU overlay
```

Teleop adds MoveIt Servo plus an input source. Run `sim.sh` in one terminal, then
`teleop.sh` in another:

```bash
./scripts/teleop.sh                # Foxglove panel -> Servo (default)
./scripts/teleop.sh --input joy    # gamepad
```

### Teleop Input — Scalability First

```
PRIMARY    Foxglove panel → TwistStamped/JointJog → Servo   browser, no per-operator HW, remote
SECONDARY  gamepad (joy) → Servo                            Linux /dev/input, or a Mac host-side HID→Joy bridge
TERTIARY   SpaceMouse (spacenav) → Servo                    best 6-DOF ergonomics, USB → Linux only
AVOID      USB-HID directly into a Mac container             no passthrough on OrbStack/Docker Desktop
```

The Foxglove panel (`foxglove_teleop/`) is the scalable spine: a new operator opens a
URL, no hardware shipped. Physical-HID devices stay on Linux hosts, or reach the Mac
container over a host-side network bridge — never through container USB passthrough.

## Direct Scripts

Each capability has a scriptable path that bypasses the menu, all converging on the
same launch files the launcher dispatches:

```
run.sh           → menu → action → robot → variant (→ backend) → launch
view-robot.sh    → one robot description, no menu
sim.sh           → one sim backend, no menu
teleop.sh        → Servo + one input, no menu
```
