# CLAUDE.md

Guidance for Claude Code and Codex working in this repo. See [README](README.md)
for the project overview and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the
system design.

## Purpose

`fm-ros2` is First Motive's ROS2 (Humble) robot stack — a colcon workspace of
`fm_*` packages spanning bringup, control, description, sensors, sim, teleop,
data, and policy.

## Conventions

- Commit and branch rules live in `CONTRIBUTING.md`. Follow them.
- Commits are subject-line-only: `prefix: phrase`. No body.
- Repo is kebab-case; ROS2 packages are snake_case (see `CONTRIBUTING.md`).

## Testing

```bash
colcon build --symlink-install
colcon test --packages-select $(colcon list --names-only | grep '^fm_')
colcon test-result --verbose
```

## Layout

The repo root holds only `fm_*` domain-group folders plus the `fm_ros2` workspace
metapackage. Each group (`fm_robot`, `fm_app`, `fm_sim`, `fm_teleop`, `fm_learning`)
is a folder containing its own `ament_cmake` metapackage as a sibling of the leaf
packages it groups — so the system boundaries are visible at the top level. Clone the
repo into a colcon workspace's `src/`, where `colcon build` recurses and finds every
package regardless of nesting depth. The root `fm_ros2` metapackage depends on the
five group metapackages; each pulls its own sub-packages transitively.

## Diagrams

Architecture diagrams are authored in [d2](https://d2lang.com) under
[`docs/diagrams/`](docs/diagrams/) with the First Motive brand (Geist Mono font,
palette in `styles.d2`). Edit the `.d2`, re-render, and commit both the `.d2` and
the generated `.svg`:

```bash
cd docs/diagrams && ./render.sh
```
