# 0004 — Zenoh-Only Transport Merges Behind a Hardware Gate

**Status**: Accepted (2026-08-31 — the hardware gate passed on the full fleet:
Rune as router host, fm-ws-01, fm-rec-01, and the cockpit Mac; record in
fm-comms#17. The FastDDS LAN profile is deleted; `FM_TRANSPORT=dds-lan` is
answered with a removal notice and remains unsupported.)
**Context**: ADR [0002](0002-no-rmw-zenoh-on-humble.md),
[fm-comms](https://github.com/first-motive/fm-comms)

## Context

Today two transports are configured. The `foxglove` profile is the default and
uses a FastDDS LAN profile that pins each host to its detected LAN address; the
`zenoh` profile is opt-in and unreachable until a host selects it. Keeping both
means every transport question has two answers, and the LAN profile only works on
the network shape the fleet is leaving behind.

The end state is one transport: DDS pinned to localhost on every host, zenoh
bridges between machines, one RMW default, and comms CI that renders and
validates the json5 configs and smokes a bridge against a router.

The risk is not the design. It is that a half-migrated `main` destroys other
people's work: a transport that is correct on a laptop and wrong on the rig is
indistinguishable from a broken rig until someone tries to record.

## Decision

Build the zenoh-only path on a feature branch across fm-comms, fm-ros2, and
fm-docker. Before merging, prove it on hardware: a Mac, a recorder, and the
workstation exchanging `/joint_states` and episode traffic, with the checklist
recorded in the pull request.

Only after that gate passes: delete the FastDDS LAN profile, and keep
`FM_TRANSPORT=dds-lan` as an escape hatch labelled unsupported.

### The router host

The fleet's single `zenohd` router runs on Rune, the office Mac mini, as a
LaunchDaemon on the **host**. Rune is the only machine that is always on, wired,
and on the tailnet. The GPU workstation was the obvious alternative and is the
wrong one: it is wiped, rebooted, and loaded with sim and inference, and every
reboot there would take the fleet's discovery point with it. A recorder must keep
its session through a workstation reboot; that is a gate line (7.2), not a hope.

The router never runs inside Rune's CI guest. The guest is ephemeral and
Softnet-isolated by design, so a router there is unreachable while it exists and
gone when the job ends. The installer refuses a virtual machine and refuses the
`fm-ci` account as owner. Sharing the mini is fine; sharing the sandbox is not.

The router listens on Rune's LAN address and its tailnet address, both. In the
office a rig connects over plain TCP on the LAN; off-site, or on a Wi-Fi link
that filters multicast, the same rig connects through the tailnet. A rig that
moves between the two changes its endpoint, not its transport.

## Consequences

- `main` never carries a transport nobody has run on three real machines.
- The gate is a recorded checklist in a pull request, not a recollection — the
  evidence outlives the session that produced it.
- Until the gate passes, both transports stay configured and the duplication
  stands. That is the cost of not breaking the fleet.
- The escape hatch is deliberate and named: an operator on a network where zenoh
  cannot reach can still work, and the label says nobody is maintaining that
  path.
