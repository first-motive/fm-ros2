#!/usr/bin/env bash
# Host-native macOS smoke: the ROS-free sim core that runs on bare arm64 — no
# Docker, no ROS2. The M5 daily driver runs the full stack inside a Linux
# container (OrbStack), which GitHub's macOS runners cannot host; this covers the
# pieces the M5 runs natively on CPU. CI calls it on macos-latest, and it runs
# locally the same way:
#
#   ./scripts/ci/ci-smoke-macos.sh
#
# Covers the deterministic host-native items: the ROS-free MuJoCo stepper logic,
# the MJCF registry lookup, and a real native-arm64 MuJoCo wheel step. The
# container build, colcon build + test, and the four-robot teleop asserts run in
# the Linux job (scripts/ci/ci-smoke.sh).
set -euo pipefail

usage() {
  cat <<'EOF'
ci-smoke-macos.sh — host-native macOS smoke: the ROS-free sim core on bare arm64

Usage: ./scripts/ci/ci-smoke-macos.sh [-h]

  -h, --help   show this help

Env: SIM_SRC  fm_sim source root (default: src/fm_sim)
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$ROOT"

  # The ROS-free packages aren't installed here — point Python at their sources.
  # fm_sim lives in the fm-sim repo, imported under src/fm_sim (override with SIM_SRC).
  local SIM_SRC="${SIM_SRC:-src/fm_sim}"
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

  # The native path is the recommended macOS path — smoke its bootstrap logic
  # without a real env solve or launch, via the FM_SELFTEST hooks. Save and restore
  # any real profile so a local run never clobbers the developer's .fm_ros2.json.
  echo "==> native dispatch: install flags + profile routing (FM_SELFTEST)"
  # Globals (not local) so the EXIT trap can still see them after main returns.
  # EXIT (not RETURN) because set -e aborts skip the RETURN trap — a failed assert
  # must still restore the developer's real profile.
  PROFILE_PATH="$ROOT/.fm_ros2.json"
  PROFILE_BAK=""
  PROFILE_EXISTED=0
  if [[ -f "$PROFILE_PATH" ]]; then PROFILE_BAK="$(cat "$PROFILE_PATH")"; PROFILE_EXISTED=1; fi
  restore_profile() {
    if [[ "$PROFILE_EXISTED" == 1 ]]; then printf '%s' "$PROFILE_BAK" > "$PROFILE_PATH"
    else rm -f "$PROFILE_PATH"; fi
  }
  trap restore_profile EXIT

  # install.sh: macOS default resolves to native; flags + viewer allowlist hold.
  FM_SELFTEST=1 ./install.sh                            | grep -q 'path=native, viewer=foxglove'
  FM_SELFTEST=1 ./install.sh --container --viewer rviz  | grep -q 'path=container, viewer=rviz'
  FM_SELFTEST=1 ./install.sh --native --viewer none     | grep -q 'path=native, viewer=none'
  if FM_SELFTEST=1 ./install.sh --viewer bogus >/dev/null 2>&1; then
    echo "FAIL: install.sh accepted an invalid viewer" >&2; return 1
  fi
  # The native install + run scripts parse and resolve under selftest.
  FM_SELFTEST=1 ./scripts/install/native.sh --viewer foxglove | grep -q 'native.sh parsed'

  # run.sh dispatcher: a native profile routes to the native run path; an override
  # flag wins; an unknown path errors.
  printf '{"path":"native","viewer":"rviz"}\n' > "$PROFILE_PATH"
  FM_SELFTEST=1 ./run.sh          | grep -q 'native run resolved (viewer=rviz'
  FM_SELFTEST=1 ./run.sh --native | grep -q 'native run resolved'
  printf '{"path":"bogus","viewer":"rviz"}\n' > "$PROFILE_PATH"
  if ./run.sh >/dev/null 2>&1; then
    echo "FAIL: run.sh accepted an unknown path" >&2; return 1
  fi
  echo "PASS: native dispatch + flag parsing"

  # pixi env: when pixi is present, the lockfile must stay consistent with the
  # manifest and cover all three platforms. The heavy install + solve runs in the
  # CI job; here it is a fast consistency check, skipped when pixi is absent.
  if command -v pixi >/dev/null 2>&1; then
    echo "==> pixi: lockfile consistent with pixi.toml (osx-arm64, win-64, linux-64)"
    pixi lock --check
    local p
    for p in osx-arm64 win-64 linux-64; do
      grep -q "$p" pixi.lock || { echo "FAIL: $p missing from pixi.lock" >&2; return 1; }
    done
    echo "PASS: pixi lock consistent across three platforms"
  else
    echo "SKIP: pixi not on PATH — install + env solve runs in the CI job"
  fi

  echo "==> ci-smoke-macos: all host-native checks passed"
}

main "$@"
