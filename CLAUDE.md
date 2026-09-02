# CLAUDE.md

Guidance for Claude Code and Codex working in this repo. See [README](README.md)
for the project overview and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the
system design.

## Purpose

`fm-ros2` is the orchestrator for First Motive's ROS2 robot stack. The
public packages live in four per-package repos under the `first-motive` org; a
private data overlay plugs in on top for team members with access. This repo
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

## Script Taxonomy

A script's directory declares what kind of thing it is. Put a new script in the
one that matches how it is invoked:

| Directory           | Holds                                              | In `fm.json` |
| ------------------- | -------------------------------------------------- | ------------ |
| `scripts/run/`      | workflows a person types                           | always       |
| `scripts/env/`      | profiles sourced into a shell, never executed      | never        |
| `scripts/service/`  | entry points systemd units and timers own          | never        |
| `scripts/internal/` | scripts other scripts call, never invoked directly | never        |
| `scripts/install/`  | provisioning steps `install.sh` drives             | never        |
| `scripts/ci/`       | checks the CI workflows run                        | never        |
| `scripts/dev/`      | maintainer utilities, run by hand and rarely       | never        |

One rule follows from it, and `fm doctor` enforces it:

```
scripts/run/*.sh  ⟺  a verb in fm.json     (nothing else lives there)
```

## fm CLI Contract

`fm` mounts this repo's workflows as top-level verbs by reading `fm.json` at the
repo root. A new workflow script in `scripts/run/` must be declared there, or it
stays unreachable from `fm`.

- Declare it: add `"<verb>": {"script": "scripts/run/<name>.sh", "help": "<one line>"}`
  under `commands` in `fm.json`.
- Verify it: `fm doctor` fails on a declared script that is missing or not
  executable, and warns on a `scripts/run/*.sh` that no manifest declares.

Arguments are forwarded to the script verbatim — the CLI parses none of them, so
the script stays the single source of truth for its own flags. See the `fm-cli`
skill for the manifest schema and the full verb surface.

## Assembly

```bash
vcs import < fm-ros2.repos     # pull container infra into docker/, zenoh transport configs into comms/, the four package repos into src/
vcs import < private-overlay.repos # private overlay — team members with access
./scripts/install/import-externals.sh      # vendor externals into external/
```

The data overlay is provisioned automatically for team members: `install.sh`'s
auth gate (gh auth + org read) routes it through the private team-setup step, which
imports it on top of the public workspace. `--no-learning` opts out — the flag keeps
its original spelling, from when the overlay still carried the policy layer. The
public installer names no private repo — the manual `vcs import` above uses the
gitignored `private-overlay.repos`, present only in a member's checkout.

## Testing

Container path (CI/parity, default on Linux):

```bash
./scripts/run/build.sh                         # or `fm build` — src/, external/, nested repos
colcon test --packages-select $(colcon list --names-only | grep '^fm_')
colcon test-result --verbose
```

`fm build` rather than a bare `colcon build`: a package repo ships a metapackage
at its root, colcon stops descending there, and the packages nested inside it are
silently never built.

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

That convention binds every manifest that writes into this workspace, the
private overlay included. A package repo ships a metapackage manifest at its
root, so colcon stops descending there, and the scripts that build the nested
packages reach past it by spelling the snake path literally. A checkout under
the kebab slug leaves those paths matching nothing, and when both spellings
exist colcon sees each package twice and refuses to build. The import paths
warn on either shape (`warn_kebab_checkouts` in `lib.sh`), but the fix belongs
in the manifest that wrote the path.

## Diagrams

Architecture diagrams are authored in [d2](https://d2lang.com) under
[`docs/diagrams/`](docs/diagrams/) with the First Motive brand (Geist Mono font,
palette in `styles.d2`). Edit the `.d2`, re-render, and commit both the `.d2` and
the generated `.svg`:

```bash
cd docs/diagrams && ./render.sh
```
