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

Beyond viewing a description, the launcher drives a robot through `ros2_control` in a
selectable simulator, and jogs its arm through MoveIt Servo. One control stack; the
sim backend swaps behind a single arg, and the backend picks the compose overlay.

```
backend → overlay              hosts the controller_manager
  mock          macOS          standalone ros2_control_node (perfect state echo)
  mujoco        macOS          MuJoCo (CPU, Mac daily driver)
  gazebo        Linux/GPU      gz-sim plugin
  isaac         Linux/NVIDIA   Isaac Sim, bridged over ROS topics
```

The controllers, controller_manager, and `<ros2_control>` interfaces stay identical
across backends — only the `<hardware>` System plugin changes. Three robots are wired
through one registry (`fm_bringup.registry`); adding a fourth is one entry there.

```
robot    arm DOF   Servo Cartesian              real backend
  openarm  7        full 6-DOF                   openarm_hardware (SocketCAN)
  g1_d     7        full 6-DOF (right arm)       arm_sdk bridge — NOT ros2_control
  so101    5        translation-only (orient. drifts)   feetech serial plugin
```

Two deliberate asymmetries:

- **SO101 is 5-DOF.** It cannot span SE(3), so per-joint jogging is the primary
  surface; Cartesian runs through Servo's inverse Jacobian, which least-squares the
  under-actuated twist — translation tracks, orientation drifts on the unreachable
  axis.
- **The G1-D `real` arm is a bridge, not a ros2_control plugin.** No hardware
  interface exists for the G1 upstream, so the real arm is driven by a Servo →
  `unitree_hg/LowCmd` bridge on `rt/arm_sdk` (50 Hz, engagement weight on motor 29).
  The sim backends still use standard ros2_control plugins. The wheeled base is driven
  separately by a Twist → AGV node, not by Servo.

Real backends for all three are plumbed but **untested** — no physical hardware yet.
On the Mac, `mock` + `mujoco` validate; `gazebo`/`isaac` are wired-not-validated
(Linux/GPU-gated). The G1-D's mujoco model is the bipedal `g1_29dof` (its arm joint
names match; legs differ from the wheeled body), so G1 mujoco is wired-not-validated
pending a wheeled-G1 MJCF — `mock` is its validated path.

```bash
./scripts/sim.sh                              # openarm right_arm in MuJoCo (default)
./scripts/sim.sh --robot so101 --backend mock # SO101, no sim
./scripts/sim.sh --robot g1_d --backend mock  # G1-D right arm (body holds)
./scripts/sim.sh --variant default_bimanual   # both OpenArm arms
```

Teleop adds MoveIt Servo plus an input source. Run `sim.sh` in one terminal, then
`teleop.sh` in another:

```bash
./scripts/teleop.sh                            # openarm, Foxglove panel -> Servo
./scripts/teleop.sh --robot so101 --backend mock
./scripts/teleop.sh --robot g1_d               # G1-D right arm
```

In the Foxglove panel, pick the robot in the panel settings so the joint set and
command frame match the running target.

### Teleop Input — Scalability First

```
PRIMARY    Foxglove panel → TwistStamped/JointJog → Servo   browser, no per-operator HW, remote
SECONDARY  gamepad (joy) → Servo                            Linux /dev/input, or a Mac host-side HID→Joy bridge
TERTIARY   SpaceMouse (spacenav) → Servo                    best 6-DOF ergonomics, USB → Linux only
AVOID      USB-HID directly into a Mac container             no passthrough on OrbStack/Docker Desktop
```

The Foxglove panel (`src/fm_teleop/fm_teleop_panel/`) is the scalable spine: a new operator opens a
URL, no hardware shipped. Physical-HID devices stay on Linux hosts, or reach the Mac
container over a host-side network bridge — never through container USB passthrough.

Every input is a source in the `fm_teleop` layer, collapsing to one shared command
contract. See [src/fm_teleop/README.md](../src/fm_teleop/README.md) for the convergence
model, the source-status table, and the add-a-source guide.

## Direct Scripts

Each capability has a scriptable path that bypasses the menu, all converging on the
same launch files the launcher dispatches:

```
run.sh           → menu → action → robot → variant (→ backend) → launch
view-robot.sh    → one robot description, no menu
sim.sh           → one sim backend, no menu
teleop.sh        → Servo + one input, no menu
```
