# fm-ros2 Docs

Guides and references for the fm_ros2 workspace. Start at the root
[README](../README.md) for the project overview, architecture, and quick start.

## Pages

| Page | What it covers |
|------|----------------|
| [ONBOARDING.md](ONBOARDING.md) | The whole loop on a bare laptop in under an hour: sim stack, record, process, verify |
| [SETUP.md](SETUP.md) | macOS (M5, OrbStack) setup: prerequisites, first run, limits, troubleshooting |
| [RUN.md](RUN.md) | `./run.sh` — the front door: detect overlay, build, open the fm_tui launcher |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System context, component layers, runtime data flow, hardware abstraction, deployment |
| [CI.md](CI.md) | The exact commands each CI job runs, reproducible locally per platform |
| [FOXGLOVE.md](FOXGLOVE.md) | `foxglove_bridge` helper modes, robot viewing, teardown |
| [REALSENSE.md](REALSENSE.md) | RealSense D435i on the Linux camera host: launch, record, stream to the Mac, boot service |
| [JETSON.md](JETSON.md) | Jetson Orin Nano bring-up: flash the card on a Mac, first boot, recorder appliance |
| [NATIVE_MUJOCO.md](NATIVE_MUJOCO.md) | Native MuJoCo sim on macOS (pixi + RoboStack): what runs, how it was resolved |
| [EXTERNALS.md](EXTERNALS.md) | Vendoring robot sources, the LeRobot editable env |
| [POLYREPO.md](POLYREPO.md) | Where to work in the split org, and the branch rules |
| [RELEASE.md](RELEASE.md) | The appliance release channel: cutting a tag set, the cadence, verifying convergence |
| [adr/README.md](adr/README.md) | The standing decisions and what would reverse each one: jetson base OS, zenoh as a bridge, the pixi native path, the transport gate |
| [diagrams/README.md](diagrams/README.md) | The d2 diagram sources: render workflow, brand styles, diagram ownership |

## Where Else Docs Live

- Root [README](../README.md) — project overview, platforms, layout, quick start
- `<package>/README.md` — per-package node, topic, and parameter reference
- [CONTRIBUTING](../CONTRIBUTING.md) — contribution workflow
