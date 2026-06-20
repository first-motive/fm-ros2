#!/usr/bin/env bash
# Host-native macOS smoke: the ROS-free sim core that runs on bare arm64 — no
# Docker, no ROS2. The M5 daily driver runs the full stack inside a Linux
# container (OrbStack), which GitHub's macOS runners cannot host; this covers the
# pieces the M5 runs natively on CPU. CI calls it on macos-latest, and it runs
# locally the same way:
#
#   ./scripts/ci-smoke-macos.sh
#
# Covers the deterministic host-native items: the ROS-free MuJoCo stepper logic,
# the MJCF registry lookup, and a real native-arm64 MuJoCo wheel step. The
# container build, colcon build + test, and the three-robot teleop asserts run in
# the Linux job (scripts/ci-smoke.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The ROS-free packages aren't installed here — point Python at their sources.
# fm_sim lives in the fm-sim repo, imported under src/fm-sim (override with SIM_SRC).
SIM_SRC="${SIM_SRC:-src/fm-sim}"
export PYTHONPATH="$SIM_SRC/fm_sim_core:$SIM_SRC/fm_sim_models"

echo "==> pytest: ROS-free sim core (stepper + MJCF registry)"
uv run --with pytest --with mujoco pytest -q \
  "$SIM_SRC/fm_sim_core/test/test_sim.py" \
  "$SIM_SRC/fm_sim_models/test/test_models.py" \
  "$SIM_SRC/fm_sim_models/test/test_import.py"

echo "==> native mujoco: step the built-in model on arm64 CPU"
uv run --with mujoco python - <<'PY'
from fm_sim_core.stepper import MujocoStepper

stepper = MujocoStepper()  # built-in 1-DOF MJCF, real mujoco wheel
sample = stepper.step()
assert stepper.njoints == 1, stepper.njoints
assert sample.names == ["joint0"], sample.names
assert len(sample.positions) == 1
print("PASS: native mujoco step on arm64")
PY

echo "==> ci-smoke-macos: all host-native checks passed"
