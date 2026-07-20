# Native MuJoCo on macOS — RESOLVED

The goal from the original handoff is met: the MuJoCo sim backend builds **and
runs** natively on macOS (arm64, pixi + RoboStack Humble), no container. The
OpenArm steps in sim, all five controllers activate, `/joint_states` publishes at
100 Hz, trajectories track exactly, foxglove_bridge serves `ws://localhost:8765`,
and the fm-desktop cockpit's Foxglove client connects and decodes live joint
state. The full vision session (`vision_session.launch.py`) comes up natively:
both `pose_tracking` Servo nodes run; `hand_tracker` runs (mediapipe added to the
pixi env) and only waits on a camera the shell has no TCC permission for — from a
camera-authorized terminal, or with the Quest MJPEG relay (`camera=phone`), it
feeds normally.

## What the blocker was, and the actual fix

The crash — `Could not load library
libmujoco_ros2_control_msgs__rosidl_typesupport_*.dylib` at service creation —
was real, but the original analysis had one wrong premise. On this dyld, a
bare-name dlopen **does** search the main executable's `LC_RPATH` (the prior
session's contrary experiment was run under the CommandLineTools python, which
has no rpaths and scrubs `DYLD_*`; the conda python resolves stock typesupport
libs by bare name just fine). The node's rpath is `$CONDA_PREFIX/lib`, so
candidate fix 1 from the handoff was correct and sufficient:

- **`scripts/install/link-typesupport-macos.sh`** (new) symlinks every
  workspace-built `lib*__rosidl_*.dylib` from `install/*/lib` into
  `$CONDA_PREFIX/lib` — general across all workspace message packages, prunes
  stale links, never shadows a real conda file. `native-build.sh` runs it after
  every build.

Two further macOS issues surfaced once past the typesupport crash, both fixed:

- **MJCF camera rendering under headless** — `MujocoCameras::update_loop` creates
  a GLFW window off the main thread (Cocoa aborts). Now gated off when
  `headless=true` (part of the mujoco patch set). Lidar is `mj_ray`-based and
  unaffected.
- **mediapipe missing natively** — `hand_tracker` imports it; the container pip
  installs it. Added `mediapipe==0.10.14` (the Dockerfile's pin) to
  `[pypi-dependencies]` in `pixi.toml`.

One operational gotcha that masqueraded as a transport bug: **zombie spawners
from an earlier crashed launch** kept retrying against the fresh
controller_manager and double-drove every load/configure/switch (duplicate
"already loaded" errors ms apart, STRICT switch aborts, wedged CM services).
`pkill -f spawner` before relaunching. With a clean process table, bring-up is
deterministic — no DDS config changes needed.

## Durability (fresh install now reproduces everything)

- `external.repos` pins `mujoco_ros2_control` (ros-controls, tag 0.0.3 commit).
- `scripts/install/patches/mujoco-ros2-control-macos.patch` carries the macOS
  patch set (2.51-API downgrade, Mach-O rpaths, GNU-ld guards, `%lu` fix,
  headless camera gate).
- `scripts/install/shims/mujoco_vendor/` carries the vendor shim
  (re-exports conda's libmujoco; upstream mujoco_vendor hard-fails on Darwin).
- `scripts/install/patch-mujoco-macos.sh` (new) writes the shim and applies the
  patch — idempotent, loud on drift. Invoked by `import-externals.sh` (Darwin
  adds `mujoco_ros2_control` + `mujoco_vendor` to BUILD_DIRS; Linux keeps them
  COLCON_IGNORE'd — the container stays on the apt binary) and re-asserted by
  `native-build.sh` before every build.

## Repro

```bash
cd fm_ros2
pixi run build     # 42+ packages, 0 failures; heals patches + typesupport links
pixi run bash -c '
  source install/setup.bash
  export FM_WS="$PWD"
  ros2 launch fm_bringup vision_session.launch.py \
    robot:=openarm variant:=default_bimanual sim_backend:=mujoco viewer:=false
'
# fm-desktop (branch feat/vision-teleop-form): ./run.sh --source, toggle Cockpit,
# Connect to ws://localhost:8765.
```

If controllers fail to activate with "already loaded" noise: stale spawners from
a previous run — `pkill -f spawner; pkill -f ros2_control_node` and relaunch.

## Still open (small)

- `headless=true` is now set in the mujoco `<hardware>` block of all four robot
  xacros (openarm, g1, so101, axol) — sim camera topics therefore don't publish
  on any mujoco path, macOS or container. If container users need MJCF cameras
  back, make the param platform-conditional in the xacro instead.
- `hand_tracker` from a fresh shell needs macOS camera permission (TCC) for
  `camera_input=device`; the Quest relay path does not touch TCC.
