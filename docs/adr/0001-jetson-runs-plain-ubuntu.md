# 0001 — The Recorder Runs Plain Ubuntu, Not JetPack

**Status**: Accepted
**Context**: [docs/JETSON.md](../JETSON.md), fm-setup's `fm flash`

## Context

The recorder is a Jetson Orin Nano with no monitor and no keyboard: it is flashed
on a Mac, inserted, and powered on. NVIDIA's own path to that board is JetPack,
which expects an attended first-boot wizard, ships a desktop environment nothing
here uses, and pins the image to whatever L4T release it was cut against.

What the recorder actually needs from the board is narrow: r36.x firmware in
QSPI, Ubuntu 22.04 as the base ROS 2 Humble is built for, and the drivers for the
sensors it carries.

## Decision

Flash Canonical's preinstalled server image for Tegra
(`ubuntu-22.04-preinstalled-server-arm64+tegra-jetson.img.xz`), not JetPack, and
provision everything else from fm-setup at first boot: the hostname, the `fm`
appliance user, ssh keys, the container runtime, and the ROS layer.

The board still needs JetPack-era firmware in QSPI — any board that has run
JetPack 6 qualifies — so this is a decision about the *root filesystem*, not
about the firmware.

## Consequences

- First boot is unattended. No wizard, no monitor, no keyboard, which is what
  makes "flash a card, insert it, power on" a real workflow rather than a
  description of one.
- The image is one Canonical release, not an NVIDIA bundle, so the OS layer
  updates on Ubuntu's schedule and everything above it is ours.
- Anything JetPack would have installed — CUDA, TensorRT, the multimedia stack —
  is an explicit provisioning step in fm-setup when a role needs it, rather than
  present by default on a machine whose job is to record.
- A board with no JetPack-era firmware in QSPI must be brought up to r36.x
  first; the card cannot do it.
