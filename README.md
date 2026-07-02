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

`install.sh` is setup only (clone + import + env + viewer); `run.sh` builds the
workspace and opens the launcher. They are split because `run.sh` drives an
interactive menu that a curl pipe cannot supply a terminal for, while `install.sh`
is non-interactive and safe to pipe.

`install.sh` picks a run path by OS: macOS and Windows default to **native**
(ROS2 Humble via pixi + RoboStack, no container), Linux defaults to the
**container** (Docker + compose, also the CI/parity path). Override the path and
viewer with flags; the choice is written to `.fm_ros2.json`, and `run.sh` reads it
to dispatch.

```bash
curl ... | bash -s -- --native --viewer foxglove   # pixi/RoboStack, Foxglove
curl ... | bash -s -- --container                  # Docker + compose
```

| Flag | Effect |
|------|--------|
| `--native` | native ROS2 via pixi + RoboStack (default: macOS/Windows) |
| `--container` | Docker + compose (default: Linux; CI/parity elsewhere) |
| `--viewer foxglove\|rviz\|none` | viewer to install (default: foxglove) |

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
./install.sh                       # bootstrap vcs + import repos + externals + viewer
./run.sh                           # auto-detect overlay, open the launcher
```

Clone by hand, then run `install.sh` from the checkout — same setup the curl
pipe runs (vcs bootstrap, package + external import, env + viewer), without
piping to `bash`. Pass `--learning` to add the private overlay, `--native` or
`--container` to override the path.

```bash
./run.sh --native      # force the native path (pixi/RoboStack)
./run.sh --container    # force the container path (Docker + compose)
```

</details>

![launcher menu](docs/diagrams/menu.svg)

Source: [`docs/diagrams/menu.d2`](docs/diagrams/menu.d2).
`run.sh` builds the workspace on every invocation, so the first run needs no
separate build step:

```bash
./run.sh                # native: pixi run colcon build, then the launcher
./run.sh --container    # container: compose build + up, then the launcher
```

The native path builds and launches on the host (rviz2 renders natively; Foxglove
Studio connects to the in-env bridge at `ws://localhost:8765`). The container path
builds inside the dev container — see [SETUP.md](docs/SETUP.md) for its compose
commands.

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
├── pixi.toml / pixi.lock    native ROS2 env: RoboStack channel, 3 platforms
├── docker/                  base image + compose overlays
├── .devcontainer/           VS Code dev container
├── .github/workflows/       CI: Linux build/test + macOS native smoke
├── scripts/                 tooling by role: install/ run/ ci/ dev/
├── docs/                    full-system docs + diagrams
├── install.sh               provisioner: clone + import + env + viewer
└── run.sh                   front door: dispatch native or container
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

macOS runs Humble natively via pixi + RoboStack (the container path stays available
for parity) — no GPU, no hardware; MuJoCo runs native. Unitree-interface robots
(e.g. G1) need the container — see [SETUP.md](docs/SETUP.md).

## CI

[![CI](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml/badge.svg)](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml)

Six jobs per push and PR; each reproduces locally with the exact CI command
([docs/CI.md](docs/CI.md)).

| Job | Runner | Proves |
|-----|--------|--------|
| `selftest` | `ubuntu-latest` | `install.sh` + `run.sh` survive the piped curl path |
| `workspace` | `ubuntu-latest` | colcon build + test (`fm_*`) → four-robot headless smoke |
| `installer` | `ubuntu-latest` | `install.sh` clone + import path populates `src/` |
| `macos` | `macos-latest` (arm64) | host-native MuJoCo core + native install/run dispatch |
| `windows` | `windows-latest` | native dispatch + `.ps1` wrappers delegate through Git Bash |
| `panel` | `ubuntu-latest` | Foxglove teleop panel type-checks and bundles |

## License & Ownership

Maintained by First Motive, a Ubundi subsidiary, under the `first-motive` org.
Licensed under Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
