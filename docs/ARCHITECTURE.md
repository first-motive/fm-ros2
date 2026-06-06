# Architecture

First Motive's ROS2 (Humble) workspace, designed as a layered robotics platform.
This document shows the structure: how the packages compose, how data flows at
runtime, and where the system boundaries sit.

The design follows a few systems-engineering principles, made explicit in
[Design Principles](#design-principles):

- **One interface, swappable implementations** — the same robot description and
  controller stack drive a mock, three simulators, or real hardware, selected by
  one argument.
- **Layered separation** — perception/policy, task brain, motion control, and
  hardware are distinct packages with one-directional dependencies.
- **Monorepo mirroring a polyrepo** — directory boundaries are the future
  repo boundaries, so growth is a `git filter-repo`, not a rewrite.

## System Context

The workspace runs inside a dev container. Operators drive it from a browser
(Foxglove) or a terminal (TUI). Physics and learning assets are vendored
externals. On Linux, the same stack reaches real OpenArm hardware over CAN.

```mermaid
flowchart TB
    operator([Operator])
    browser[Foxglove Studio<br/>+ teleop panel]
    tui[fm_tui<br/>monitor / launcher]

    subgraph container [Dev Container · ROS2 Humble]
        nodegraph[ROS2 node graph]
        bridge[foxglove_bridge<br/>ws://8765]
    end

    subgraph externals [Vendored Externals · external.repos]
        mujoco[(MuJoCo MJCF)]
        lerobot[(LeRobot)]
        openarm_ext[(OpenArm desc /<br/>MoveIt / CAN)]
    end

    hw([OpenArm hardware<br/>CAN-FD · Linux only])

    operator --> browser
    operator --> tui
    browser <--> bridge
    bridge <--> nodegraph
    tui --> nodegraph
    nodegraph -.loads.-> mujoco
    nodegraph -.loads.-> openarm_ext
    nodegraph -.records / serves.-> lerobot
    nodegraph -.SocketCAN.-> hw
```

| Actor / System | Role |
|----------------|------|
| Operator | Drives teleop, launches robots, watches the graph |
| Foxglove Studio | Browser viz + Cartesian/joint jog panel (`foxglove_teleop`) |
| fm_tui | Terminal monitor (live graph) and menu launcher |
| Dev container | Hosts the entire ROS2 node graph; one per host |
| Vendored externals | MuJoCo models, LeRobot, OpenArm description/MoveIt/CAN |
| OpenArm hardware | Real bimanual arms over CAN-FD (Linux native only) |

## Component Architecture

Six First Motive packages sit on top of vendored externals. Dependencies point
one way: launch orchestration depends on the layers below it; the data engine and
task brain never depend on launch.

```mermaid
flowchart TD
    subgraph fm [First Motive Packages]
        bringup[fm_bringup<br/>launch · teleop adapters]
        tui[fm_tui<br/>monitor · launcher]

        subgraph vlta [fm_vlta · data engine]
            record[fm_vlta_record]
            dataset[fm_vlta_dataset]
            train[fm_vlta_train]
            serve[fm_vlta_serve]
        end

        orch[fm_orchestration<br/>task brain · sim loop]
        control[fm_control<br/>ros2_control xacro]
        desc[fm_description<br/>URDF · meshes · registry]
    end

    subgraph ext [Vendored Externals]
        oa_desc[openarm_description]
        oa_moveit[openarm_bimanual_moveit_config]
        oa_hw[openarm_hardware · openarm_can]
        oa_mjcf[openarm_mujoco]
        lerobot[lerobot]
    end

    bringup --> control
    bringup --> orch
    bringup --> oa_moveit
    control --> oa_desc
    control --> oa_hw
    desc --> oa_desc
    orch --> oa_mjcf
    serve --> orch
    record --> lerobot
    dataset --> lerobot
    train --> lerobot

    bringup -.launches.-> tui
```

| Package | Build | Responsibility |
|---------|-------|----------------|
| `fm_bringup` | ament_python | Launch files (sim/servo/teleop), controller configs, teleop input adapters |
| `fm_control` | ament_cmake | Backend-selectable `ros2_control` description (mock/mujoco/gazebo/isaac/real) |
| `fm_description` | ament_cmake | URDF/xacro, mesh handling, multi-robot registry (G1-D, SO101, OpenArm) |
| `fm_orchestration` | ament_python | Task brain (stub) + headless MuJoCo sim loop |
| `fm_vlta` | ament_cmake (meta) | Data engine: record → dataset → train → serve |
| `fm_tui` | ament_python | Terminal monitor + menu launcher (Textual) |

The dependency direction is the design contract: **`fm_description` is the
foundation**, `fm_control` adds the control layer on top of it, and `fm_bringup`
orchestrates everything. The data engine (`fm_vlta`) and task brain
(`fm_orchestration`) plug in at the top without the lower layers knowing they
exist.

## Runtime Data Flow

The core loop is teleop into a simulated or real arm. An operator jog command
becomes a Cartesian/joint delta, MoveIt Servo turns it into a trajectory, the
controller streams it to the active backend, and the backend publishes joint
state back — closing the loop at roughly 100 Hz.

```mermaid
sequenceDiagram
    participant Op as Operator input<br/>(Foxglove / joy / spacenav)
    participant Servo as moveit_servo
    participant JTC as joint_trajectory_controller
    participant Back as Backend<br/>(MuJoCo / Gazebo / real)
    participant RSP as robot_state_publisher
    participant Viz as foxglove_bridge

    Op->>Servo: /servo_node/delta_twist_cmds<br/>(unitless TwistStamped)
    Servo->>Servo: IK + collision / singularity check
    Servo->>JTC: /…_arm_controller/joint_trajectory
    JTC->>Back: position command (hardware interface)
    Back->>Back: step physics / drive motors
    Back-->>RSP: /joint_states
    Back-->>Servo: /joint_states (next IK)
    RSP-->>Viz: /tf · /robot_description
    Back-->>Viz: /joint_states
```

Key topics:

| Topic | Type | From → To |
|-------|------|-----------|
| `/servo_node/delta_twist_cmds` | `geometry_msgs/TwistStamped` | teleop adapter → servo |
| `/servo_node/delta_joint_cmds` | `control_msgs/JointJog` | teleop adapter → servo |
| `/…_arm_controller/joint_trajectory` | `trajectory_msgs/JointTrajectory` | servo → JTC |
| `/joint_states` | `sensor_msgs/JointState` | backend → RSP, servo, viz, recorder |
| `/tf`, `/tf_static` | `geometry_msgs/TransformStamped` | RSP → servo, viz |
| `/robot_description` | URDF (XML) | RSP → servo, viz, gazebo |
| `/rosout` | `rcl_interfaces/Log` | all nodes → fm_tui monitor |

Teleop input is pluggable — `teleop.launch.py input:=foxglove|joy|spacenav` swaps
the adapter, but every adapter normalizes to the same `delta_twist_cmds` topic, so
nothing downstream changes.

## Hardware Abstraction Layer

This is the architectural crux. `fm_control` emits one `ros2_control` system
whose `<hardware>` plugin is chosen by the `sim_backend` argument. Everything
above the hardware interface — controllers, servo, description, teleop — is
identical across all backends.

```mermaid
flowchart LR
    arg{{sim_backend}}
    iface[ros2_control<br/>system interface]

    arg -->|mock| mock[mock_components<br/>GenericSystem]
    arg -->|mujoco| mj[mujoco_ros2_control<br/>MujocoSystemInterface]
    arg -->|gazebo| gz[gz_ros2_control<br/>GazeboSimSystem]
    arg -->|isaac| isaac[topic_based_ros2_control<br/>TopicBasedSystem]
    arg -->|real| real[openarm_hardware<br/>OpenArmHW · SocketCAN]

    mock --> iface
    mj --> iface
    gz --> iface
    isaac --> iface
    real --> iface

    iface --> ctrl[controllers · servo · description<br/>identical across backends]
```

| Backend | Plugin | Host | Use |
|---------|--------|------|-----|
| `mock` | `mock_components/GenericSystem` | any CPU | State echo, no physics — fast smoke tests |
| `mujoco` | `mujoco_ros2_control/MujocoSystemInterface` | CPU (arm64 ok) | **Daily driver**, incl. macOS M5 |
| `gazebo` | `gz_ros2_control/GazeboSimSystem` | Linux GPU | Higher-fidelity sim |
| `isaac` | `topic_based_ros2_control/TopicBasedSystem` | Linux GPU + external Isaac | Photoreal sim over ROS topics |
| `real` | `openarm_hardware/OpenArmHW` | Linux native | CAN-FD to DM motors |

The xacro layering that makes this work:

```
openarm.sim.urdf.xacro          (top level)
  ├─ openarm_description geometry + preset YAML   → links, joints, meshes
  └─ openarm.ros2_control.xacro                   → one <ros2_control> per arm
       └─ hardware block selected by sim_backend  → plugin above
```

Because the swap happens at the `<hardware>` boundary, switching from MuJoCo to
real hardware is a launch argument, not a code change.

## Robot Registry

`fm_description` carries a registry that abstracts over three robots. Each entry
defines its description source, variants, and mesh strategy. The viewer and
launchers select by `robot:=` and `variant:=`.

```mermaid
flowchart TD
    reg[Robot Registry<br/>fm_description]
    reg --> g1[g1_d · default<br/>Unitree wheeled G1-D]
    reg --> so[so101<br/>LeRobot SO-ARM100]
    reg --> oa[openarm<br/>bimanual]

    g1 --> g1v[variants: g1_d · g1_29dof_rev_1_0]
    oa --> oav[variants: right_arm · default_bimanual ·<br/>*_with_pinch_gripper]

    g1 -.flat URDF + STL.-> g1mesh[vendored meshes]
    so -.flat URDF + STL.-> somesh[vendored meshes]
    oa -.DAE → STL convert.-> oamesh[openarm_meshes/*.stl]
```

Mesh handling differs by source: G1-D and SO101 ship flat URDF + STL files
vendored into the package, while OpenArm visual `.dae` meshes are converted to
`.stl` at build time so the Foxglove bridge can fetch them over the `package://`
scheme.

## Deployment

One dev container hosts the full node graph. The host OS only provides Docker,
the browser, and (on Linux) the GPU and CAN bus. Compose overlays adapt the same
base image per platform.

```mermaid
flowchart TB
    subgraph mac [macOS · M5 · OrbStack]
        macbrowser[Foxglove Studio]
        subgraph maccontainer [container · compose.macos.yaml]
            macgraph[node graph<br/>backend: mock / mujoco]
            macbridge[foxglove_bridge :8765]
        end
    end

    subgraph linux [Linux · GPU + hardware]
        linbrowser[Foxglove Studio]
        subgraph lincontainer [container · compose.linux.yaml]
            lingraph[node graph<br/>backend: any incl. real]
            linbridge[foxglove_bridge :8765]
        end
        gpu[(GPU)]
        can[(CAN bus → arms)]
    end

    macbrowser <--> macbridge
    linbrowser <--> linbridge
    lincontainer -.NVIDIA runtime.-> gpu
    lincontainer -.SocketCAN.-> can
```

| Platform | Role | Backends | Notes |
|----------|------|----------|-------|
| Linux (GPU) | Main system | mock, mujoco, gazebo, isaac, real | Full stack incl. hardware |
| macOS M5 (OrbStack) | Dev / build / sim / dataset | mock, mujoco | No GPU, no hardware; MuJoCo via native arm64 wheel |

The entry point is `./run.sh`, which detects the host, selects the compose
overlay, brings the container up, and opens the `fm_tui` launcher. The
`openarm_hardware` and `openarm_can` packages are `COLCON_IGNORE`'d on macOS,
since they need Linux SocketCAN.

## Data Engine (VLTA)

`fm_vlta` is the learning loop: record teleop episodes, manage datasets, train
policies, serve inference back into the task brain. It is a metapackage split into
four sub-packages so each can move to its own repo (or the cloud) independently.
The runtime wiring is still being built out — the structure is in place.

```mermaid
flowchart LR
    livegraph[Live ROS graph<br/>/joint_states · cmds] --> record[fm_vlta_record<br/>→ LeRobot episodes]
    record --> dataset[fm_vlta_dataset<br/>manage · replay · HF hub]
    dataset --> train[fm_vlta_train<br/>policy training · cloud-ready]
    train --> serve[fm_vlta_serve<br/>inference]
    serve --> orch[fm_orchestration<br/>task brain]
    orch --> control[fm_control<br/>→ robot]
```

This closes the autonomy loop: teleop generates data, data trains policies, and
policies feed `fm_orchestration`, which commands the same `fm_control` stack the
operator drives manually. Manual and autonomous control share one motion path.

## Design Principles

The rationale behind the boundaries above.

| Principle | How it shows up | Payoff |
|-----------|-----------------|--------|
| **One interface, many backends** | `sim_backend` selects the `ros2_control` hardware plugin | Sim ↔ real is a launch arg; controllers and teleop never change |
| **Normalize inputs early** | Every teleop adapter emits `delta_twist_cmds` | Add an input device without touching servo or control |
| **Layered, one-way deps** | `description → control → bringup`; data engine plugs in on top | Lower layers stay testable and reusable; no cycles |
| **Description as foundation** | `fm_description` registry abstracts robot + variant + meshes | New robot is a registry entry, not a fork |
| **Monorepo mirrors polyrepo** | Directory layout = future repo split | Growth is `git filter-repo`, not a rename |
| **Shared motion path** | Manual teleop and `fm_vlta_serve` both reach `fm_control` | Autonomy reuses the validated manual stack |

For setup and run instructions, see [setup-macos.md](setup-macos.md) and
[run.md](run.md). Per-package detail lives in each `src/<package>/README.md`.
