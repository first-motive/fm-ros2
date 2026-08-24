# CI

Every push and pull request runs the jobs in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml): the workflow lint, the
Linux workspace build and headless smoke, the sim-first loop, the macOS native path, the Windows
dispatch check, the installer import-path check, the Foxglove panel build, plus the
drift, bootstrap-selftest, and appliance guards. The commands below are exactly what CI runs, so any job reproduces
locally with the same line — not a prose claim that it works on each system. For the
job summary, see the [CI table in the root README](../README.md#ci).

## Workflow lint

The workflows are code: a composite action, expressions that refer to its outputs,
and shell inside every `run:` block. `actionlint` type-checks the expressions and
runs shellcheck over the shell.

```bash
./scripts/ci/lint-workflows.sh
```

The version is pinned in the script. It uses `actionlint` from `PATH` when you have
it (`brew install actionlint`), and otherwise runs the pinned Docker image — so a
fresh clone needs nothing installed.

## Linux (`ubuntu-latest`)

The full stack, in the same Linux container the team builds from. fm-ros2 owns no
Dockerfile — it pulls the published `fm-app` full-stack image (the top of the
inheritance chain) and tags it `fm-ros2:ci`:

```bash
docker pull ghcr.io/first-motive/fm-app:humble
docker tag ghcr.io/first-motive/fm-app:humble fm-ros2:ci
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci bash -lc './scripts/install/import-externals.sh'
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci \
  bash -lc 'source /opt/ros/humble/setup.bash && colcon build --symlink-install'
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci \
  bash -lc 'source /opt/ros/humble/setup.bash && source install/setup.bash &&
            colcon test --packages-select $(colcon list --names-only | grep "^fm_") &&
            colcon test-result --verbose'
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci ./scripts/ci/ci-smoke.sh
```

## The Sim-First Loop (`ubuntu-latest`)

The data path end to end, on a runner with no hardware: stack up on the sim
backend, record an episode, process it, and assert the manifest describes a
usable one. It drives the same verbs a person types, so a green job is a green
onboarding demo ([ONBOARDING.md](ONBOARDING.md)).

```bash
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci bash -lc './scripts/ci/loop.sh'
```

Locally, through compose:

```bash
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
  run --rm fm ./scripts/ci/loop.sh
```

**Not yet a required check.** It becomes one after two consecutive greens on
`main` — the first runs are what show whether the MuJoCo backend and the recorder
are stable enough on a hosted runner to gate merges.

## macOS (`macos-latest`, arm64)

The M5 daily driver runs the full stack in a Linux container (OrbStack), which
GitHub's macOS runners cannot host. CI instead exercises the host-native,
ROS-free core the M5 runs directly on arm64 CPU — the MuJoCo stepper, the MJCF
registry, and a real native mujoco step:

```bash
./scripts/ci/ci-smoke-macos.sh
```

## Windows (`windows-latest`)

Windows is native-only — no Docker, no ROS2 — and has no user yet. The job keeps that
future path from rotting: the same dispatch smoke the macOS job runs, through Git
Bash, plus the `.ps1` wrappers delegating to it. Nothing else exercises the wrappers.

```bash
./scripts/ci/native-dispatch.sh          # Git Bash
```

```powershell
$env:FM_SELFTEST = '1'
.\install.ps1 --native --viewer foxglove
.\run.ps1 --native
```
