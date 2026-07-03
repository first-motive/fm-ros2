# Architecture

`fm-ros2` is the **orchestrator** for First Motive's ROS2 robot stack.
It assembles four public per-package repos into one colcon workspace — plus a
private learning overlay for team members with access — holds the shared tooling
(Docker, dev container, CI, scripts), and carries the full-system view. It holds
no package source.

This document is the top-of-stack map: how the repos compose, how an operator
enters the system, and where the boundaries sit. Each package repo carries its own
`docs/ARCHITECTURE.md` with the detail for what it does — see
[Per-Repo Architecture](#per-repo-architecture).

The design follows a few systems-engineering principles, made explicit in
[Design Principles](#design-principles):

- **One interface, swappable implementations** — the same robot description and
  controller stack drive a mock, three simulators, or real hardware, selected by
  one argument.
- **Layered separation** — perception/policy, motion control, and hardware are
  distinct repos with one-directional dependencies.
- **Polyrepo, one workspace** — each layer is its own repo under the
  `first-motive` org, carved from the original monorepo with history preserved
  (see [CARVE-RECIPE.md](CARVE-RECIPE.md)). `fm-ros2` assembles them via `vcs`.

## System Overview

`./run.sh` is the front door: a thin dispatcher that reads the install profile
(`.fm_ros2.json`) and routes to the **native** path or the **container** path,
builds the workspace, and execs the `fm_tui` launcher. macOS and Windows run
native — ROS2 Humble on the host via pixi + RoboStack (see [SETUP.md](SETUP.md#why-pixi));
Linux, CI, and parity runs use the Docker container. Shared tooling lives under
`scripts/` by role: `install/` (provision), `run/` (native + container launch),
`ci/` (build + smoke), `dev/` (carve + maintenance).

![run](diagrams/run.svg)

The launcher walks action × robot × backend and dispatches to `fm_bringup`, which
composes the robot stack. Both `fm_tui` and `fm_bringup` live in
[`fm-app`](https://github.com/first-motive/fm-app); the dashed blocks below expand
in that repo's diagrams.

![system](diagrams/system.svg)

Source: [`diagrams/run.d2`](diagrams/run.d2),
[`diagrams/system.d2`](diagrams/system.d2).

## System Context

The workspace runs inside a dev container. Operators drive it from a browser
(Foxglove) or a terminal (TUI). Physics and learning assets are vendored
externals. On Linux, the same stack reaches real OpenArm hardware over CAN.

![context](diagrams/context.svg)

Source: [`diagrams/context.d2`](diagrams/context.d2).

| Actor / System | Role |
|----------------|------|
| Operator | Drives teleop, launches robots, watches the graph |
| Foxglove Studio | Browser viz + Cartesian/joint jog panel (`fm_teleop_panel`) |
| fm_tui | Terminal monitor (live graph) and menu launcher |
| Dev container | Hosts the entire ROS2 node graph; one per host |
| Vendored externals | MuJoCo models, LeRobot, OpenArm description/MoveIt/CAN |
| OpenArm hardware | Real bimanual arms over CAN-FD (Linux native only) |

## Repo Map

Four public package repos assemble into `src/`; a private learning overlay plugs
in on top. Dependencies point one way: the application layer depends on the layers
below it; the learning overlay never depends on the application layer.

![repo map](diagrams/repomap.svg)

Source: [`diagrams/repomap.d2`](diagrams/repomap.d2).

| Repo | Packages | Build | Responsibility |
|------|----------|-------|----------------|
| [fm-app](https://github.com/first-motive/fm-app) | `fm_bringup`, `fm_tui`, `fm_app` | ament_python / cmake | Launch composition + operator TUI — the entry points |
| [fm-robot](https://github.com/first-motive/fm-robot) | `fm_description`, `fm_control`, `fm_sensors`, `fm_robot` | ament_cmake / python | URDF + `ros2_control` + hardware abstraction |
| [fm-sim](https://github.com/first-motive/fm-sim) | `fm_sim_core`, `fm_sim_backends`, `fm_sim_models`, `fm_sim` | ament_cmake | Headless dev loop, backend hosts, MJCF registry |
| [fm-teleop](https://github.com/first-motive/fm-teleop) | `fm_teleop_*` | ament_python | Servo wiring + pluggable input adapters |

The private learning overlay (`fm-data`, `fm-policy`, `fm-learning`) adds the data
engine and policy layer on top — see
[Learning Stack](#learning-stack-private-overlay).

`fm_ros2` (this repo) is the workspace metapackage: it exec-depends on every public
group metapackage, so `colcon build` recurses and finds every package regardless of
nesting depth. When the learning overlay is imported, colcon builds it too.

The dependency direction is the design contract: **`fm_description` is the
foundation**, `fm_control` adds the control layer on top of it, and `fm_bringup`
orchestrates everything. The learning overlay plugs in at the top without the lower
layers knowing it exists.

## Package Dependency Graph

The repo map above is the repo-level view. Below is the full top-down graph: every
`fm_` package and the `<depend>` edges between them. `fm_ros2` exec-depends on the
four public group metapackages, and each group pulls its own leaf packages, so
`colcon build` reaches every package by recursion.

![packages](diagrams/packages.svg)

Source: [`diagrams/packages.d2`](diagrams/packages.d2).

Two properties of the graph are the design contract:

- **`fm_bringup` is the only cross-group edge.** Every dependency that leaves a
  group originates in `fm_bringup` — it pulls `fm_control` (robot), `fm_sim_models`
  and `fm_sim_backends` (sim), and `fm_teleop_device` (teleop). The app layer is
  the sole integration point; no other package reaches across a group boundary.
- **`fm_description` is the foundation.** Inside `fm-robot`, `fm_control` depends on
  `fm_description` and nothing depends back on it. The teleop group is a star — all
  four adapters depend on `fm_teleop_core`, never on each other.

The private learning overlay plugs in at `fm_control` (policy serving feeds the same
control stack the operator drives) and depends on no public package, so it adds a
top edge without the lower layers knowing it exists.

## Per-Repo Architecture

Each repo documents its own internals. The detail that once lived here moved down
with its package.

| Repo | Architecture doc | Covers |
|------|------------------|--------|
| [fm-app](https://github.com/first-motive/fm-app/blob/main/docs/ARCHITECTURE.md) | application layer | Launcher, bringup composition, launch dependency graph, runtime data flow, visualization |
| [fm-robot](https://github.com/first-motive/fm-robot/blob/main/docs/ARCHITECTURE.md) | robot layer | Robot state graph, `ros2_control` controllers, hardware abstraction, robot registry |
| [fm-sim](https://github.com/first-motive/fm-sim/blob/main/docs/ARCHITECTURE.md) | simulation layer | Backend hosts, MJCF registry, headless dev loop |
| [fm-teleop](https://github.com/first-motive/fm-teleop/blob/main/docs/ARCHITECTURE.md) | teleop layer | The input contract, sources, vision pipeline |

The private learning overlay documents its internals in its own (private) repos.

## Hardware Abstraction

The architectural crux of the platform. `fm_control` emits one `ros2_control`
system whose `<hardware>` plugin is chosen by the `sim_backend` argument —
`mock` · `mujoco` · `gazebo` · `isaac` · `real`. Everything above the hardware
interface (controllers, servo, description, teleop) is identical across every
backend, so switching from MuJoCo to real hardware is a launch argument, not a
code change.

The interface lives in `fm-robot`; the sim plugins live in `fm-sim`. Full detail —
the xacro layering and the backend table — is in
[fm-robot's architecture doc](https://github.com/first-motive/fm-robot/blob/main/docs/ARCHITECTURE.md#hardware-abstraction-layer).

## Deployment

One dev container hosts the full node graph. The host OS only provides Docker, the
browser, and (on Linux) the GPU and CAN bus. Compose overlays adapt one image per
platform.

### Image Inheritance

The container is not one monolithic build. The shared `fm-docker` repo publishes a
minimal base, and each package repo's image is `FROM` its parent, so deps point
down through clear layers instead of a single union build:

```
fm-docker base       ros:humble + tooling + viz + xacro/rsp        (view any robot)
   └ fm-robot   FROM base    + ros2-control                        (description + control + sensors)
        ├ fm-sim     FROM robot  + mujoco/gz/xvfb
        └ fm-teleop  FROM robot  + moveit/servo
   └ fm-app     FROM robot  + sim & teleop apt deps + textual      (full-stack launcher)
```

The launcher image (`fm-app`) reconverges the union because the TUI launches every
backend and Docker has single inheritance. `fm-ros2` owns no Dockerfile: it
consumes the published `fm-app` image and sources the compose overlays from
`fm-docker` (both imported via `fm-ros2.repos`). Each package repo also runs and
CI-tests standalone through its own `run.sh`; `fm-ros2` only assembles them.

![deployment](diagrams/deployment.svg)

Source: [`diagrams/deployment.d2`](diagrams/deployment.d2).

| Platform | Role | Backends | Notes |
|----------|------|----------|-------|
| Linux (GPU) | Main system | mock, mujoco, gazebo, isaac, real | Full stack incl. hardware |
| macOS M5 (OrbStack) | Dev / build / sim / dataset | mock, mujoco | No GPU, no hardware; MuJoCo via native arm64 wheel |

This is the container deployment; on macOS and Windows the same launcher runs
native via pixi (no image). The entry point is `./run.sh`, which reads the profile,
and on the container path selects the compose overlay, brings the container up, and
opens the `fm_tui` launcher. The `openarm_hardware` and `openarm_can` packages are
`COLCON_IGNORE`'d on macOS, since they need Linux SocketCAN.

## Learning Stack (private overlay)

The learning loop is a private overlay (`fm-data`, `fm-policy`, `fm-learning`),
imported on top of the public workspace via `fm-learning.repos` by team members
with access. It is not part of the public stack. Structurally it follows the
standard imitation-learning shape:

![learning loop](diagrams/learning.svg)

Source: [`diagrams/learning.d2`](diagrams/learning.d2).

This closes the autonomy loop: teleop generates data, data trains policies, and
policy output feeds back into the same `fm_control` stack the operator drives
manually — manual and autonomous control share one motion path. Internals live in
the private repos.

## Design Principles

The rationale behind the boundaries above.

| Principle | How it shows up | Payoff |
|-----------|-----------------|--------|
| **One interface, many backends** | `sim_backend` selects the `ros2_control` hardware plugin | Sim ↔ real is a launch arg; controllers and teleop never change |
| **Normalize inputs early** | Every teleop adapter emits `delta_twist_cmds` | Add an input device without touching servo or control |
| **Layered, one-way deps** | `description → control → bringup`; data engine plugs in on top | Lower layers stay testable and reusable; no cycles |
| **Description as foundation** | `fm_description` registry abstracts robot + variant + meshes | New robot is a registry entry, not a fork |
| **Polyrepo, one workspace** | Each layer is its own repo; `fm-ros2` assembles them via `vcs` | Teams own and ship their layer independently |
| **Shared motion path** | Manual teleop and the learning overlay's policy serving both reach `fm_control` | Autonomy reuses the validated manual stack |

For setup and run instructions, see [SETUP.md](SETUP.md) and [RUN.md](RUN.md).
Per-package detail lives in each repo's `docs/ARCHITECTURE.md` and
`<package>/README.md`.
