# fm-ros2

[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-blue.svg)](LICENSE)

First Motive's ROS2 workspace orchestrator.

The stack lives in seven per-package repos under the `first-motive` org. This
repo holds no package source — it assembles those repos into one colcon
workspace via `vcs`, and carries the shared tooling (Docker, dev container, CI,
scripts) and the full-system docs.

## Quick Start

See [docs/RUN.md](docs/RUN.md) for details.

```bash
git clone https://github.com/first-motive/fm-ros2.git
cd fm-ros2
vcs import src < fm-ros2.repos     # pull the seven package repos into src/
./scripts/import-externals.sh      # vendor externals into external/
./run.sh                           # auto-detect overlay, open the launcher
```

```bash
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

This repo holds no package source — only the workspace metapackage, shared
tooling, and full-system docs. `vcs import src < fm-ros2.repos` pulls the seven
package repos into `src/`.

```
fm-ros2/
├── fm_ros2/                 workspace metapackage (depends on the 5 group metas)
├── fm-ros2.repos            vcs manifest: the 7 package repos -> src/
├── external.repos           vcs pins for vendored externals -> external/
├── docker/                  base image + compose overlays
├── .devcontainer/           VS Code dev container
├── .github/workflows/       CI: Linux build/test + macOS native smoke
├── scripts/                 setup, import-externals, carve tooling
├── docs/                    full-system docs + diagrams
└── run.sh                   front door: build + open the launcher
```

The seven package repos (each builds standalone, history preserved from the
split — see [docs/CARVE-RECIPE.md](docs/CARVE-RECIPE.md)):

| Repo | Layer | Packages |
|------|-------|----------|
| [fm-robot](https://github.com/first-motive/fm-robot) | robot | `fm_description` · `fm_control` · `fm_sensors` |
| [fm-sim](https://github.com/first-motive/fm-sim) | simulation | `fm_sim_core` · `fm_sim_backends` · `fm_sim_models` |
| [fm-teleop](https://github.com/first-motive/fm-teleop) | teleop | `fm_teleop_core` · `device` · `leader` · `vr` · `vision` · `panel` |
| [fm-data](https://github.com/first-motive/fm-data) | data | `fm_data_record` · `fm_data_dataset` |
| [fm-policy](https://github.com/first-motive/fm-policy) | policy | `fm_policy_train` · `fm_policy_serve` |
| [fm-learning](https://github.com/first-motive/fm-learning) | learning | thin metapackage over fm-data + fm-policy |
| [fm-app](https://github.com/first-motive/fm-app) | application | `fm_bringup` · `fm_tui` |

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
