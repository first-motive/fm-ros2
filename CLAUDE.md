# CLAUDE.md

Guidance for Claude Code and Codex working in this repo. See [README](README.md)
for the project overview and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the
system design.

## Purpose

`fm-ros2` is the orchestrator for First Motive's ROS2 robot stack. The
public packages live in four per-package repos under the `first-motive` org; a
private learning overlay plugs in on top for team members with access. This repo
assembles them
into one colcon workspace via `vcs` and holds the shared tooling (Docker, dev
container, CI, scripts) and full-system docs. It carries no package source — only
the `fm_ros2` workspace metapackage.

## Conventions

- Commit and branch rules live in `CONTRIBUTING.md`. Follow them.
- Commits are subject-line-only: `prefix: phrase`. No body.
- Repo is kebab-case; ROS2 packages are snake_case (see `CONTRIBUTING.md`).
- Package source changes belong in the package's own repo, not here. This repo
  changes only for tooling, the workspace metapackage, the `.repos` manifests,
  and docs.

## Assembly

```bash
vcs import < fm-ros2.repos     # pull container infra into docker/ + the four package repos into src/
vcs import src < private-overlay.repos # private overlay — team members with access
./scripts/install/import-externals.sh      # vendor externals into external/
```

The learning overlay is provisioned automatically for team members: `install.sh`'s
auth gate (gh auth + org read) routes it through the private team-setup step, which
imports it on top of the public workspace. `--no-learning` opts out. The public
installer names no private learning repo — the manual `vcs import` above uses the
gitignored `private-overlay.repos`, present only in a member's checkout.

## Testing

Container path (CI/parity, default on Linux):

```bash
colcon build --symlink-install
colcon test --packages-select $(colcon list --names-only | grep '^fm_')
colcon test-result --verbose
```

Native path (pixi + RoboStack, default on macOS/Windows):

```bash
pixi install                                   # solve the env from pixi.lock
pixi run build                                 # build src/ + external/ on the host
pixi run test                                  # colcon test on the fm_ packages
```

Use the `build` task, not a bare `pixi run colcon build` — it carries the
`-DPython_EXECUTABLE` cmake arg that lets `rosidl_generator_py` find the env Python
(without it, interface packages fail and abort the whole build). `rosdep` is
unsupported inside a pixi env — add ROS deps with `pixi add ros-humble-<pkg>`
instead (this is how MoveIt and the DDS IDL generator land in the env). The full
workspace builds natively on macOS; driving real Unitree hardware still needs the
Linux container. The container remains the CI/parity path — see
[docs/SETUP.md](docs/SETUP.md).

## Layout

The repo root holds the `fm_ros2` workspace metapackage, the `fm-ros2.repos` and
`external.repos` vcs manifests, and the shared tooling and docs — no package
source. `vcs import < fm-ros2.repos` pulls the four public package repos into
`src/`, where `colcon build` recurses and finds every package regardless of
nesting depth. The `fm_ros2` metapackage depends on the four public group
metapackages (`fm_robot`, `fm_app`, `fm_sim`, `fm_teleop`), each of which pulls its
own sub-packages transitively. The private `private-overlay.repos` overlay adds
the learning packages; colcon builds them too once imported. `install.sh`
provisions the overlay automatically for team members through its auth-gated
team-setup step, so no `--learning` flag is needed on a normal member install;
`--no-learning` opts out. Local checkout dirs
are snake_case (`fm_ros2`, `src/fm_robot`) to match the package names; the GitHub
repo slugs they clone from stay kebab (`fm-ros2`, `fm-robot`), and the `.repos`
manifest filenames follow the slug.

## Diagrams

Architecture diagrams are authored in [d2](https://d2lang.com) under
[`docs/diagrams/`](docs/diagrams/) with the First Motive brand (Geist Mono font,
palette in `styles.d2`). Edit the `.d2`, re-render, and commit both the `.d2` and
the generated `.svg`:

```bash
cd docs/diagrams && ./render.sh
```
