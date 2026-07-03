# fm-data

[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-blue.svg)](LICENSE)

Data layer for First Motive's ROS2 stack. Records robot episodes and packages
them into datasets — the capture half of the learning loop.

Part of First Motive's ROS2 stack. Builds standalone here; assembled
with the other six package repos by
[`fm-ros2`](https://github.com/first-motive/fm-ros2).

## Packages

| Package | Build | Role |
|---------|-------|------|
| `fm_data_record` | ament_python | Episode recording from the running stack |
| `fm_data_dataset` | ament_python | Dataset tooling over recorded episodes |
| `fm_data` | ament_cmake | Metapackage tying the two together for a single install |

## Standalone Build

Clone into a colcon workspace's `src/`, pull dependencies, then build:

```bash
mkdir -p ws/src && cd ws/src
git clone https://github.com/first-motive/fm-data.git
vcs import < fm-data/fm-data.repos     # externals (lerobot)
cd .. && colcon build --symlink-install
colcon test && colcon test-result --verbose
```

## Governance

Owner-free-on-main — see [CONTRIBUTING.md](CONTRIBUTING.md) and
[`.github/CODEOWNERS`](.github/CODEOWNERS).
