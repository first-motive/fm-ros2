# Architecture Decisions

The standing decisions behind this workspace, each with the reasoning that
produced it and the conditions that would reverse it. They live here rather than
in a planning document because everyone who reads the code has to live with
them, and a decision nobody can find gets re-litigated every few months.

One file per decision, numbered in the order they were taken. A decision is
never edited to say something else: it is superseded by a later one that names
it.

| ADR | Decision | Status |
| --- | -------- | ------ |
| [0001](0001-jetson-runs-plain-ubuntu.md) | The recorder runs Canonical's Ubuntu for Tegra, not JetPack | Accepted |
| [0002](0002-no-rmw-zenoh-on-humble.md) | Zenoh runs as a bridge, not as an RMW, until the Jazzy upgrade | Accepted |
| [0003](0003-pixi-robostack-native-path.md) | The native path is pixi + RoboStack; the container stays the parity path | Accepted |
| [0004](0004-zenoh-behind-a-hardware-gate.md) | Zenoh-only transport merges only after a three-machine hardware gate | Proposed |
