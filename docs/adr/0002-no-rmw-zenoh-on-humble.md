# 0002 — Zenoh Is a Bridge, Not an RMW, Until Jazzy

**Status**: Accepted
**Context**: [fm-comms](https://github.com/first-motive/fm-comms), ADR
[0004](0004-zenoh-behind-a-hardware-gate.md)

## Context

First Motive's machines are not on one flat LAN. The workstation sits in an
office, a recorder travels to a client site, and a laptop reaches both over a
tailnet. DDS discovery assumes multicast between every pair of hosts, which is
exactly what those links do not provide, and the symptom is the worst kind:
`ros2 topic list` shows the topic and no data ever arrives.

Zenoh solves that, and ROS 2 offers it two ways — `rmw_zenoh`, which replaces the
middleware outright, and `zenoh-bridge-ros2dds`, which keeps DDS on each host and
carries traffic between hosts.

`rmw_zenoh` is a Jazzy-era package. On Humble it means building the middleware
from source on every machine — including the Jetson — and running a middleware
whose Humble support is not the configuration upstream tests.

## Decision

Use the bridge. DDS stays the middleware on every host, pinned to localhost, and
`zenoh-bridge-ros2dds` carries what crosses machines, with one `zenohd` router.
Revisit `rmw_zenoh` when the workspace moves to Jazzy, not before.

## Consequences

- No machine builds a middleware from source, and no host runs an RMW that
  differs from the one its ROS distribution ships.
- The transport decision is per-link rather than per-host: what crosses machines
  is what the bridge is configured to carry, and that list is reviewable.
- There is a bridge process to run and supervise on each rig — a real operational
  cost, paid deliberately in exchange for not depending on an unsupported RMW.
- Moving to `rmw_zenoh` later is a middleware swap under the same topic surface,
  not a redesign, because nothing above the transport knows which one is in use.
