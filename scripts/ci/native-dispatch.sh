#!/usr/bin/env bash
# Native install/run dispatch smoke — shared by the macOS and Windows CI jobs and
# runnable locally. Exercises the bootstrap logic without a real env solve or
# launch, via the FM_SELFTEST hooks: install.sh flag parsing + OS-default profile
# routing + viewer allowlist, run.sh dispatcher routing, and the pixi lockfile
# consistency check (skipped when pixi is absent). No Docker, no ROS2, no network.
#
#   ./scripts/ci/native-dispatch.sh
#
# Wrapped in main() and called on the last line so a truncated pipe never half-runs.
set -euo pipefail

main() {
  case "${1:-}" in
    -h|--help)
      echo "native-dispatch.sh — smoke the native install/run dispatch (FM_SELFTEST)"
      return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$ROOT"

  # Save and restore any real profile so a run never clobbers .fm_ros2.json or the
  # launcher's .fm_tui.json (the V-toggle, which outranks the profile in the native
  # viewer resolution — it must be absent for the profile asserts below). EXIT
  # (not RETURN) because set -e aborts skip the RETURN trap — a failed assert must
  # still restore. Globals (not local) so the trap sees them after main returns.
  PROFILE_PATH="$ROOT/.fm_ros2.json"
  TUI_PATH="$ROOT/.fm_tui.json"
  PROFILE_BAK=""; PROFILE_EXISTED=0
  TUI_BAK=""; TUI_EXISTED=0
  if [[ -f "$PROFILE_PATH" ]]; then PROFILE_BAK="$(cat "$PROFILE_PATH")"; PROFILE_EXISTED=1; fi
  if [[ -f "$TUI_PATH" ]]; then TUI_BAK="$(cat "$TUI_PATH")"; TUI_EXISTED=1; fi
  restore_profile() {
    if [[ "$PROFILE_EXISTED" == 1 ]]; then printf '%s' "$PROFILE_BAK" > "$PROFILE_PATH"
    else rm -f "$PROFILE_PATH"; fi
    if [[ "$TUI_EXISTED" == 1 ]]; then printf '%s' "$TUI_BAK" > "$TUI_PATH"
    else rm -f "$TUI_PATH"; fi
  }
  trap restore_profile EXIT
  rm -f "$TUI_PATH"

  echo "==> install flags + OS-default profile routing (FM_SELFTEST)"
  # The OS default resolves to native on macOS and Windows; flags + viewer
  # allowlist hold on every host.
  FM_SELFTEST=1 ./install.sh --native --viewer foxglove | grep -q 'path=native, viewer=foxglove'
  FM_SELFTEST=1 ./install.sh --container --viewer rviz  | grep -q 'path=container, viewer=rviz'
  FM_SELFTEST=1 ./install.sh --native --viewer none     | grep -q 'path=native, viewer=none'
  if FM_SELFTEST=1 ./install.sh --viewer bogus >/dev/null 2>&1; then
    echo "FAIL: install.sh accepted an invalid viewer" >&2; return 1
  fi
  # The native install + run scripts parse and resolve under selftest.
  FM_SELFTEST=1 ./scripts/install/native.sh --viewer foxglove | grep -q 'native.sh parsed'

  echo "==> run.sh dispatcher routing"
  # The dispatcher resolves a native profile to the native path; an override flag
  # wins; an unknown path errors. run.sh stops at its own selftest hook after
  # resolving, so assert the resolved path here.
  printf '{"path":"native","viewer":"rviz"}\n' > "$PROFILE_PATH"
  FM_SELFTEST=1 ./run.sh             | grep -q 'run.sh dispatch resolved (path=native'
  FM_SELFTEST=1 ./run.sh --container | grep -q 'run.sh dispatch resolved (path=container'
  # The native run path itself resolves the viewer from the profile.
  FM_SELFTEST=1 ./scripts/run/native.sh | grep -q 'native run resolved (viewer=rviz'
  # The launcher's V-toggle (.fm_tui.json) outranks the install profile.
  printf '{"viewer":"none"}\n' > "$TUI_PATH"
  FM_SELFTEST=1 ./scripts/run/native.sh | grep -q 'native run resolved (viewer=none'
  rm -f "$TUI_PATH"
  printf '{"path":"bogus","viewer":"rviz"}\n' > "$PROFILE_PATH"
  if ./run.sh >/dev/null 2>&1; then
    echo "FAIL: run.sh accepted an unknown path" >&2; return 1
  fi
  echo "PASS: native dispatch + flag parsing"

  # pixi env: when pixi is present, the lockfile must stay consistent with the
  # manifest and cover all three platforms — a fast solve-consistency check. The
  # heavy full-env install runs elsewhere; here it validates one manifest solves.
  if command -v pixi >/dev/null 2>&1; then
    echo "==> pixi: lockfile consistent with pixi.toml (osx-arm64, win-64, linux-64)"
    pixi lock --check
    local p
    for p in osx-arm64 win-64 linux-64; do
      grep -q "$p" pixi.lock || { echo "FAIL: $p missing from pixi.lock" >&2; return 1; }
    done
    echo "PASS: pixi lock consistent across three platforms"
  else
    echo "SKIP: pixi not on PATH — lock check deferred"
  fi

  echo "==> native-dispatch: all checks passed"
}

main "$@"
