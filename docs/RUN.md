# run.sh — The Front Door

`./run.sh` is the single entry point for the fm_ros2 stack. It is a thin
dispatcher: it reads the install profile (`.fm_ros2.json`) and routes the launch to
the **native** path (pixi/RoboStack) or the **container** path (Docker + compose).
Either way it builds the workspace and opens the **fm_tui launcher** — an arrow-key
menu that walks action → robot → variant (→ backend for sim/teleop) and dispatches
the launch.

`run.sh` is the terminal front door. **First Motive** — the native macOS app at
[first-motive/fm-desktop](https://github.com/first-motive/fm-desktop) — is the
graphical alternative: it drives this same contract (the registry, the profiles,
the native/container path) without a terminal. Both share the `~/fm_ros2`
workspace, so a launch behaves the same from either. Build and open it from this
workspace with `./run.sh --app` (see [App Front Door](#app-front-door)).

## Native vs Container

| Path | Runs | Build + launch |
|------|------|----------------|
| **native** | ROS2 on the host via pixi | `pixi run build`, then `fm_tui` natively — rviz2 renders natively, no VNC |
| **container** | ROS2 in a Linux arm64 container | compose build + up, launcher inside the container — rviz over VNC on macOS |

The path is set at install time by OS (macOS/Windows → native, Linux → container)
and persisted to `.fm_ros2.json`. `--native` / `--container` override it per run.
See [SETUP.md](SETUP.md) for the two install paths.

## What It Does

![run](diagrams/run.svg)

Source: [`diagrams/run.d2`](diagrams/run.d2).

On the container path, every step routes through the image entrypoint
(`/ros_entrypoint.sh`) so ROS and the workspace overlay are sourced before the
command runs. On the native path, `pixi run` activates ROS and the script sources
the workspace overlay before launching.

## Usage

```bash
./run.sh                # route by profile (or OS default), build, open the launcher
./run.sh --native       # force the native path (pixi/RoboStack)
./run.sh --container    # force the container path (Docker + compose)
./run.sh --app          # build + launch First Motive, the native macOS app
```

| Flag | Path | When |
|------|------|------|
| (none) | profile in `.fm_ros2.json`, else OS default | normal use |
| `--native` | pixi/RoboStack on the host | macOS/Windows dev |
| `--container` | Docker + compose | Linux, CI/parity, Unitree robots |
| `--app` | First Motive macOS app | prefer a GUI over the terminal launcher (macOS) |

The OS default maps `Darwin` / Windows → native and `Linux` → container. Remaining
args forward to the chosen path script (`scripts/run/native.sh` or
`scripts/run/container.sh`) — run either with `-h` for its own flags.

### Path-Specific Flags

```bash
./run.sh --no-foxglove              # (native) skip auto-opening Foxglove Studio
./run.sh --container --linux        # (container) force the Linux overlay (GPU / hardware)
./run.sh --container --macos        # (container) force the macOS overlay (OrbStack, sim only)
```

On the container path, `--linux` selects `docker/compose.linux.yaml` and `--macos`
selects `docker/compose.macos.yaml`; unflagged, it auto-detects from `uname -s`.

**Windows has no container path** — OrbStack is macOS-only. `run.sh` refuses
`--container` on Windows and points WSL2 users at the Linux container path from a
WSL2 shell.

## App Front Door

`./run.sh --app` builds and launches **First Motive**, the native macOS app, as a
graphical alternative to the `fm_tui` launcher. It dispatches to
`scripts/run/app.sh`, which:

1. **Finds the app checkout** — `$FM_DESKTOP_DIR`, else a sibling `../fm-desktop`,
   else `~/fm-desktop`. If none exists, it clones `first-motive/fm-desktop` into
   `~/fm-desktop`.
2. **Builds the bundle** from source via the app's `scripts/package-app.sh`.
3. **Opens** `First Motive.app`, which adopts this workspace at `~/fm_ros2`.

The app lives in its own repo — deliberately outside this workspace's `.repos`
manifests — so `install.sh` never touches it. A locally built app carries no
Gatekeeper quarantine, so it runs unsigned: no Apple Developer ID needed for a team
that already clones this repo. macOS only; needs the Xcode Command Line Tools
(`xcode-select --install`).

Setup from scratch, workspace-first:

```bash
git clone https://github.com/first-motive/fm-ros2.git fm_ros2
cd fm_ros2
./install.sh            # assemble the workspace (native/container by OS)
./run.sh --app          # clone + build fm-desktop, launch it, adopt this workspace
```

The reverse direction also works: starting from the app (its dmg or checkout),
First Motive's onboarding runs this repo's `install.sh` to create the workspace. Each
front door can bootstrap the other. Signed, downloadable builds for teammates who do
not clone this repo are tracked in fm-desktop's issues.

## macOS: OrbStack Bootstrap

On the macOS path, `run.sh` ensures the Docker provider is ready before bringing
the stack up. It delegates this to fm-docker — the single owner of the container
bring-up — running the imported `docker/install.sh --no-pull` when present, else
fetching the pinned `fm-docker` tag over `curl`. That installer installs OrbStack
(via Homebrew, pointing at [brew.sh](https://brew.sh) and
[orbstack.dev](https://orbstack.dev) when Homebrew is absent) and starts the
daemon — both idempotent. The Linux path skips this block — Docker runs natively.

## Prerequisite: Vendor Robot Sources

Robot descriptions live outside the repo. Vendor them once before the first run:

```bash
./scripts/install/import-externals.sh    # vendor robot sources into external/
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

## Viewer Default — `V` Toggle

The launcher carries a standing viewer default, shown on a status line above the
footer and flipped live with the `V` hotkey:

```
┏ MENU ─────────────────────────┓
┃ ▸ Robot Description            ┃
┃   Teleop                       ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
[V] VIEWER: foxglove
[Q] QUIT   [ESC] BACK
```

Pressing `V` flips `foxglove ⇄ rviz`, updates the line, and writes the choice to
`.fm_tui.json` immediately — no per-launch selection, and the default survives a
quit and re-run. The viewer applies to **Robot Description** only; `sim` and
`teleop` carry no rviz node, so the toggle is a no-op there (Foxglove always).

rviz has no native macOS build. On a Mac it renders inside the container against
a virtual X server with software GL (OrbStack exposes no GPU) and streams to the
browser over VNC, so `run.sh` starts the display + noVNC bridge, opens the
browser, and skips the Foxglove auto-open when rviz is the default — the toggle
warns that Foxglove is the faster path. See [FOXGLOVE.md](FOXGLOVE.md) for the
config file and the VNC flow.

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
across backends — only the `<hardware>` System plugin changes. Four robots are wired
through one registry (`fm_bringup.registry`); adding a fifth is one entry there.

```
robot    arm DOF   Servo Cartesian              real backend
  openarm  7        full 6-DOF                   openarm_hardware (SocketCAN)
  g1_d     7        full 6-DOF (right arm)       arm_sdk bridge — NOT ros2_control
  so101    5        translation-only (orient. drifts)   feetech serial plugin
  axol     7 + 7    full 6-DOF (both arms)       deferred — CAN over USB-C, not yet plumbed
```

Two deliberate asymmetries:

- **SO101 is 5-DOF.** It cannot span SE(3), so per-joint jogging is the primary
  surface; Cartesian runs through Servo's inverse Jacobian, which least-squares the
  under-actuated twist — translation tracks, orientation drifts on the unreachable
  axis.
- **The Unitree `real` arm is a bridge, not a ros2_control plugin.** No hardware
  interface exists for the Unitree upstream, so the real arm is driven by a Servo →
  `unitree_hg/LowCmd` bridge on `rt/arm_sdk` (50 Hz, engagement weight on motor 29).
  The sim backends still use standard ros2_control plugins. The wheeled base is driven
  separately by a Twist → AGV node, not by Servo.

The openarm, g1_d, and so101 real backends are plumbed but **untested** — no physical
hardware yet; Axol's real backend is **deferred** (its CAN driver has no ros2_control
plugin yet, so only the sim backends are wired). On the Mac, `mock` + `mujoco`
validate; `gazebo`/`isaac` are wired-not-validated (Linux/GPU-gated). The Unitree's mujoco
model is the bipedal `g1_29dof` (its arm joint names match; legs differ from the
wheeled body), so Unitree mujoco is wired-not-validated pending a wheeled Unitree MJCF — `mock`
is its validated path. Axol's mujoco model is authored in-repo (Almond Bot ships no
MJCF) and drives both arms.

```bash
./scripts/run/sim.sh                              # openarm right_arm in MuJoCo (default)
./scripts/run/sim.sh --robot so101 --backend mock # SO101, no sim
./scripts/run/sim.sh --robot g1_d --backend mock  # Unitree right arm (body holds)
./scripts/run/sim.sh --variant default_bimanual   # both OpenArm arms
./scripts/run/sim.sh --robot axol --backend mujoco # Axol, both arms in MuJoCo
```

Teleop adds MoveIt Servo plus an input source. Run `sim.sh` in one terminal, then
`teleop.sh` in another:

```bash
./scripts/run/teleop.sh                            # openarm, Foxglove panel -> Servo
./scripts/run/teleop.sh --robot so101 --backend mock
./scripts/run/teleop.sh --robot g1_d               # Unitree right arm
./scripts/run/teleop.sh --robot axol               # Axol, one servo_node per arm
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

The Foxglove panel (`fm_teleop/fm_teleop_panel/`) is the scalable spine: a new operator opens a
URL, no hardware shipped. Physical-HID devices stay on Linux hosts, or reach the Mac
container over a host-side network bridge — never through container USB passthrough.

Every input is a source in the `fm_teleop` layer, collapsing to one shared command
contract. See the [fm-teleop repo](https://github.com/first-motive/fm-teleop) for
the convergence model, the source-status table, and the add-a-source guide.

## Direct Scripts

Each capability has a scriptable path that bypasses the menu, all converging on the
same launch files the launcher dispatches:

```
run.sh           → menu → action → robot → variant (→ backend) → launch
view-robot.sh    → one robot description, no menu
sim.sh           → one sim backend, no menu
teleop.sh        → Servo + one input, no menu
```
