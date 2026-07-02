# CLAUDE.md

Guidance for Claude Code and Codex working in the `fm-robot` repo. See the
[README](README.md) for the package overview.

## Purpose

First Motive robot layer: the URDF description, the controllers, and the sensor drivers for the physical robot stack. Part of First Motive's ROS2 (Humble) stack — one of seven package
repos assembled by [`fm-ros2`](https://github.com/first-motive/fm-ros2).

## Conventions

- Commit and branch rules live in `CONTRIBUTING.md`. Follow them.
- Commits are subject-line-only: `prefix: phrase`. No body.
- Repo is kebab-case; ROS2 packages are snake_case.

## Standalone Build

Clone into a colcon workspace's `src/`, pull dependencies, then build:

```bash
vcs import < fm-robot.repos     # siblings + externals
colcon build --symlink-install
colcon test
colcon test-result --verbose
```
