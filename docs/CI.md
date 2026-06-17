# CI

Every push and pull request runs three jobs ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)).
The commands below are exactly what CI runs, so any job reproduces locally with
the same line — not a prose claim that it works on each system. For the job
summary, see the [CI table in the root README](../README.md#ci).

## Linux (`ubuntu-latest`)

The full stack, in the same Linux container the team builds from:

```bash
docker build -t fm-ros2:ci -f docker/Dockerfile.base .
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci bash -lc './scripts/import-externals.sh'
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci \
  bash -lc 'source /opt/ros/humble/setup.bash && colcon build --symlink-install'
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci \
  bash -lc 'source /opt/ros/humble/setup.bash && source install/setup.bash &&
            colcon test --packages-select $(colcon list --names-only | grep "^fm_") &&
            colcon test-result --verbose'
docker run --rm -v "$PWD:/ws" -w /ws fm-ros2:ci ./scripts/ci-smoke.sh
```

## macOS (`macos-latest`, arm64)

The M5 daily driver runs the full stack in a Linux container (OrbStack), which
GitHub's macOS runners cannot host. CI instead exercises the host-native,
ROS-free core the M5 runs directly on arm64 CPU — the MuJoCo stepper, the MJCF
registry, and a real native mujoco step:

```bash
./scripts/ci-smoke-macos.sh
```
