# fm-ros2

[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-blue.svg)](LICENSE)

First Motive's ROS2 workspace.

One monorepo for the whole team. The layout mirrors a planned polyrepo split, so
growth is a `git filter-repo`, not a rewrite.

## Quick Start

See [docs/RUN.md](docs/RUN.md) for details.

```bash
./run.sh            # auto-detect overlay, open the launcher
./run.sh --linux    # Linux overlay (GPU / hardware)
./run.sh --macos    # macOS overlay (OrbStack, sim only)
```

```
           +-------------+
           |  ./run.sh   |
           +------+------+ 
                  |      \
      +-----------+--+     +--------------------+
      | Robot Description|  | Autonomous (stub) |
      +-----------+--+     +--------------------+
                  | \
          +-------+-------+
          |   Simulation   |
          +-------+-------+
                   |      \
     +-------------+--+   +--------------+
     |     Gazebo      |   |    MuJoCo    |
     +-------------+--+   +-------+------+
                              \
                           +--------+
                           | Isaac  |
                           |  Sim   |
                           +--------+
           
           +--------+
           | Teleop |
           +---+----+
               |
               v
         +-----------+
         | Simulation|
         +-----------+
```
**First run** (once, or after changing externals):

```bash
# macOS (M5, OrbStack)
./scripts/setup-macos.sh
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm_ros2 colcon build --symlink-install

# Linux (GPU / hardware) — swap the setup script and overlay
./scripts/setup-linux.sh
docker compose -f docker/compose.yaml -f docker/compose.linux.yaml \
  run --rm fm_ros2 colcon build --symlink-install
```

Then `./run.sh`, and connect Foxglove Studio to `ws://localhost:8765`.

[Setup](docs/SETUP.md) · [externals](docs/EXTERNALS.md) · [Foxglove](docs/FOXGLOVE.md)
· [all guides](docs/README.md). Per-package detail in each `<package>/README.md`.

## Architecture

`fm_description` feeds `fm_control`; control drives a backend-selectable hardware
interface; `fm_bringup` launches the graph. Data engine and policy layer plug in on
top. Full diagrams: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

![system](docs/diagrams/system.svg)

Entry points invoke `fm_bringup`, which composes the robot stack. Blocks marked
with a stacked edge expand in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Source:
[`docs/diagrams/system.d2`](docs/diagrams/system.d2).

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
│   ├── fm_teleop_vision     wrist-tracking (working)
│   └── fm_teleop_panel      browser Foxglove panel (npm)
├── fm_sim/                  simulation layer - split-ready group
│   ├── fm_sim_core          headless MuJoCo dev loop (sim_loop)
│   ├── fm_sim_backends      mujoco · gazebo · isaac launch hosts
│   └── fm_sim_models        robot -> MJCF registry
├── fm_data/                 data engine - split-ready group
│   ├── fm_data_record       episodes -> LeRobot
│   └── fm_data_dataset      manage / replay / HF hub
├── fm_policy/               policy layer - split-ready group
│   ├── fm_policy_train       training (may move to cloud)
│   └── fm_policy_serve       inference serving
├── docker/                  base image + compose overlays
├── .devcontainer/           VS Code dev container
├── .github/workflows/       CI: Linux build/test + macOS native smoke
├── scripts/                 setup-macos.sh · setup-linux.sh
└── external.repos           vcs import pins
```

## Platforms

| Platform | Role |
|----------|------|
| Linux (GPU) | dev · build · sim · hardware |
| macOS M5 (OrbStack) | dev · build · sim · dataset |

macOS runs Humble in a Linux arm64 container — no GPU, no hardware; MuJoCo runs native.

## CI

[![CI](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml/badge.svg)](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml)

Three jobs per push and PR; each reproduces locally with the exact CI command
([docs/CI.md](docs/CI.md)).

| Job | Runner | Proves |
|-----|--------|--------|
| `workspace` | `ubuntu-latest` | colcon build + test (`fm_*`) → three-robot headless smoke |
| `macos` | `macos-latest` (arm64) | host-native MuJoCo core — no Docker, no ROS2 |
| `panel` | `ubuntu-latest` | Foxglove teleop panel type-checks and bundles |

## License & Ownership

Maintained by First Motive, a Ubundi subsidiary, under the `first-motive` org.
First Motive proprietary — see [LICENSE](LICENSE).
