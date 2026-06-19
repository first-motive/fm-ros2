# fm_learning

Learning layer for the fm_ros2 workspace. Groups the data pipeline and the policy
stack — the packages that record robot experience and train, serve, and run
policies on it. Split-ready: this whole group extracts cleanly into its own repo
later.

## Sub-Packages

Each sub-group is itself a metapackage with its own sub-packages, so this layer
nests three levels deep.

| Package | Build | Role |
|---------|-------|------|
| [`fm_data`](fm_data/README.md) | ament_cmake | Data pipeline metapackage: dataset tooling and episode recording |
| [`fm_policy`](fm_policy/README.md) | ament_cmake | Policy metapackage: training and serving the learned policies |

## How the Pieces Connect

`fm_data` captures and packages robot episodes into datasets; `fm_policy` consumes
those datasets to train policies and serves them back to the running stack. Data
flows one way: record → dataset → train → serve. See
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the full system design.

## Build Type

`ament_cmake` metapackage (exec-depends on the two sub-groups). The package itself
builds nothing; it ties the group together for a single install.
