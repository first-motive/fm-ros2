# fm-policy

[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-blue.svg)](LICENSE)

Policy layer for First Motive's ROS2 stack. Trains policies on recorded datasets
and serves them back to the running stack — the learning half of the loop.

Part of First Motive's ROS2 stack. Builds standalone here; assembled
with the other six package repos by
[`fm-ros2`](https://github.com/first-motive/fm-ros2).

## Packages

| Package | Build | Role |
|---------|-------|------|
| `fm_policy_train` | ament_python | Training learned policies on datasets |
| `fm_policy_serve` | ament_python | Serving trained policies to the running stack |
| `fm_policy` | ament_cmake | Metapackage tying the two together for a single install |

## Standalone Build

Clone into a colcon workspace's `src/`, pull dependencies, then build:

```bash
mkdir -p ws/src && cd ws/src
git clone https://github.com/first-motive/fm-policy.git
vcs import < fm-policy/fm-policy.repos     # externals (lerobot)
cd .. && colcon build --symlink-install
colcon test && colcon test-result --verbose
```

## Governance

Owner-free-on-main — see [CONTRIBUTING.md](CONTRIBUTING.md) and
[`.github/CODEOWNERS`](.github/CODEOWNERS).
