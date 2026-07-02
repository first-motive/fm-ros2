# Polyrepo Guide

This is the working guide for First Motive's split GitHub org. The old
all-in-one `fm-ros2` checkout is no longer the place to keep adding source
changes. The source of truth now lives in the per-layer repos under
[`first-motive`](https://github.com/first-motive).

Use this guide for three things:

1. understanding what each repo owns
2. choosing where a change should be made
3. running the common private workflows that now live in `fm-policy` and
   `fm-data`

## Start Here

`fm-ros2` is now the workspace orchestrator. It is the front door for:

- workspace assembly
- Docker and dev-container setup
- shared scripts
- full-stack docs
- importing the public repos into one colcon workspace

Do not keep building new product code in the old monorepo layout. Keep code in
the repo that owns that layer, then assemble the workspace through `fm-ros2`.

## The Repos

### Public repos

| Repo | Purpose | Work here when you are changing |
|------|---------|---------------------------------|
| `fm-ros2` | Workspace orchestrator | workspace scripts, `vcs` manifests, Docker, top-level docs, shared runbooks |
| `fm-app` | Application layer | `fm_bringup`, launch wiring, operator TUI, robot registry, task-env launch composition |
| `fm-robot` | Robot layer | URDF/xacro, control plugins, controllers, drivers, Foxglove robot views |
| `fm-sim` | Simulation layer | sim backends, MJCF assets, model lookup/materialization, sim-only launch support |
| `fm-teleop` | Teleoperation layer | Foxglove panel, leader arm, vision input, retargeting, device input |
| `.github` | Org meta | shared GitHub defaults, org profile, templates, automation defaults |

### Private repos

| Repo | Purpose | Work here when you are changing |
|------|---------|---------------------------------|
| `fm-data` | Data layer | LeRobot viewer, episode export/replay tools, data recording, dataset tooling |
| `fm-policy` | Policy layer | LIBERO training, benchmark scripts, policy-serving docs, private runbooks |
| `fm-learning` | Learning metapackage | the thin overlay that groups `fm-data` and `fm-policy` in one workspace |
| `fm-ai` | AI skills/reference libs | AI helper code and reusable skills, not the robot runtime itself |

## Where To Work

Use the smallest owning repo possible.

If the change is about:

- workspace bootstrap, Docker, `run.sh`, `install.sh`, public top-level docs: use `fm-ros2`
- launch arguments, task-env selection, orchestration, bringup wiring: use `fm-app`
- MuJoCo plugin code, marker generation, URDF/control details, Foxglove robot views: use `fm-robot`
- MJCF task scenes, sim backend launch plumbing, model-path helpers: use `fm-sim`
- panel UI, keyboard control, leader-arm utilities, vision teleop, retarget math: use `fm-teleop`
- episode viewer UI, episode export/replay scripts, recorder helpers, hand-pose extraction: use `fm-data`
- training, benchmark orchestration, LIBERO scripts, experiment summaries: use `fm-policy`
- shared private learning workspace grouping only: use `fm-learning`

If a change spans more than one layer, split it into repo-native commits and PRs.

## Workspace Shape

The normal public workspace flow is:

```bash
git clone https://github.com/first-motive/fm-ros2.git fm_ros2
cd fm_ros2
vcs import src < fm-ros2.repos
./scripts/install/import-externals.sh
./run.sh
```

That gives you:

```text
fm_ros2/
  src/fm_robot
  src/fm_sim
  src/fm_teleop
  src/fm_app
  external/...
```

If you also have private access, add the learning repos into the same workspace.
The exact import manifest may be managed privately, but the intended layout is:

```text
fm_ros2/
  src/fm_data
  src/fm_policy
  src/fm_learning
```

That lets one workspace assemble the public runtime plus the private learning
overlay.

## Branch Rules

During this migration, work continues on repo-specific branches. The current
sync branches are the matching `codex/teleop-sync-20260624` branches in each
repo, and follow-up fixes can continue there until those PRs land.

Normal operating rule:

- for `fm-app`, `fm-robot`, `fm-sim`, `fm-data`, `fm-policy`, `fm-learning`,
  `fm-ai`, and `.github`: assume `main` is managed by that repo's owners;
  continue work on feature branches and merge through PRs
- for `fm-teleop`: RetiefLouw can work from `main` and can merge teleop PRs

If a change touches more than one repo, keep the work on matching branch names
across those repos so review stays easy to follow.

## Common Flows

### 1. Run a training run

Training now lives in `fm-policy`, not in the old monorepo path.

If you are working from the integrated workspace:

```bash
cd fm_ros2/src/fm_policy
vcs import < fm-policy.repos
```

Set up the LIBERO environment:

```bash
fm_policy_train/scripts/setup_libero_env.sh --profile ref_py38
```

Fetch dataset inputs if needed:

```bash
python fm_policy_train/scripts/download_libero_data.py --suite libero_spatial
```

Run a small smoke training pass:

```bash
python fm_policy_train/scripts/run_libero_experiments.py \
  --profile local \
  --alignment-mode forward_probe \
  --run-budget smoke \
  --seeds 42 \
  --dry-run-training
```

Run a benchmark-style pass:

```bash
python fm_policy_train/scripts/run_libero_experiments.py \
  --profile local \
  --alignment-mode lifelong_benchmark \
  --run-budget benchmark \
  --seeds 42
```

Summarize a run:

```bash
python fm_policy_train/scripts/summarize_libero_run.py \
  --run-root runs/libero_5090_batch96_workers4/libero_spatial/bc_transformer_policy/local
```

Use `fm-policy` for:

- training code changes
- benchmark helper scripts
- experiment summaries
- private runbooks

Do not add new training code to `fm-ros2`.

### 2. Run a LeRobot episode

LeRobot episode tooling now lives in `fm-data`.

If you want to export one episode into the local viewer:

```bash
cd fm_ros2/src/fm_data
vcs import < fm-data.repos
./scripts/export-lerobot-viewer-episode.sh \
  --dataset-repo-id LeRobot-worldwide-hackathon/174-Mate-so101_dataset6 \
  --episode-index 0 \
  --output-dir apps/lerobot_episode_viewer/.episode-data \
  --overwrite
```

Run the review app:

```bash
cd apps/lerobot_episode_viewer
npm ci
npm run dev -- --hostname 127.0.0.1 --port 3000
```

If you want to replay an exported episode into Foxglove topics:

```bash
cd fm_ros2/src/fm_data
./scripts/replay-lerobot-viewer-episode-foxglove.sh \
  LeRobot-worldwide-hackathon__174-Mate-so101_dataset6__episode-000000
```

If you want to record a live SO101 MuJoCo episode bundle for the viewer:

```bash
cd fm_ros2/src/fm_data
./scripts/record-so101-mujoco-episode.sh --duration-s 20
```

Use `fm-data` for:

- viewer UI work
- viewer API routes
- episode export/replay helpers
- recorder helpers
- hand-pose extraction

Do not keep those tools under `fm-ros2` anymore.

## Practical Ownership Rules

Before making a change, ask:

1. Which layer owns this behavior?
2. Does this need to compile or ship from one repo, or is it only workspace glue?
3. Is this public-safe, or does it belong in a private repo?

Use `fm-ros2` only when the change is truly about assembly, workspace tooling,
or cross-repo docs. Everything else should move down into the owning repo.

## Short Version

- `fm-ros2` assembles the workspace
- `fm-app` launches it
- `fm-robot` defines and controls the robot
- `fm-sim` defines the sim assets and backends
- `fm-teleop` handles operator input
- `fm-data` handles viewer/data/recording workflows
- `fm-policy` handles training and benchmark workflows
- work continues on repo branches
- teleop is the one repo where RetiefLouw can operate on `main` and merge PRs
