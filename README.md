# fm-ros2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml/badge.svg)](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml)

First Motive's canonical ROS2 (Humble) workspace. One monorepo the whole team runs
from work laptops: build, Docker, and external vendoring live in one place. The
directory layout mirrors the planned polyrepo split, so growth is a clean
`git filter-repo`, not a rename.

## Platforms

| Platform | Role | GPU / Hardware |
|----------|------|----------------|
| Ubuntu / Linux | main system — dev, build, sim, hardware | yes |
| M5 MacBook Pro (OrbStack) | dev, build, sim, dataset | no |

The macOS path is dev + build + sim + dataset only — no GPU, no hardware.

## CI

Every push and pull request runs three jobs ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)).
The commands below are exactly what CI runs, so any job reproduces locally with
the same line — not a prose claim that it works on each system.

| Job | Runner | Proves |
|-----|--------|--------|
| `workspace` | `ubuntu-latest` | base image → colcon build + test (`fm_*` only) → three-robot headless smoke |
| `macos` | `macos-latest` (arm64) | host-native MuJoCo core runs on the M5 path — no Docker, no ROS2 |
| `panel` | `ubuntu-latest` | Foxglove teleop panel type-checks and bundles |

Reproduce any job locally with the exact CI commands — see [docs/CI.md](docs/CI.md).

## Architecture

Full structural diagrams — system context, component layers, runtime data flow,
the backend-selectable hardware abstraction, deployment, and the data engine —
live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Quick summary:

```
Data flow:  fm_policy_serve -> fm_control (ros2_control) -> hardware   (autonomy arbiter deferred: fm_fsm)
            fm_description -> robot state / URDF
            fm_bringup     -> launches the graph

Viz:        container [foxglove_bridge ws://8765]  -->  macOS Foxglove Studio
Sim:        MuJoCo (native arm64 CPU on M5)  +  rosbag / LeRobot replay
External:   vcs import < external.repos  (LeRobot, OpenArm, Unitree - fork when patching)
```

## Layout

```
fm-ros2/
├── fm_ros2/                 workspace metapackage (depends on all fm_*)
├── fm_bringup/              launch + configs            (Python)
├── fm_description/          URDF / xacro / meshes        (ament_cmake)
├── fm_control/              ros2_control, HW interfaces  (C++)
├── fm_sensors/              multi-sensor capture layer   (placeholder stub)
├── fm_teleop/               teleop source layer - split-ready group
│   ├── fm_teleop_core       TeleopSource base + contract
│   ├── fm_teleop_device     gamepad · SpaceMouse · hand
│   ├── fm_teleop_leader     leader-arm follow (skeleton)
│   ├── fm_teleop_vr         VR controllers (skeleton)
│   ├── fm_teleop_vision     hand-tracking (skeleton)
│   └── fm_teleop_panel      browser Foxglove panel (npm)
├── fm_sim/                  simulation layer - split-ready group
│   ├── fm_sim_core          headless MuJoCo dev loop (sim_loop)
│   ├── fm_sim_backends      mujoco · gazebo · isaac launch hosts
│   └── fm_sim_models        robot -> MJCF registry
├── fm_data/                 data engine - split-ready group
│   ├── fm_data_record       episodes -> LeRobot
│   └── fm_data_dataset      manage / replay / HF hub
├── fm_policy/               policy layer - split-ready group
│   ├── fm_policy_train      training (may move to cloud)
│   └── fm_policy_serve      inference serving
├── docker/                  base image + compose overlays
├── .devcontainer/           VS Code dev container
├── .github/workflows/       CI: Linux build/test + macOS native smoke
├── scripts/                 setup-macos.sh · setup-linux.sh
└── external.repos           vcs import pins
```

## Quick Start

The front door is `./run.sh`. It auto-detects the host OS, brings the dev
container up, and opens the **fm_tui launcher** — an arrow-key menu that walks
action → robot → variant and dispatches the launch:

```bash
./run.sh            # auto-detect overlay, open the launcher
./run.sh --linux    # force the Linux overlay (GPU / hardware)
./run.sh --macos    # force the macOS overlay (OrbStack, sim only)
```

Full front-door reference: [docs/RUN.md](docs/RUN.md).

Robot Description is wired end-to-end (G1-D, SO101, OpenArm); Teleop and
Autonomous show as stubs until their launch graphs land. Connect Foxglove Studio
to `ws://localhost:8765` to view a robot — see [Foxglove](#foxglove).

First time, or after changing externals / sources, run setup and build once:

### macOS (M5, OrbStack)

```bash
./scripts/setup-macos.sh
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm_ros2 colcon build --symlink-install
```

### Linux (native GPU / hardware)

```bash
./scripts/setup-linux.sh
docker compose -f docker/compose.yaml -f docker/compose.linux.yaml \
  run --rm fm_ros2 colcon build --symlink-install
```

Then `./run.sh`. For one robot without the menu, `./scripts/view-robot.sh` is the
direct path to the same launch file (see [Foxglove](#foxglove)).

Full macOS walkthrough: [docs/SETUP.md](docs/SETUP.md). All guides are
indexed in [docs/](docs/README.md). Each package has its own README under
`<package>/`.

## Foxglove

The dev container runs `foxglove_bridge`; Foxglove Studio on the host connects at
`ws://localhost:8765`. Helper modes (`./scripts/foxglove.sh`), robot viewing, and
teardown: [docs/FOXGLOVE.md](docs/FOXGLOVE.md).

## External Dependencies

```bash
./scripts/import-externals.sh        # vendor sources: vcs import external < external.repos
./scripts/setup-lerobot.sh           # then: editable lerobot env from the vendored source
```

Pins in `external.repos` are placeholders (LeRobot, OpenArm, Unitree) — replace
with real tags and fork before patching upstream. Vendored sources live under
`external/` and are gitignored. Vendoring details and the LeRobot env (`--force`,
idempotency): [docs/EXTERNALS.md](docs/EXTERNALS.md).

## License & Ownership

Maintained by First Motive, a Ubundi subsidiary, under the `first-motive` GitHub org.
Released under the MIT License — see [LICENSE](LICENSE).
