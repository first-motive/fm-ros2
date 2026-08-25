# 0003 — The Native Path Is pixi + RoboStack

**Status**: Accepted
**Context**: [docs/SETUP.md](../SETUP.md), `pixi.toml`, `pixi.lock`

## Context

Most of this team develops on macOS, and ROS 2 has no macOS binaries. The
historical answer was a Linux container with a VNC desktop for anything that
draws — which works, and costs a rebuild for every change, a virtual display for
every viewer, and a filesystem boundary between the editor and the build.

RoboStack publishes prebuilt Humble binaries on a conda channel for `osx-arm64`,
`win-64`, and `linux-64`, and RoboStack itself recommends pixi as the way to
consume them.

## Decision

The native path is pixi + RoboStack: `pixi.toml` declares the environment,
`pixi.lock` pins one solve per platform, and `pixi run build` / `pixi run test`
are the workspace's own tasks. It is the default on macOS and Windows.

The container remains the CI and parity path, and the only path for driving real
Unitree hardware.

## Consequences

- A Mac builds and tests the whole workspace natively, and rviz2 renders through
  its native build instead of through VNC.
- The environment is locked: `pixi.lock` is the solve every machine gets, so
  "works on my laptop" is a claim CI can check.
- `rosdep` does not work inside a pixi env. ROS dependencies are added with
  `pixi add ros-humble-<pkg>`, which means a package's `package.xml` and the pixi
  environment are two lists that have to agree — the cost of this decision, and
  the source of most native build failures.
- The `build` task carries `-DPython_EXECUTABLE`, without which
  `rosidl_generator_py` finds the wrong interpreter and every interface package
  fails. A bare `pixi run colcon build` is therefore not the same command.
- Two build paths exist, so a change can pass one and fail the other. CI runs
  both.
