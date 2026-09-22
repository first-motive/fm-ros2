#!/usr/bin/env bash
# The dataset verbs run where the engine is (#145).
#
#   ./scripts/ci/test-dataset-runtime.sh
#
# `fm dataset process` resolved the SIM stack's compose project, so on a
# workstation it ran the engine inside a container built without it and reported
# `Package 'fm_data_dataset' not found` — while the processor container sat beside
# it with the engine built and the data directories mounted. The routing is the
# whole bug, so the routing is what is asserted.
#
# Every host check is stubbed, so this runs on any CI guest with no Docker, no ROS
# and no processor role installed.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../internal/lib-processor.sh disable=SC1091
source scripts/internal/lib-processor.sh

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/uv-python"
# The merged processor compose contract requires the provisioned host's managed
# Python tree. This test stubs that prerequisite because it verifies routing only.
export FM_PROCESSOR_UV_PYTHON_ROOT="$WORK/uv-python"

echo "== the role marker decides =="
FM_PROCESSOR_ENV_FILE="$WORK/absent.env"
if fm_processor_installed; then
  fail "a host with no processor EnvironmentFile claimed the role"
else
  pass "a host with no processor role falls back to the stack"
fi

FM_PROCESSOR_ENV_FILE="$WORK/fm-processor.env"
touch "$FM_PROCESSOR_ENV_FILE"
if fm_processor_installed; then
  pass "a host with the processor EnvironmentFile owns the role"
else
  fail "the processor role went undetected with its EnvironmentFile present"
fi

echo "== the command lands in the processor's runtime =="
# The runtime picker reads this; the point here is the routing, not the picking.
# shellcheck disable=SC2034  # read by fm_processor_runtime, through the library
FM_PROCESSOR_RUNTIME=native
got="$(fm_processor_exec "$PWD" echo landed-native)"
if [[ "$got" == "landed-native" ]]; then
  pass "a Humble host runs the engine in place"
else
  fail "the native runtime did not run the command — got '$got'"
fi

# Container: the invocation must address the processor's OWN compose project, and
# route through the image entrypoint so ROS and the overlay are sourced.
# shellcheck disable=SC2034  # read by fm_processor_runtime, through the library
FM_PROCESSOR_RUNTIME=container
# shellcheck disable=SC2329  # invoked by the library, which resolves it as a command
docker() {
  if [ -n "${FM_ARCHIVE_UPLOADER_ENVFILE:-}" ]; then
    [ "${FM_ARCHIVE_UPLOADER_ENV_FILE:-}" = "$FM_ARCHIVE_UPLOADER_ENVFILE" ] || return 9
  fi
  printf '%s\n' "$*"
  return "${FM_TEST_DOCKER_EXIT:-0}"
}
got="$(fm_processor_exec /workspace echo landed-container)"

case "$got" in
  *"-p fm-processor"*) pass "the processor container is addressed, not the sim stack's" ;;
  *) fail "the invocation names the wrong compose project: $got" ;;
esac
case "$got" in
  *"compose.processor.yaml"*) pass "the processor overlay is stacked in" ;;
  *) fail "the processor overlay is missing: $got" ;;
esac
case "$got" in
  *"/ros_entrypoint.sh echo landed-container"*) pass "the command routes through the image entrypoint" ;;
  *) fail "the command bypasses the entrypoint: $got" ;;
esac

# The archive ledger query uses the same existing-only runtime boundary.
printf 'FM_ARCHIVE_UPLOADER_STATE_DIR=/data/private archive\n' >"$WORK/fm-processor.env"
export -f docker
got="$(FM_PROCESSOR_RUNTIME=container FM_PROCESSOR_ENV_FILE="$WORK/fm-processor.env" \
  FM_ARCHIVE_UPLOADER_ENVFILE="$WORK/fm-processor.env" FM_TRANSPORT=none \
  bash scripts/run/archive.sh status --storage --json)"
case "$got" in
  *"-p fm-processor"*"exec -T fm /ros_entrypoint.sh bash -c"*'exec ros2 run fm_data_archive archive_cli "$@"'*"archive-status /data/private archive status --state-dir /data/private archive --json")
    pass "archive storage status reads the configured ledger in the processor runtime" ;;
  *) fail "archive storage status used the wrong runtime or state directory: $got" ;;
esac
archive_rc=0
FM_TEST_DOCKER_EXIT=7 FM_PROCESSOR_RUNTIME=container \
  FM_PROCESSOR_ENV_FILE="$WORK/fm-processor.env" \
  FM_ARCHIVE_UPLOADER_ENVFILE="$WORK/fm-processor.env" FM_TRANSPORT=none \
  bash scripts/run/archive.sh status --storage --json >/dev/null || archive_rc=$?
if [[ "$archive_rc" == 7 ]]; then
  pass "archive storage status preserves runtime failure"
else
  fail "archive storage status hid runtime failure: $archive_rc"
fi
unset -f docker

printf 'ROS_DOMAIN_ID=7\nFM_TRANSPORT=none\nIGNORED=value\n' >"$WORK/fm-processor.env"
got="$(bash -s -- "$WORK/fm-processor.env" <<'SH'
eval "$(sed '/^main /d' scripts/internal/catalogue.sh)"
recorder_environment "$1"
source scripts/env/comms.sh >&2
printf '%s:%s:%s' "$ROS_DOMAIN_ID" "$FM_COMMS_PROFILE" "${IGNORED:-unset}"
SH
)"
if [[ "$got" == "7:none:unset" ]]; then
  pass "catalogue transport matches the recorder domain without importing unrelated settings"
else
  fail "catalogue transport differs from the recorder environment: $got"
fi

echo "== the verb itself routes, not only the library =="
# The checks above exercise the library. This one exercises dataset.sh, so a
# regression that stops calling the wrapper is caught where it happens.
# The marker path is exported INSIDE the substitution: a `VAR=x got=$(...)`
# prefix sets a second variable, it does not reach the command.
got="$(FM_PROCESSOR_ENV_FILE="$WORK/absent.env" FM_SELFTEST=1 \
  ./scripts/run/dataset.sh process 2>/dev/null | tail -1)"
case "$got" in
  *"runtime=stack"*) pass "a host with no processor role runs the verb on the stack" ;;
  *) fail "the verb did not fall back to the stack: $got" ;;
esac

got="$(FM_PROCESSOR_ENV_FILE="$WORK/fm-processor.env" FM_SELFTEST=1 \
  ./scripts/run/dataset.sh process 2>/dev/null | tail -1)"
case "$got" in
  *"runtime=processor"*) pass "a host with the processor role runs the verb there" ;;
  *) fail "the verb ignored the processor role: $got" ;;
esac

# Every engine call must go through the wrapper. A call site left on
# fm_stack_exec reintroduces the bug in one verb while the others are fixed.
before="$fails"
# The wrapper's own fallback line is the one legitimate use; match it literally.
# shellcheck disable=SC2016  # deliberate: this is a pattern, not an expansion
while IFS= read -r line; do
  fail "an engine call bypasses dataset_exec: $line"
done < <(grep -n 'fm_stack_exec' scripts/run/dataset.sh \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vF 'fm_stack_exec "$overlay" "$@"')
[[ "$fails" == "$before" ]] && pass "no engine call bypasses the wrapper"

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
uv run --no-project python - <<'PY' || exit 1
import json
import os
import subprocess
import runpy

client = runpy.run_path("scripts/internal/catalogue-client.py")
match = client["correlated_result"]
assert match({"target_id": "pack-1", "request_id": "old"}, "new", detail_target="pack-1") is None
assert match({"target_id": "pack-2", "request_id": "new"}, "new", detail_target="pack-1") is None
assert match({"target_id": "pack-1", "request_id": "new", "evidence": "fresh"}, "new",
             detail_target="pack-1")["evidence"] == "fresh"
assert match({"current": {"request_id": "new", "target_id": "pack-1"}}, "new",
             inspect_release=True)["state"] == "running"
assert match({"queue": [{"request_id": "new", "target_id": "pack-1"}]}, "new",
             inspect_release=True)["state"] == "queued"

def preview(domain, *args):
    result = subprocess.run(
        ["uv", "run", "--no-project", "python", "scripts/internal/catalogue-client.py",
         domain, *args, "--dry-run"], capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)

capture_cli = subprocess.run(
    ["bash", "scripts/run/episode.sh", "catalog", "show", "--episode-id", "take-1",
     "--dry-run", "--json"], env={**os.environ, "FM_TRANSPORT": "none"},
    capture_output=True, text=True, check=True,
)
assert json.loads(capture_cli.stdout)["request"]["episode_id"] == "take-1"
assert "comms:" not in capture_cli.stdout

capture = preview("capture", "show", "--episode-id", "take-1")
assert capture["command_topic"] == "/capture/select"
assert capture["result_topic"] == "/capture/detail"
assert capture["request"]["episode_id"] == "take-1"
assert capture["request"]["request_id"]
assert preview("capture", "list")["result_topic"] == "/capture/index"
assert preview("capture", "status")["result_topic"] == "/fm_data_record/recorder_status"
start = preview("capture", "start", "--episode-id", "take-1", "--task-id", "sort",
                "--instruction", "Sort the operator's cups", "--operator-id", "person")
assert start["command_topic"] == "/capture/command"
assert start["result_topic"] == "/capture/result"
assert start["request"]["options"]["instruction"] == "Sort the operator's cups"
assert "operator_success" not in start["request"]["options"]
assert preview("capture", "stop", "--episode-id", "take-1")["request"]["options"] == {}
for outcome, expected in (("success", True), ("failed", False), ("unlabeled", None)):
    assert preview("capture", "submit", "--episode-id", "take-1", "--outcome", outcome)["request"]["options"] == {"operator_success": expected}
assert preview("capture", "discard", "--episode-id", "take-1", "--confirm")["request"]["options"] == {"confirmed": True}
lookup = preview("capture", "result", "--request-id", "capture-request")
assert lookup["command_topic"] is None and lookup["request"] is None
assert lookup["result_topic"] == "/capture/result"
assert preview("capture", "sensors", "--disabled-device", "glove_left")["request"]["options"] == {"disabled_devices": ["glove_left"]}
for arguments in (("submit", "--episode-id", "take-1"),
                  ("discard", "--episode-id", "take-1"),
                  ("stop", "--episode-id", "take-1", "--outcome", "success"),
                  ("start", "--episode-id", "take-1")):
    refused = subprocess.run(["uv", "run", "--no-project", "python",
                              "scripts/internal/catalogue-client.py", "capture",
                              *arguments, "--dry-run"], capture_output=True, text=True)
    assert refused.returncode == 2, (arguments, refused.stdout, refused.stderr)
assert match({"session": "take-1", "request_id": "old"}, "new",
             detail_target="take-1", detail_key="session") is None
assert match({"session": "take-2", "request_id": "new"}, "new",
             detail_target="take-1", detail_key="session") is None
assert match({"session": "take-1", "request_id": "new", "error": "not found"}, "new",
             detail_target="take-1", detail_key="session")["error"] == "not found"

bundle_sha = "a" * 64
media = preview("review-media", "fetch", "--episode-id", "take-1",
                 "--annotation-bundle-sha256", bundle_sha, "--mode", "range",
                 "--start-frame", "0", "--end-frame", "2")
assert media["command_topic"] == "/process/review_media/select"
assert media["result_topics"] == ["/process/review_media/meta", "/process/review_media/image"]
assert media["request"]["start_frame"] == 0 and media["request"]["end_frame"] == 2
showcase = preview("showcase", "fetch", "--episode-id", "take-1")
assert showcase["command_topic"] == "/process/showcase/select"
assert showcase["result_topics"] == ["/process/showcase/meta", "/process/showcase/chunk"]
viewer = preview("viewer", "rows", "first-motive/demo", "--offset", "0", "--length", "20")
assert viewer["request"]["endpoint"] == "rows"
assert viewer["request"]["query"] == {"dataset": "first-motive/demo", "config": "default",
                                        "split": "train", "offset": "0", "length": "20"}
pin = preview("review-pin", "acquire", "--target-id", "take-1/annotation/" + bundle_sha,
              "--pin-id", "review-1")
assert pin["command_topic"] == "/archive/review_pin/begin"
assert pin["result_topic"] == "/archive/storage/status"
assert pin["request"]["target_id"].endswith("/annotation/" + bundle_sha)
pin_request = pin["request"]
pin_status = {"operation": {"request_id": pin_request["request_id"],
                             "target_id": pin_request["target_id"], "pin_id": "review-1",
                             "verb": "begin_review_pin", "state": "active", "ok": True,
                             "pin_durable": True, "lock_state": "shared"},
              "last_update": {"ok": False}}
assert client["_review_pin_success"](pin_status, pin_request, "begin") is True
qa_state = {"command_version": 1, "policy": {},
            "last_update": {"request_id": "qa-new", "ok": False},
            "results": [{"request_id": "qa-old", "ok": False},
                        {"request_id": "qa-new", "ok": True}]}
assert client["_qa_receipt"](qa_state, "qa-new")["ok"] is False
qa_state["last_update"] = {"request_id": "qa-other", "ok": True}
assert client["_qa_receipt"](qa_state, "qa-new")["ok"] is True
assert preview("qa", "show")["result_topic"] == "/episode_qa/policy"
assert preview("qa", "result", "--request-id", "qa-1")["request"]["request_id"] == "qa-1"
with __import__("tempfile").NamedTemporaryFile(mode="w", suffix=".json") as policy_file:
    json.dump({"min_duration_s": 1}, policy_file)
    policy_file.flush()
    qa_set = preview("qa", "set", "--inputfile", policy_file.name, "--confirm")
assert qa_set["command_topic"] == "/episode_qa/policy/set"
assert qa_set["request"]["schema_version"] == 1
assert qa_set["request"]["policy"]["min_duration_s"] == 1
for argv in (
    ["bash", "scripts/run/process.sh", "review-media", "take-1",
     "--annotation-bundle-sha256", bundle_sha, "--mode", "frame",
     "--topic-frame-index", "0", "--dry-run"],
    ["bash", "scripts/run/process.sh", "showcase", "take-1", "--dry-run"],
):
    shell = subprocess.run(argv, env={**os.environ, "FM_TRANSPORT": "none"},
                           capture_output=True, text=True, check=True)
    assert json.loads(shell.stdout)["request"]["episode_id"] == "take-1"
release_shell = subprocess.run(
    ["bash", "scripts/run/release.sh", "viewer", "rows", "first-motive/demo", "--dry-run"],
    env={**os.environ, "FM_TRANSPORT": "none"}, capture_output=True, text=True, check=True,
)
assert json.loads(release_shell.stdout)["request"]["endpoint"] == "rows"
qa_shell = subprocess.run(
    ["bash", "scripts/run/episode.sh", "qa", "show", "--dry-run"],
    env={**os.environ, "FM_TRANSPORT": "none"}, capture_output=True, text=True, check=True,
)
assert json.loads(qa_shell.stdout)["result_topic"] == "/episode_qa/policy"

project = preview("project", "create", "--name", "Cup \"sort\"", "--description", "Two\nlines")
assert project["command_topic"] == "/projects/command"
assert project["request"]["name"] == 'Cup "sort"'
assert project["request"]["description"] == "Two\nlines"
assert project["request"]["request_id"]
dataset = preview("dataset", "move", "--dataset-id", "source", "--destination", "training", "--episode", "take-1")
assert dataset["command_topic"] == "/process/datasets/move"
assert dataset["result_topic"] == "/process/datasets/status"
assert dataset["request"]["options"] == {"destination_dataset_id": "training", "episode_ids": ["take-1"]}
assert preview("dataset", "list")["request"] is None
detail = preview("dataset", "show", "--dataset-id", "training")
assert detail["command_topic"] == "/process/datasets/select"
assert detail["result_topic"] == "/process/datasets/detail"
assert detail["request"]["operation"] == "select"
assert detail["request"]["dataset_id"] == "training"
assert match({"dataset_id": "training", "request_id": "old"}, "new",
             detail_target="training", detail_key="dataset_id") is None
assert match({"dataset_id": "other", "request_id": "new"}, "new",
             detail_target="training", detail_key="dataset_id") is None
assert match({"dataset_id": "training", "request_id": "new", "episode_ids": ["take-1"]}, "new",
             detail_target="training", detail_key="dataset_id")["episode_ids"] == ["take-1"]
assert match({"refusal": {"request_id": "new", "issue_code": "dataset_not_found"}}, "new",
             detail_target="missing", detail_key="dataset_id")["issue_code"] == "dataset_not_found"
assert match({"refusal": {"request_id": "old", "issue_code": "dataset_not_found"}}, "new",
             detail_target="missing", detail_key="dataset_id") is None
profile = preview("profile", "inspect", "--profile-id", "pick-place", "--profile-version", "v1")
assert profile["command_topic"] == "/process/task_profiles/request"
assert profile["result_topic"] == "/process/task_profiles/result"
assert profile["request"]["operation"] == "inspect_profile"
assert profile["request"]["profile_id"] == "pick-place"
profile_save = subprocess.run(
    ["uv", "run", "--no-project", "python", "scripts/internal/catalogue-client.py",
     "profile", "save", "--request-stdin", "--dry-run"],
    input=json.dumps({"profile": {"instruction": "Pick \"this\"\nthen place"}, "request_id": "old"}),
    capture_output=True, text=True, check=True,
)
saved = json.loads(profile_save.stdout)["request"]
assert saved["profile"]["instruction"] == 'Pick "this"\nthen place'
assert saved["request_id"] != "old"
assert saved["operation"] == "save_profile"
refused = subprocess.run(
    ["uv", "run", "--no-project", "python", "scripts/internal/catalogue-client.py",
     "profile", "decide", "--dry-run"], capture_output=True, text=True,
)
assert refused.returncode == 2 and "requires --confirm" in refused.stderr
release = preview("release", "export", "candidate-1", "--episode", "take-1", "--episode", "take-2")
assert release["command_topic"] == "/release/export"
assert release["result_topic"] == "/release/status"
assert release["request"]["options"] == {"episode_ids": ["take-1", "take-2"]}
assert preview("release", "result", "--request-id", "original")["request"] is None
assert preview("release", "verify", "pack-1", "--strict")["request"]["options"] == {"strict": True}
approval = {"candidate_inventory_sha256": "a" * 64, "review": {"reference": "human-review"}}
approved = subprocess.run(
    ["uv", "run", "--no-project", "python", "scripts/internal/catalogue-client.py",
     "release", "approve", "candidate-1", "--request-stdin", "--confirm", "--dry-run"],
    input=json.dumps(approval), capture_output=True, text=True, check=True,
)
assert json.loads(approved.stdout)["request"]["options"] == {"approval": approval}
refused = subprocess.run(
    ["uv", "run", "--no-project", "python", "scripts/internal/catalogue-client.py",
     "release", "publish", "pack-1", "--confirmation-identity", "publish-1", "--dry-run"],
    capture_output=True, text=True,
)
assert refused.returncode == 2 and "human --confirm" in refused.stderr
prepared = preview("provision", "start", "--model", "qwen3.5-9b")
assert prepared["command_topic"] == "/process/provision"
assert prepared["result_topic"] == "/process/status"
assert prepared["request"]["model"] == "qwen3.5-9b"
assert prepared["request"]["request_id"]
assert preview("provision", "result", "--request-id", "prepare-1")["request"] is None
import runpy
match = runpy.run_path("scripts/internal/catalogue-client.py")["correlated_result"]
preparation = {"provision": {"state": "running", "request_id": "prepare-1"}}
assert match(preparation, "other", provision=True) is None
assert match(preparation, "prepare-1", provision=True)["state"] == "running"
assert match({"request_id": "prepare-1", "request_error": "busy"}, "prepare-1", provision=True)["ok"] is False
assert match({"provision": {"state": "failed", "request_id": "prepare-1"}}, "prepare-1", provision=True)["ok"] is False

PY
echo "dataset runtime: all checks passed"
