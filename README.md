# fm-ros2

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

First Motive's ROS2 workspace orchestrator.

The public stack lives in four per-package repos under the `first-motive` org. A
private learning overlay (data engine + policy) plugs in on top for team members
with access. This repo holds no package source — it assembles those repos into
one colcon workspace via `vcs`, and carries the shared tooling (Docker, dev
container, CI, scripts) and the full-system docs.

## Quick Start

Provision, then launch from your terminal. The package repos are
private, so this needs git access to the `first-motive` org — see
[docs/RUN.md](docs/RUN.md) for details.

**Install** (setup only — clone + import + viewer):

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh | bash
```

**Run** (build the workspace + open the launcher):

```bash
cd fm_ros2 && ./run.sh
```

`install.sh` is setup only (clone + import + env + viewer); `run.sh` builds the
workspace and opens the launcher. They are split because `run.sh` drives an
interactive menu that a curl pipe cannot supply a terminal for, while `install.sh`
is non-interactive and safe to pipe.

Prefer a GUI? **First Motive** — a native macOS app at
[first-motive/fm-desktop](https://github.com/first-motive/fm-desktop) — is a third
front door beside the two above. It installs, runs, and observes the same stack
through the same script contract, sharing the `~/fm_ros2` workspace and the
`.fm_ros2.json` / `.fm_tui.json` profiles, so the app and the terminal stay in
sync. It is operator-first; the terminal paths remain the reference for dev and CI.

```bash
./run.sh --desktop          # launch First Motive (install it first — macOS)
```

`run.sh --desktop` launches the installed app; it does not build or install. Install
First Motive first: `./install.sh` puts it in `/Applications` for team members,
or use the fm-desktop repo's own `install.sh` directly. See
[docs/RUN.md](docs/RUN.md#desktop-front-door) for the install/run split.

`install.sh` picks a run path by OS: macOS and Windows default to **native**
(ROS2 Humble via pixi + RoboStack, no container), Linux defaults to the
**container** (Docker + compose, also the CI/parity path). Override the path and
viewer with flags; the choice is written to `.fm_ros2.json`, and `run.sh` reads it
to dispatch.

On **macOS the native path is self-contained** — the one-liner brings up the full
stack, including the MuJoCo sim, with no Docker. `import-externals.sh` vendors and
patches `mujoco_ros2_control` for macOS (RoboStack ships no build), the pixi env
carries the hand-tracking deps (mediapipe, trimesh, pycollada), and `pixi run
build` heals the ros2_control + MuJoCo dylibs and links the workspace message
typesupport so custom-message C++ nodes load. A fresh MacBook needs only the
one-liner and `./run.sh`.

```bash
curl ... | bash -s -- --native --viewer foxglove   # pixi/RoboStack, Foxglove
curl ... | bash -s -- --container                  # Docker + compose
```

| Flag | Effect |
|------|--------|
| `--native` | native ROS2 via pixi + RoboStack (default: macOS/Windows) |
| `--container` | Docker + compose (default: Linux; CI/parity elsewhere) |
| `--viewer foxglove\|rviz\|none` | viewer to install (default: foxglove) |

The private learning overlay imports automatically for team members: when the
installer's org-auth gate passes, its team-setup step provisions the overlay on
top of the public workspace. No flag needed. Opt out with `--no-learning`; force
it with `--learning` (which fails loud without org access):

```bash
curl ... | bash -s -- --no-learning   # skip the overlay
```

### Role One-Liners

One command per machine role — the desktop app on a Mac, and the two Linux
appliance roles the same installer provisions:

**Desktop app (macOS)** — pulls the latest release dmg into `/Applications`.
The app repo is private, so the script is fetched over an authenticated `gh`:

```bash
gh api repos/first-motive/fm-desktop/contents/install.sh --jq .content \
  | base64 --decode | bash
```

**Recorder (Linux camera host)** — RealSense + hand tracker + episode recorder,
streaming to the app over the LAN. Ubuntu 22.04 + ROS 2 Humble required;
`--service` makes it a boot appliance (`fm-recorder.service`). Run from the
directory that should own the checkout:

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh \
  | bash -s -- --recorder --service
```

**Data processor (Linux)** — the dataset engine, the annotation tooling
(`annotation_run` / `annotation_verify`), and the supervisor the desktop
app's Process surface drives (`/process/*`). Deliberately its own workspace,
separate from a recorder checkout: the recorder later moves to its own device
while processing stays on the strong host. `--service` installs
`fm-processor.service`:

```bash
mkdir -p ~/processor && cd ~/processor
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh \
  | bash -s -- --processor --service
```

All three need access to the private `first-motive` org: the Linux roles clone
private repos over git auth, and the app installer fetches its release through
`gh`.

`--service` also makes the box discoverable: the installer writes an avahi
advert (`_fm-rig._tcp`, role-tagged) so the desktop app's Settings lists the rig
by hostname — no typed IPs. Every box provisioned with a role one-liner shows up
on its own; both roles on one box advertise as two entries at the same address.

`--service` also enables auto-update on the Linux roles: `fm-update-<role>.timer`
fetches every ~15 minutes and, when a repo is behind, fast-forwards and re-runs
the role installer — merged PRs land on the box within one tick. A take or
processing run in flight is never interrupted. Pause with
`sudo systemctl stop fm-update-<role>.timer`.

The processor can also carry the REAL annotation model (pinned Qwen2.5-VL
weights + a locked GPU runtime, ~22 GB, NVIDIA hosts only) — opt-in because the
default fake-adapter annotation lane needs none of it. Provision it with
`FM_INSTALL_QWEN=1` on the one-liner, later via
`./scripts/install/setup-qwen.sh`, or from the desktop app's Process window.
Model execution itself stays approval-gated per run; provisioning only
downloads and verifies content identities.

The processor additionally gets `fm-sync.timer`, the recordings transfer for a
two-box split: it pulls finalized episodes from the recorder host into
`~/recordings` (index-driven, busy-gated, never deletes at the source). On a
single-box setup it idles as a quiet no-op; when the recorder moves to its own
device, set `FM_SYNC_SOURCE=user@<recorder>:~/recordings` in `/etc/fm-sync.env`
and the split is live on the next tick.

<details>
<summary>Manual steps (fallback)</summary>

```bash
git clone https://github.com/first-motive/fm-ros2.git fm_ros2
cd fm_ros2
./install.sh                       # bootstrap vcs + import repos + externals + viewer
./run.sh                           # auto-detect overlay, open the launcher
```

Clone by hand, then run `install.sh` from the checkout — same setup the curl
pipe runs (vcs bootstrap, package + external import, env + viewer), without
piping to `bash`. Team members get the private overlay automatically (org auth);
use `--no-learning` to skip it, `--native` or `--container` to override the path.

```bash
./run.sh --native      # force the native path (pixi/RoboStack)
./run.sh --container    # force the container path (Docker + compose)
```

</details>

![launcher menu](docs/diagrams/menu.svg)

Source: [`docs/diagrams/menu.d2`](docs/diagrams/menu.d2).
`run.sh` builds the workspace on every invocation, so the first run needs no
separate build step:

```bash
./run.sh                # native: pixi run build, then the launcher
./run.sh --container    # container: compose build + up, then the launcher
```

The native path builds and launches on the host (rviz2 renders natively; Foxglove
Studio connects to the in-env bridge at `ws://localhost:8765`). The container path
builds inside the dev container — see [SETUP.md](docs/SETUP.md) for its compose
commands.

[Setup](docs/SETUP.md) · [externals](docs/EXTERNALS.md) · [Foxglove](docs/FOXGLOVE.md)
· [all guides](docs/README.md). Per-package detail in each `<package>/README.md`.

## Architecture

`fm_description` feeds `fm_control`; control drives a backend-selectable hardware
interface; `fm_bringup` launches the graph. A private learning overlay (data
engine + policy) plugs in on top. Full diagrams: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

![system](docs/diagrams/system.svg)

Entry points invoke `fm_bringup`, which composes the robot stack. Blocks marked
with a stacked edge (`fm_tui`, `fm_bringup`) expand in
[`fm-app`](https://github.com/first-motive/fm-app)'s diagrams; the robot layer
detail lives in [`fm-robot`](https://github.com/first-motive/fm-robot). The
orchestrator view is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Source:
[`docs/diagrams/system.d2`](docs/diagrams/system.d2).

## Layout

This repo holds no package source — only the workspace metapackage, shared
tooling, and full-system docs. `vcs import < fm-ros2.repos` pulls the shared
container infra into `docker/` and the four public package repos into `src/`.

```
fm_ros2/                     local checkout dir (snake to match the packages; GitHub slug stays fm-ros2)
├── fm_ros2/                 workspace metapackage (depends on the 4 public group metas)
├── fm-ros2.repos            vcs manifest: the 4 public package repos -> src/
├── external.repos           vcs pins for vendored externals -> external/
├── pixi.toml / pixi.lock    native ROS2 env: RoboStack channel, 3 platforms
├── docker/                  base image + compose overlays
├── .devcontainer/           VS Code dev container
├── .github/workflows/       CI: Linux build/test + macOS native smoke
├── scripts/                 tooling by role: install/ run/ ci/ dev/
├── docs/                    full-system docs + diagrams
├── install.sh               provisioner: clone + import + env + viewer
└── run.sh                   front door: dispatch native or container
```

The four public package repos (each builds standalone, history preserved from the
split):

| Repo | Layer | Packages |
|------|-------|----------|
| [fm-robot](https://github.com/first-motive/fm-robot) | robot | `fm_description` · `fm_control` · `fm_sensors` |
| [fm-sim](https://github.com/first-motive/fm-sim) | simulation | `fm_sim_core` · `fm_sim_backends` · `fm_sim_models` |
| [fm-teleop](https://github.com/first-motive/fm-teleop) | teleop | `fm_teleop_core` · `device` · `leader` · `vr` · `vision` · `panel` |
| [fm-app](https://github.com/first-motive/fm-app) | application | `fm_bringup` · `fm_tui` |

A private learning overlay plugs in on top for team members with access — see
[Learning Stack](docs/ARCHITECTURE.md#learning-stack-private-overlay).

## Platforms

| Platform | Role |
|----------|------|
| Linux (GPU) | dev · build · sim · hardware |
| macOS M5 (OrbStack) | dev · build · sim · dataset |

macOS runs Humble natively via pixi + RoboStack (the container path stays available
for parity) — no GPU, no hardware; MuJoCo runs native. The full workspace builds
natively; driving real Unitree hardware still needs the container — see
[SETUP.md](docs/SETUP.md).

## CI

[![CI](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml/badge.svg)](https://github.com/first-motive/fm-ros2/actions/workflows/ci.yml)

Seven jobs per push and PR; each reproduces locally with the exact CI command
([docs/CI.md](docs/CI.md)).

| Job | Runner | Proves |
|-----|--------|--------|
| `selftest` | `ubuntu-latest` | `install.sh` + `run.sh` survive the piped curl path |
| `workspace` | `ubuntu-latest` | colcon build + test (`fm_*`) → four-robot headless smoke |
| `installer` | `ubuntu-latest` | `install.sh` clone + import path populates `src/` |
| `macos` | `macos-latest` (arm64) | host-native MuJoCo core + native install/run dispatch |
| `native` | `macos-latest` (arm64) | full pixi env + native build + launcher/launch runtime deps |
| `windows` | `windows-latest` | native dispatch + `.ps1` wrappers delegate through Git Bash |
| `panel` | `ubuntu-latest` | Foxglove teleop panel type-checks and bundles |

## License & Ownership

Maintained by First Motive, a Ubundi subsidiary, under the `first-motive` org.
Licensed under Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
