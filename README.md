# fm-ros2

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

First Motive's ROS2 workspace orchestrator.

The public stack lives in four per-package repos under the `first-motive` org. A
private learning overlay (data engine + policy) plugs in on top for team members
with access. This repo holds no package source — it assembles those repos into
one colcon workspace via `vcs`, and carries the shared tooling (Docker, dev
container, CI, scripts) and the full-system docs.

## Quick Start

Provision, then launch from your terminal. The package repos are
private, so this needs git access to the `first-motive` org — see
[docs/RUN.md](docs/RUN.md) for details.

**Install** (setup only — clone + import + viewer):

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh | bash
```

**Run** (build the workspace + open the launcher):

```bash
cd fm_ros2 && ./run.sh
```

`install.sh` is setup only (clone + import + viewer); `run.sh` builds the
workspace and opens the launcher. They are split because `run.sh` drives an
interactive menu that a curl pipe cannot supply a terminal for, while `install.sh`
is non-interactive and safe to pipe. Pick the overlay on `run.sh` with `--macos`
or `--linux` (default: auto-detect).

Pass `--learning` through the install pipe to also import the private learning
overlay:

```bash
curl ... | bash -s -- --learning
```

<details>
<summary>Manual steps (fallback)</summary>

```bash
git clone https://github.com/first-motive/fm-ros2.git fm_ros2
cd fm_ros2
vcs import < fm-ros2.repos         # pull container infra into docker/ + the package repos into src/
./scripts/import-externals.sh      # vendor externals into external/
./run.sh                           # auto-detect overlay, open the launcher
```

```bash
./run.sh --linux    # Linux overlay (GPU / hardware)
./run.sh --macos    # macOS overlay (OrbStack, sim only)
```

</details>

![launcher menu](docs/diagrams/menu.svg)

Source: [`docs/diagrams/menu.d2`](docs/diagrams/menu.d2).
**First run** (once, or after changing externals):

```bash
# macOS (M5, OrbStack)
./scripts/setup-macos.sh
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm colcon build --symlink-install

# Linux (GPU / hardware) — swap the setup script and overlay
./scripts/setup-linux.sh
docker compose -f docker/compose.yaml -f docker/compose.linux.yaml \
  run --rm fm colcon build --symlink-install
```

Then `./run.sh`, and connect Foxglove Studio to `ws://localhost:8765`.

[Setup](docs/SETUP.md) · [externals](docs/EXTERNALS.md) · [Foxglove](docs/FOXGLOVE.md)
· [all guides](docs/README.md). Per-package detail in each `<package>/README.md`.

## Architecture

`fm_description` feeds `fm_control`; control drives a backend-selectable hardware
interface; `fm_bringup` launches the graph. A private learning overlay (data
engine + policy) plugs in on top. Full diagrams: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

![system](docs/diagrams/system.svg)

Entry points invoke `fm_bringup`, which composes the robot stack. Blocks marked
with a stacked edge (`fm_tui`, `fm_bringup`) expand in
[`fm-app`](https://github.com/first-motive/fm-app)'s diagrams; the robot layer
detail lives in [`fm-robot`](https://github.com/first-motive/fm-robot). The
orchestrator view is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Source:
[`docs/diagrams/system.d2`](docs/diagrams/system.d2).

## Layout

This repo holds no package source — only the workspace metapackage, shared
tooling, and full-system docs. `vcs import < fm-ros2.repos` pulls the shared
container infra into `docker/` and the four public package repos into `src/`.

```
fm_ros2/                     local checkout dir (snake to match the packages; GitHub slug stays fm-ros2)
├── fm_ros2/                 workspace metapackage (depends on the 4 public group metas)
├── fm-ros2.repos            vcs manifest: the 4 public package repos -> src/
├── external.repos           vcs pins for vendored externals -> external/
├── docker/                  base image + compose overlays
├── .devcontainer/           VS Code dev container
├── .github/workflows/       CI: Linux build/test + macOS native smoke
├── scripts/                 setup, import-externals, carve tooling
├── docs/                    full-system docs + diagrams
└── run.sh                   front door: build + open the launcher
```

The four public package repos (each builds standalone, history preserved from the
split — see [docs/CARVE-RECIPE.md](docs/CARVE-RECIPE.md)):

| Repo | Layer | Packages |
|------|-------|----------|
| [fm-robot](https://github.com/first-motive/fm-robot) | robot | `fm_description` · `fm_control` · `fm_sensors` |
| [fm-sim](https://github.com/first-motive/fm-sim) | simulation | `fm_sim_core` · `fm_sim_backends` · `fm_sim_models` |
| [fm-teleop](https://github.com/first-motive/fm-teleop) | teleop | `fm_teleop_core` · `device` · `leader` · `vr` · `vision` · `panel` |
| [fm-app](https://github.com/first-motive/fm-app) | application | `fm_bringup` · `fm_tui` |

A private learning overlay (`fm-data`, `fm-policy`, `fm-learning`) plugs in on top
via `fm-learning.repos` for team members with access — see
[Learning Stack](docs/ARCHITECTURE.md#learning-stack-private-overlay).

## Platforms

| Platform | Role |
|----------|------|
| Linux (GPU) | dev · build · sim · hardware |
| macOS M5 (OrbStack) | dev · build · sim · dataset |

macOS runs Humble in a Linux arm64 container — no GPU, no hardware; MuJoCo runs native.

## CI

[![CI](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml/badge.svg)](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml)

Four jobs per push and PR; each reproduces locally with the exact CI command
([docs/CI.md](docs/CI.md)).

| Job | Runner | Proves |
|-----|--------|--------|
| `workspace` | `ubuntu-latest` | colcon build + test (`fm_*`) → four-robot headless smoke |
| `installer` | `ubuntu-latest` | `install.sh` clone + import path populates `src/` |
| `macos` | `macos-latest` (arm64) | host-native MuJoCo core — no Docker, no ROS2 |
| `panel` | `ubuntu-latest` | Foxglove teleop panel type-checks and bundles |

## License & Ownership

Maintained by First Motive, a Ubundi subsidiary, under the `first-motive` org.
Licensed under Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
