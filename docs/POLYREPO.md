# Polyrepo Guide

This is the working guide for First Motive's split GitHub org. The old
all-in-one `fm-ros2` checkout is no longer the place to keep adding source
changes. The source of truth now lives in the per-layer repos under
[`first-motive`](https://github.com/first-motive).

Use this guide for two things:

1. understanding what each public repo owns
2. choosing where a change should be made

## Start Here

`fm-ros2` is now the workspace orchestrator. It is the front door for:

- workspace assembly
- Docker and dev-container setup
- shared scripts
- full-stack docs
- importing the public repos into one colcon workspace

Do not keep building new product code in the old monorepo layout. Keep code in
the repo that owns that layer, then assemble the workspace through `fm-ros2`.

## The Public Repos

| Repo | Purpose | Work here when you are changing |
|------|---------|---------------------------------|
| `fm-ros2` | Workspace orchestrator | workspace scripts, `vcs` manifests, Docker, top-level docs, shared runbooks |
| `fm-app` | Application layer | `fm_bringup`, launch wiring, operator TUI, robot registry, task-env launch composition |
| `fm-robot` | Robot layer | URDF/xacro, control plugins, controllers, drivers, Foxglove robot views |
| `fm-sim` | Simulation layer | sim backends, MJCF assets, model lookup/materialization, sim-only launch support |
| `fm-teleop` | Teleoperation layer | Foxglove panel, leader arm, vision input, retargeting, device input |
| `.github` | Org meta | shared GitHub defaults, org profile, templates, automation defaults |

A private learning overlay plugs in on top for team members with access. Its
repos, workflows, and import manifest are documented privately — see the
member-only org profile.

## Where To Work

Use the smallest owning repo possible.

If the change is about:

- workspace bootstrap, Docker, `run.sh`, `install.sh`, public top-level docs: use `fm-ros2`
- launch arguments, task-env selection, orchestration, bringup wiring: use `fm-app`
- MuJoCo plugin code, marker generation, URDF/control details, Foxglove robot views: use `fm-robot`
- MJCF task scenes, sim backend launch plumbing, model-path helpers: use `fm-sim`
- panel UI, keyboard control, leader-arm utilities, vision teleop, retarget math: use `fm-teleop`

If a change spans more than one layer, split it into repo-native commits and PRs.

## Workspace Shape

`fm-ros2` is the single entryway. The one-curl installer clones the workspace,
imports every manifest, and sets up the viewer:

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh | bash
cd fm_ros2 && ./run.sh
```

Under the hood that is the manifest import — run it directly inside an existing
checkout if you prefer:

```bash
vcs import < fm-ros2.repos                 # container infra + public packages
./scripts/install/import-externals.sh      # vendored externals
```

Keep the workspace current with the shared `fm` CLI rather than pulling each
repo by hand — `fm update` fast-forwards every clean repo and skips the dirty
ones, and `scripts/update.sh` re-runs the manifest imports:

```bash
fm status     # which repos are behind
fm update     # converge the clean ones
```

The import gives you:

```text
fm_ros2/
  src/fm_robot
  src/fm_sim
  src/fm_teleop
  src/fm_app
  external/...
```

Team members with private access layer the learning overlay on top of the same
workspace; the import manifest is managed privately.

## Branch Rules

During this migration, work continues on repo-specific branches. Assume `main`
is managed by each repo's owners; continue work on feature branches and merge
through PRs. If a change touches more than one repo, keep the work on matching
branch names across those repos so review stays easy to follow.

## Short Version

- `fm-ros2` assembles the workspace
- `fm-app` launches it
- `fm-robot` defines and controls the robot
- `fm-sim` defines the sim assets and backends
- `fm-teleop` handles operator input
- work continues on repo branches
