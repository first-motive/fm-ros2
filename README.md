# fm-ros2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/Ubundi/fm-ros2/actions/workflows/ci.yml/badge.svg)](https://github.com/Ubundi/fm-ros2/actions/workflows/ci.yml)

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

## Architecture

```
Data flow:  fm_vlta_serve -> fm_orchestration -> fm_control (ros2_control) -> hardware
            fm_description -> robot state / URDF
            fm_bringup     -> launches the graph

Viz:        container [foxglove_bridge ws://8765]  -->  macOS Foxglove Studio
Sim:        MuJoCo (native arm64 CPU on M5)  +  rosbag / LeRobot replay
External:   vcs import < external.repos  (LeRobot, OpenArm, Unitree - fork when patching)
```

## Layout

```
fm-ros2/
├── src/
│   ├── fm_bringup/          launch + configs            (Python)
│   ├── fm_description/      URDF / xacro / meshes        (ament_cmake)
│   ├── fm_control/          ros2_control, HW interfaces  (C++)
│   ├── fm_orchestration/    task brain, action arbiter   (Python)
│   └── fm_vlta/             data engine - split-ready group
│       ├── fm_vlta_record   episodes -> LeRobot
│       ├── fm_vlta_dataset  manage / replay / HF hub
│       ├── fm_vlta_train    training (may move to cloud)
│       └── fm_vlta_serve    inference -> orchestration
├── docker/                  base image + compose overlays
├── .devcontainer/           VS Code dev container
├── .github/workflows/       CI: colcon build + test
├── scripts/                 setup-macos.sh · setup-linux.sh
└── external.repos           vcs import pins
```

## Quick Start

### macOS (M5, OrbStack)

```bash
./scripts/setup-macos.sh
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml up
```

Then start the Foxglove bridge — see [Foxglove](#foxglove).

### Linux (native GPU / hardware)

```bash
./scripts/setup-linux.sh
docker compose -f docker/compose.yaml -f docker/compose.linux.yaml up
```

Full macOS walkthrough: [docs/setup-macos.md](docs/setup-macos.md).
Each package has its own README under `src/<package>/`.

## Foxglove

The dev container runs `foxglove_bridge`; Foxglove Studio on the host connects at
`ws://localhost:8765`. Plain `docker compose ... up` opens a shell, not the bridge —
use the helper to serve the port:

```bash
./scripts/foxglove.sh           # shared stack (default)
./scripts/foxglove.sh -t        # throwaway container, auto-cleans on exit
./scripts/foxglove.sh -p 9000   # custom in-container bridge port
```

| Mode | Command | Container | ROS graph |
|------|---------|-----------|-----------|
| shared (default) | `up -d` + `exec` | long-lived | shared with sim / other `exec` sessions |
| throwaway (`-t`) | `run --rm` | fresh, auto-clean | isolated |

Shared keeps one container, so the bridge sees topics from sim and other `exec`
sessions with no extra DDS config. Tear it down with
`docker compose -f docker/compose.yaml -f docker/compose.macos.yaml down`. Throwaway
runs an isolated bridge that cleans up on exit.

To view a robot URDF in Foxglove, run `./scripts/view-robot.sh` (default G1-D;
`--robot so101` or `--robot openarm` for the others) — it starts
robot_state_publisher plus the bridge with meshes. See
[src/fm_description/README.md](src/fm_description/README.md#view-robots) for the
robot table, variants, and caveats.

## External Dependencies

```bash
./scripts/import-externals.sh        # vendor sources: vcs import src/external < external.repos
./scripts/setup-lerobot.sh           # then: editable lerobot env from the vendored source
```

Pins in `external.repos` are placeholders (LeRobot, OpenArm, Unitree) — replace
with real tags and fork before patching upstream. Vendored sources live under
`src/external/` and are gitignored. The setup scripts call this step; run it
standalone to refresh. If `vcs` is not on the host, run it inside the container.

### LeRobot Env

`setup-lerobot.sh` creates `~/.venvs/lerobot` and installs lerobot editable from
the vendored `src/external/lerobot`, so it runs **after** `import-externals.sh`.
The env is host-native — same story as the MuJoCo env on the M5 (CPU sim and
dataset work, no container). The script is idempotent: it skips when the venv
already exists. Pass `--force` to wipe and reinstall, which also migrates an
older PyPI lerobot venv to this editable source install.

## License & Ownership

Maintained by First Motive, a Ubundi subsidiary, under the `Ubundi` GitHub org.
Released under the MIT License — see [LICENSE](LICENSE).
