# 0004 — Zenoh-Only Transport Merges Behind a Hardware Gate

**Status**: Proposed
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

## Consequences

- `main` never carries a transport nobody has run on three real machines.
- The gate is a recorded checklist in a pull request, not a recollection — the
  evidence outlives the session that produced it.
- Until the gate passes, both transports stay configured and the duplication
  stands. That is the cost of not breaking the fleet.
- The escape hatch is deliberate and named: an operator on a network where zenoh
  cannot reach can still work, and the label says nobody is maintaining that
  path.
