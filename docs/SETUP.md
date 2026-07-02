# Setup

How to build and run `fm-ros2`. Two paths share one imported workspace:

| Path | Default on | Runs | Best for |
|------|-----------|------|----------|
| **Native** (pixi + RoboStack) | macOS, Windows | ROS2 Humble on the host, no container | day-to-day dev on a Mac or Windows box |
| **Container** (Docker + compose) | Linux | ROS2 Humble in a Linux arm64 container | CI, parity, Unitree hardware, GPU/Linux work |

`install.sh` picks the path by OS and writes the choice to `.fm_ros2.json`;
`run.sh` reads that file to dispatch. Override with `--native` / `--container`.
Both paths are dev + build + sim + dataset on macOS — no GPU, no hardware. Hardware
and GPU work happen on Linux.

## Native Path (Recommended)

On macOS and Windows, the native path runs ROS2 Humble directly on the host through
[pixi](https://pixi.sh) and [RoboStack](https://robostack.github.io) — no container,
no VNC. RoboStack ships prebuilt Humble binaries on the `robostack-humble` conda
channel; `pixi.lock` pins the exact solve for `osx-arm64`, `win-64`, and `linux-64`
from one `pixi.toml`.

```bash
git clone https://github.com/first-motive/fm-ros2.git fm_ros2
cd fm_ros2
./install.sh --native                 # bootstrap pixi, solve the env, install the viewer
./run.sh                              # pixi run colcon build, then the launcher
```

`install.sh --native` bootstraps pixi (pinned via `PIXI_VERSION`), solves the env
from `pixi.lock`, and installs the viewer (Foxglove via Homebrew cask on macOS /
winget on Windows; rviz and none need nothing — rviz ships inside the pixi env).
`run.sh` then runs `pixi run colcon build --symlink-install` on the host and opens
`fm_tui` natively. rviz2 renders through its native RoboStack build; Foxglove Studio
connects to the in-env bridge at `ws://localhost:8765`.

On macOS (osx-arm64), 13 packages build natively — all of `fm_sim` and `fm_teleop`,
plus `fm_tui`, `fm_sensors`, and `openarm_description`.

### Caveats

| Caveat | What to do |
|--------|-----------|
| `rosdep` is unsupported inside a pixi env | Add ROS deps with `pixi add ros-humble-<pkg>`, not `rosdep`. |
| Unitree interface externals (`unitree_api`, `unitree_go`, `unitree_hg`) do **not** build natively on macOS — `rosidl_generator_py` cannot find the env Python's dev component. Packages that depend on them (`fm_description`, some openarm configs) abort. | Use the container path for Unitree-dependent robots (e.g. G1). Everything else builds natively. |
| `ros-humble-foxglove-bridge` has no `win-64` build on `robostack-humble` | Native Windows has no Foxglove path — Windows installs default to the rviz viewer. |
| Native Linux is deferred | Linux stays on the container (the CI/parity default). |
| Windows PowerShell wrappers (`install.ps1` / `run.ps1`) are not yet present | Windows support is planned; for now the bash path runs under Git for Windows. |

### Why pixi

Native ROS2 on macOS and Windows was historically painful; pixi + RoboStack is now
the mainstream answer:

- **OSRF** made pixi the official ROS2 Windows install (Feb 2025) — conda-forge is
  the exclusive binary source. ([announcement](https://discourse.openrobotics.org/t/upcoming-switch-of-windows-installation-to-pixi-conda/41916))
- **prefix.dev** maintains first-class ROS2 support: a
  [ROS2 tutorial](https://pixi.prefix.dev/latest/tutorials/ros2/), a robotics landing
  page, and a ROS build backend.
- **Peer-reviewed:** "Pixi: Unified Software Development and Distribution for Robotics
  and AI" (arXiv [2511.04827](https://arxiv.org/abs/2511.04827), Nov 2025) — lockfile
  reproducibility across `linux-64` / `osx-arm64` / `win-64`.
- **RoboStack** [recommends pixi](https://robostack.github.io/GettingStarted.html)
  over micromamba for new installs.

## Container Path (Parity / CI)

The container path is the CI/parity path and the default on Linux. ROS2 Humble
targets Ubuntu; on macOS it runs inside a Linux arm64 container via OrbStack. The
workspace is bind-mounted, so host edits rebuild without reimaging.

![macOS setup](diagrams/setup.svg)

Source: [`diagrams/setup.d2`](diagrams/setup.d2).

## Prerequisites

1. Install [OrbStack](https://orbstack.dev) — the Docker provider on M5. With
   [Homebrew](https://brew.sh) present, `./run.sh` installs and starts it for you
   (delegated to fm-docker's `docker/install.sh`); install it by hand only if you
   skip `run.sh`.
2. Install [Foxglove Studio](https://foxglove.dev/download) (native macOS app).

## First run

```bash
git clone https://github.com/first-motive/fm-ros2.git fm_ros2
cd fm_ros2
vcs import < fm-ros2.repos     # pull the four public package repos into src/
./scripts/install/setup-macos.sh
```

`setup-macos.sh` checks OrbStack, imports external deps (placeholder pins), and
builds the base image (arm64). The package source comes from the four public repos
in `fm-ros2.repos` — import them into `src/` first, as shown above.

## Bring the stack up

```bash
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml up
```

Then open Foxglove Studio and connect to `ws://localhost:8765`. Topics appear once
the bringup launch is running.

## Common tasks

Open a shell in the container:

```bash
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml run --rm fm bash
```

Build and test (same commands CI runs):

```bash
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm ./scripts/ci/verify-build.sh
```

Run the end-to-end smoke check:

```bash
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm ./scripts/ci/smoke.sh
```

Launch the graph (foxglove bridge + control):

```bash
# inside the container shell
ros2 launch fm_bringup bringup.launch.py
```

Run the headless MuJoCo sim:

```bash
# inside the container shell
ros2 run fm_sim_core sim_loop
```

## Limits of the macOS path

| Works | Does not work |
|-------|---------------|
| build, colcon test | GPU compute |
| headless MuJoCo (CPU) | robot hardware / `/dev` |
| dataset record / replay | X11 GUI passthrough |
| Foxglove viz over ws | CUDA training |

For GPU, hardware, or GUI tools, use the Linux native path
(`scripts/install/setup-linux.sh` + `compose.linux.yaml`).

## Troubleshooting

- **`docker info` does not mention OrbStack** — another Docker provider is active.
  Switch to OrbStack so builds use the arm64 path.
- **Foxglove will not connect** — confirm the stack is up and port 8765 is mapped
  (it is, in `compose.macos.yaml`). Check the bridge node is running.
- **`vcs import` fails** — pins in `external.repos` are placeholders. Edit them to
  real tags before importing.
