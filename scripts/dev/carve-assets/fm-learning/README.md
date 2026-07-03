# fm-learning

[![License: Proprietary](https://img.shields.io/badge/License-Proprietary-blue.svg)](LICENSE)

Learning layer for First Motive's ROS2 stack. A thin metapackage over two sibling
repos — [`fm-data`](https://github.com/first-motive/fm-data) (record → dataset)
and [`fm-policy`](https://github.com/first-motive/fm-policy) (train → serve) — so
the learning side installs as one unit.

Part of First Motive's ROS2 stack. Builds standalone here; assembled
with the other six package repos by
[`fm-ros2`](https://github.com/first-motive/fm-ros2).

## Packages

| Package | Build | Role |
|---------|-------|------|
| `fm_learning` | ament_cmake | Metapackage exec-depending on `fm_data` and `fm_policy` |

Data flows one way: `record → dataset → train → serve`.

## Standalone Build

The metapackage builds nothing on its own — it pulls the `fm-data` and `fm-policy`
sibling repos via `vcs` and groups them. Clone into a colcon workspace's `src/`:

```bash
mkdir -p ws/src && cd ws/src
git clone https://github.com/first-motive/fm-learning.git
vcs import < fm-learning/fm-learning.repos     # siblings (fm-data, fm-policy) + lerobot
cd .. && colcon build --symlink-install
colcon test && colcon test-result --verbose
```

Sibling repos track `main` — fast inner loop while every repo churns together
early; revisit exact-commit pinning at the first release.

## Governance

Owner-free-on-main — see [CONTRIBUTING.md](CONTRIBUTING.md) and
[`.github/CODEOWNERS`](.github/CODEOWNERS).
