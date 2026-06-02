# fm-ros2

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

Connect Foxglove Studio to `ws://localhost:8765`.

### Linux (native GPU / hardware)

```bash
./scripts/setup-linux.sh
docker compose -f docker/compose.yaml -f docker/compose.linux.yaml up
```

## External Dependencies

```bash
vcs import src/external < external.repos
```

Pins are placeholders — see `external.repos`. Vendored sources live under
`src/external/` and are gitignored.
