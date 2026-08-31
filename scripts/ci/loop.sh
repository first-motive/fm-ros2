#!/usr/bin/env bash
# The sim-first loop: the whole company's data path, on a machine with no
# hardware attached.
#
#   stack up (sim) -> episode record -> dataset process -> assert the artifacts
#
# Runs inside the built container, after `colcon build` — CI calls it, and it
# runs locally the same way:
#
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm ./scripts/ci/loop.sh
#
# Every step goes through the same verbs a person types (`scripts/run/stack.sh`,
# `episode.sh`, `dataset.sh`), so this job grades the documented path rather than
# a CI-only imitation of it. The one thing it adds is the synthetic operator:
# nobody is driving the arm, so the loop publishes the action stream a real take
# would carry, derived from whatever joints the running robot actually reports.
#
# What it asserts, in order: the stack publishes, an episode reaches the index, a
# manifest is written, and at least one episode in it is usable. A loop that
# records nothing still writes files, so "the artifacts exist" is not the check.
set -uo pipefail # not -e: run the teardown even when a step fails

usage() {
  cat <<'EOF'
loop.sh — the end-to-end sim-first loop, asserted

Usage: ./scripts/ci/loop.sh [--backend B] [--duration S] [-h]

  --backend B    sim backend to run the loop on (default mujoco)
  --duration S   seconds of episode to record (default 8)
  -h, --help     show this help
EOF
}

BACKEND=mujoco
DURATION=8
# The one reviewed task in the engine's default profile
# (thresholds.instruction_quality). Recording under it exercises the real gate.
TASK_ID=first-proof-pick-v1
INSTRUCTION="Pick the object and place it in the target."
JOINT_STATES_TIMEOUT=20 # seconds to wait for the first /joint_states message

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --backend=*)
      BACKEND="${1#--backend=}"
      shift
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --duration=*)
      DURATION="${1#--duration=}"
      shift
      ;;
    *)
      usage >&2
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1

# The two raw `ros2` calls below need the same routing the verbs already do:
# in place when this shell has ROS, through the sim container otherwise. The loop
# runs on the workstation's HOST during the hardware gate, and that host has no
# ROS at all — a bare `ros2` there is not a transport failure, it is a command
# that does not exist, and it reported itself as `no /joint_states message within
# 20s` for as long as the line has been red (gate 3.5).
# shellcheck source=../internal/lib-stack.sh disable=SC1091
source scripts/internal/lib-stack.sh

# Which compose overlay this host and backend imply — resolved once, after the
# arguments are parsed, and read by every routed call below.
OVERLAY="$(fm_stack_overlay "$(fm_stack_normalize "$BACKEND")")"

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

# Hermetic run: a scratch root per invocation, so a rerun never reads the
# episodes a previous one left behind and calls them today's proof.
# Under the workspace, and named RELATIVELY, because the recorder and the engine
# run on the far side of a bind mount. The host's own /tmp is not mounted into the
# container, so a `mktemp -d` root is a path only one of the two can see — the
# recorder wrote nothing and the loop reported `no finalized episode appeared`
# (gate 3.5). A relative path resolves against the workspace root on the host and
# against /ws in the container, which are the same directory.
WORK=".fm-loop-$$"
RECORDINGS="$WORK/recordings"
PROCESSED="$WORK/processed"
mkdir -p "$RECORDINGS" "$PROCESSED"

ACTION_PID=""

teardown() {
  [[ -n "$ACTION_PID" ]] && kill "$ACTION_PID" 2>/dev/null
  # The recorder first, and on the side it actually runs: a host-side pkill never
  # reached a recorder inside the container, so it outlived the loop and the next
  # run found it "already running" — still writing to the previous run's output
  # directory, which is why the episode never reached the new index. Before the
  # stack goes down, while the container is still there to exec into.
  fm_stack_exec "$OVERLAY" pkill -f 'fm_data_record recorder' >/dev/null 2>&1
  ./scripts/run/stack.sh down --backend "$BACKEND" >/dev/null 2>&1
  pkill -f 'fm_data_record recorder' 2>/dev/null
  # Keep the scratch root on a failure — the bag and the manifest are the only
  # evidence of what went wrong, and a red run is exactly when they are wanted.
  if [[ "$fails" -eq 0 ]]; then
    rm -rf "$WORK"
  else
    echo "loop: artifacts left at $WORK"
  fi
  return 0
}
trap teardown EXIT

# The joints the running robot actually reports. Publishing a hand-written joint
# name list would bind this loop to one robot; reading them back binds it to
# whichever robot the stack came up as.
joint_names() {
  # --field prints the list as a Python literal followed by a `---` separator,
  # and `ros2 topic echo` also writes lost-message warnings to stdout — so take
  # the one line that is the list itself and never parse the stream as YAML.
  local reader='
import ast, sys
line = next(l for l in sys.stdin if l.lstrip().startswith("["))
print(",".join(ast.literal_eval(line.strip())))
'
  # `timeout` runs on the FAR side, where coreutils is: the host may be a Mac or a
  # bare rig with neither it nor ros2.
  fm_stack_exec "$OVERLAY" timeout "$JOINT_STATES_TIMEOUT" \
    ros2 topic echo --once --field name /joint_states |
    python3 -c "$reader"
}

# The synthetic operator. A take is only a take if it carries an action channel
# alongside the observations — the recorder's own validation says so, and an
# episode recorded without one is quarantined downstream. Zero velocities: the
# loop proves the path, not the motion.
drive_actions() {
  local names="$1"
  local zeros
  zeros=$(awk -F, '{for (i = 1; i <= NF; i++) printf (i > 1 ? ", 0.0" : "0.0")}' <<<"$names")
  # Detached through the same router: in place it hands back a PID, through the
  # container the publisher lives there and `stack down` reaps it in teardown.
  fm_stack_exec_detached "$OVERLAY" \
    ros2 topic pub -r 20 /servo_node/delta_joint_cmds control_msgs/msg/JointJog \
    "{joint_names: [${names//,/, }], velocities: [$zeros]}"
  ACTION_PID="${FM_STACK_PID:-}"
}

echo "== stack up ($BACKEND) =="
if ./scripts/run/stack.sh up --backend "$BACKEND"; then
  pass "stack up on the $BACKEND backend"
else
  fail "stack never came up on the $BACKEND backend"
  exit 1 # nothing downstream can mean anything without a stack
fi

if ./scripts/run/stack.sh status --backend "$BACKEND"; then
  pass "topic surface complete"
else
  fail "topic surface incomplete — sim does not match the hardware contract"
fi

echo "== episode record (${DURATION}s) =="
NAMES="$(joint_names)"
if [[ -z "$NAMES" ]]; then
  fail "no /joint_states message within ${JOINT_STATES_TIMEOUT}s — cannot drive a take"
  exit 1
fi
drive_actions "$NAMES"

# The reviewed task and instruction from the engine's own profile: the loop
# exercises the real instruction-quality gate rather than a made-up task the
# gate is right to refuse.
if ./scripts/run/episode.sh record --duration "$DURATION" \
  --task-id "$TASK_ID" --instruction "$INSTRUCTION" \
  --output-dir "$RECORDINGS" --backend "$BACKEND"; then
  pass "episode recorded"
else
  fail "episode never reached the index"
fi

kill "$ACTION_PID" 2>/dev/null
ACTION_PID=""

echo "== dataset process =="
# A sim take carries no gripper, and the default profile's outcome gate
# (pick_and_hold) quarantines any success it cannot confirm by terminal grasp.
# The loop proves the path, not a grasp: derive a profile from the engine's
# default with the outcome mode switched to the sidecar label alone, and
# nothing else changed — every other gate still applies to this take.
LOOP_PROFILE="$WORK/loop-profile.json"
./scripts/run/dataset.sh profile --output "$LOOP_PROFILE" --backend "$BACKEND" \
  --set thresholds.outcome_labeling.outcome_mode=source_label_only
if ./scripts/run/dataset.sh process --input "$RECORDINGS" --output "$PROCESSED" \
  --config "$LOOP_PROFILE" --backend "$BACKEND"; then
  pass "dataset processed"
else
  fail "dataset processing exited non-zero"
fi

if ./scripts/run/dataset.sh verify --output "$PROCESSED" --backend "$BACKEND"; then
  pass "manifest describes a usable episode"
else
  fail "manifest missing, empty, or entirely unusable"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "loop: $fails check(s) failed"
  exit 1
fi
echo "loop: green — sim to dataset, no hardware"
