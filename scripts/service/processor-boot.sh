#!/usr/bin/env bash
# processor-boot.sh — non-interactive bring-up of the dataset-processing appliance,
# for the fm-processor.service systemd unit (installed by install-processor-service.sh).
#
# A systemd unit reads NONE of ~/.bashrc, so this sources ROS + the colcon overlay +
# the DDS LAN profile explicitly, then execs the processing launch. It is the boot-time
# equivalent of the three `source` lines setup-processor.sh prints for an interactive
# terminal, so the processor host serves /process/* itself, including bounded
# bundle-bound review media, and the desktop app's Process surface drives it.
# Runnable by hand too: `bash scripts/service/processor-boot.sh`.
#
# Knobs (set in /etc/fm-processor.env, the unit's EnvironmentFile):
#   FM_PROCESSOR_RECORDINGS_DIR=<dir>  recorder output dir with sessions.jsonl + bags
#   FM_PROCESSOR_OUTPUT_DIR=<dir>      per-episode processing output root
#   FM_PROCESSOR_CONFIG=<file>         processing profile JSON (empty = engine default)
#   FM_PROCESSOR_ENGINE_PYTHON=<exe>   interpreter for the dataset_process subprocess
#                                      (default: the workspace .engine-venv when present)
#   FM_PROCESSOR_ANNOTATIONS_DIR=<dir> per-episode annotation bundle root
#   FM_PROCESSOR_LEROBOT_IMPORTS_DIR=<dir> receipt-bound LeRobot Process imports
#   FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=<dir> durable attempt evidence root
#   FM_PROCESSOR_ANNOTATION_REVIEWS_DIR=<dir> durable human review receipts
#   FM_PROCESSOR_ANNOTATION_CORRECTIONS_DIR=<dir> durable corrected outputs
#   FM_PROCESSOR_ANNOTATION_LEARNING_DIR=<dir> durable learning records
#   FM_PROCESSOR_OPERATOR_EVIDENCE_DIR=<dir> selected operator evidence receipts
#   FM_PROCESSOR_AWS_INFERENCE_SCRIPT=<file> AWS annotation adapter (optional)
#   FM_PROCESSOR_ANNOTATE_GIT_COMMIT=<40-hex> explicit fm-data source commit (optional;
#                                      otherwise resolved from src/fm_data at boot)
#   FM_AWS_INFERENCE_SERVICE_MODE=1    opt in to the persistent Ohio worker service
#   FM_AWS_INFERENCE_REGION=us-east-2  Ohio region (service mode only)
#   FM_AWS_PROFILE=<identity-profile> Roles Anywhere profile (service mode only)
#   FM_AWS_INFERENCE_BUCKET=<bucket>   reviewed Ohio inference bucket (required)
#   FM_AWS_INFERENCE_READINESS_DIR=<dir> fresh qwen2.5.json/qwen3.5.json receipts
#   FM_AWS_SERVICE_TIMEOUT_SECONDS=7200 bounded Ohio service receipt wait
#   FM_PROCESSOR_RELEASE_ROOT=<dir>     candidates, Packs, jobs, and deliveries
#   FM_PROCESSOR_RELEASE_DATASET_EXPORTER=<exe> pinned real-dataset exporter
#   FM_PROCESSOR_RELEASE_PYTHON=<exe>   pinned Python for Pack and strict loaders
#   FM_PROCESSOR_RELEASE_PACK_CONFIG=<file> reviewed Dataset Release Pack v2 config
#   FM_PROCESSOR_RELEASE_HUGGINGFACE_CLI=<exe> pinned hf executable (optional)
#   FM_PROCESSOR_RELEASE_HUGGINGFACE_REPOSITORY=<owner/name> approved private dataset
#   FM_LAN_IP=<ip>                     pin the DDS LAN interface (else auto-detected)
#
# No `set -e`: this is a long-lived bring-up wrapper, and a non-matching grep in the
# wait loop must not abort it. The launch's exit becomes the service's exit, with one
# correction: `ros2 launch` returns 0 even when every node it started has died, so a
# supervisor that dies on a missing dependency looked like a clean shutdown and
# systemd's Restart=on-failure never fired (#134). A long-lived supervisor that
# returns at all has failed, unless it was asked to stop.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RECORDINGS_DIR="${FM_PROCESSOR_RECORDINGS_DIR:-~/recordings}"
OUTPUT_DIR="${FM_PROCESSOR_OUTPUT_DIR:-~/processed}"
CONFIG="${FM_PROCESSOR_CONFIG:-}"
ANNOTATIONS_DIR="${FM_PROCESSOR_ANNOTATIONS_DIR:-}"
LEROBOT_IMPORTS_DIR="${FM_PROCESSOR_LEROBOT_IMPORTS_DIR:-~/.cache/fm-archive/lerobot-staged}"
ANNOTATION_ATTEMPTS_DIR="${FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR:-~/fm-data-runs/annotation-attempts}"
ANNOTATION_REVIEWS_DIR="${FM_PROCESSOR_ANNOTATION_REVIEWS_DIR:-~/fm-data-runs/annotation-reviews}"
ANNOTATION_CORRECTIONS_DIR="${FM_PROCESSOR_ANNOTATION_CORRECTIONS_DIR:-~/fm-data-runs/annotation-corrections}"
ANNOTATION_LEARNING_DIR="${FM_PROCESSOR_ANNOTATION_LEARNING_DIR:-~/fm-data-runs/annotation-learning}"
OPERATOR_EVIDENCE_DIR="${FM_PROCESSOR_OPERATOR_EVIDENCE_DIR:-}"
ANNOTATION_ADJUDICATIONS_DIR="${FM_PROCESSOR_ANNOTATION_ADJUDICATIONS_DIR:-~/fm-data-runs/annotation-adjudications}"
ANNOTATION_REVOCATIONS_DIR="${FM_PROCESSOR_ANNOTATION_REVOCATIONS_DIR:-~/fm-data-runs/annotation-revocations}"
ANNOTATION_LEARNING_SNAPSHOTS_DIR="${FM_PROCESSOR_ANNOTATION_LEARNING_SNAPSHOTS_DIR:-~/fm-data-runs/annotation-learning-snapshots}"
ANNOTATION_IMPROVEMENT_RUNS_DIR="${FM_PROCESSOR_ANNOTATION_IMPROVEMENT_RUNS_DIR:-~/fm-data-runs/annotation-improvement-runs}"
AWS_INFERENCE_SCRIPT="${FM_PROCESSOR_AWS_INFERENCE_SCRIPT:-}"
ANNOTATE_GIT_COMMIT="${FM_PROCESSOR_ANNOTATE_GIT_COMMIT:-}"
# The managed service env uses a workspace-relative adapter path so the same
# config works natively and from /ws in the Humble container.
if [ -n "$AWS_INFERENCE_SCRIPT" ] && [[ "$AWS_INFERENCE_SCRIPT" != /* ]]; then
  AWS_INFERENCE_SCRIPT="$ROOT/$AWS_INFERENCE_SCRIPT"
fi
RELEASE_ROOT="${FM_PROCESSOR_RELEASE_ROOT:-~/dataset-releases}"
RELEASE_DATASET_EXPORTER="${FM_PROCESSOR_RELEASE_DATASET_EXPORTER:-}"
RELEASE_PYTHON="${FM_PROCESSOR_RELEASE_PYTHON:-}"
RELEASE_PACK_CONFIG="${FM_PROCESSOR_RELEASE_PACK_CONFIG:-}"
RELEASE_HUGGINGFACE_CLI="${FM_PROCESSOR_RELEASE_HUGGINGFACE_CLI:-}"
RELEASE_HUGGINGFACE_REPOSITORY="${FM_PROCESSOR_RELEASE_HUGGINGFACE_REPOSITORY:-}"
# The engine's dedicated venv isolates its numpy pin from other tenants of the
# host (setup-processor.sh creates it); default to it whenever it exists.
ENGINE_PYTHON="${FM_PROCESSOR_ENGINE_PYTHON:-}"
if [ -z "$ENGINE_PYTHON" ] && [ -x "$ROOT/.engine-venv/bin/python" ]; then
  ENGINE_PYTHON="$ROOT/.engine-venv/bin/python"
fi

# Annotation evidence must identify the actual fm-data source. Resolve the
# nested checkout used by this workspace (the same path is mounted at /ws in
# the Humble container); an explicit value is accepted only when it is a full
# immutable Git object id. A missing source is tolerated for the offline/local
# lane, but a configured AWS adapter is refused rather than producing an
# untraceable cloud bundle.
_is_full_commit() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] &&
    [ "$1" != 0000000000000000000000000000000000000000 ]
}
_resolve_data_commit() {
  local data_root="$ROOT/src/fm_data" commit
  [ -e "$data_root/.git" ] || return 1
  commit="$(git -C "$data_root" rev-parse --verify HEAD 2>/dev/null)" || return 1
  _is_full_commit "$commit" || return 1
  printf '%s\n' "$commit"
}
_DISCOVERED_DATA_COMMIT=""
if [ -e "$ROOT/src/fm_data/.git" ]; then
  _DISCOVERED_DATA_COMMIT="$(_resolve_data_commit 2>/dev/null || true)"
fi
_DATA_SOURCE_DIRTY=0
if [ -n "$_DISCOVERED_DATA_COMMIT" ] &&
   ! git -C "$ROOT/src/fm_data" diff --quiet HEAD -- >/dev/null 2>&1; then
  _DATA_SOURCE_DIRTY=1
  # Do not stamp HEAD on the offline/local lane either. Tracked edits are not
  # part of that commit; untracked runtime outputs are intentionally ignored.
  _DISCOVERED_DATA_COMMIT=""
fi
if [ "$_DATA_SOURCE_DIRTY" = 1 ] &&
   { [ -n "$ANNOTATE_GIT_COMMIT" ] || [ -n "$AWS_INFERENCE_SCRIPT" ] ||
     [ "${FM_AWS_INFERENCE_SERVICE_MODE:-0}" = 1 ]; }; then
  echo "ERROR: tracked changes in $ROOT/src/fm_data prevent a trusted annotation source identity" >&2
  echo "       Commit or stash tracked fm-data changes before the AWS annotation launch." >&2
  exit 1
fi
if [ -n "$ANNOTATE_GIT_COMMIT" ] && ! _is_full_commit "$ANNOTATE_GIT_COMMIT"; then
  echo "ERROR: FM_PROCESSOR_ANNOTATE_GIT_COMMIT must be a full 40-character lowercase Git commit" >&2
  exit 1
fi
if [ -n "$ANNOTATE_GIT_COMMIT" ] && [ -n "$_DISCOVERED_DATA_COMMIT" ] &&
   [ "$ANNOTATE_GIT_COMMIT" != "$_DISCOVERED_DATA_COMMIT" ]; then
  echo "ERROR: FM_PROCESSOR_ANNOTATE_GIT_COMMIT does not match the local fm-data checkout" >&2
  echo "       expected $_DISCOVERED_DATA_COMMIT" >&2
  exit 1
fi
if [ -z "$ANNOTATE_GIT_COMMIT" ]; then
  if [ -n "$_DISCOVERED_DATA_COMMIT" ]; then
    ANNOTATE_GIT_COMMIT="$_DISCOVERED_DATA_COMMIT"
  else
    if [ -n "$AWS_INFERENCE_SCRIPT" ] || [ "${FM_AWS_INFERENCE_SERVICE_MODE:-0}" = 1 ]; then
      echo "ERROR: AWS annotation requires an fm-data source commit at $ROOT/src/fm_data" >&2
      echo "       Check out the processor's nested fm-data repository or set a reviewed" >&2
      echo "       full 40-character FM_PROCESSOR_ANNOTATE_GIT_COMMIT." >&2
      exit 1
    fi
    echo "WARNING: fm-data source commit unavailable; cloud annotation is disabled" >&2
  fi
fi

# At boot the LAN interface may not be up yet, so the foxglove profile's dds-lan.sh
# would find no IP to pin and fall back to default DDS. Wait (bounded, ~30s) for a
# private-LAN address before sourcing the profile. FM_LAN_IP short-circuits the wait
# (dds-lan.sh honours it directly).
if [ -z "${FM_LAN_IP:-}" ]; then
  for _i in $(seq 1 30); do
    if hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -Eq '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; then
      break
    fi
    sleep 1
  done
fi

# ROS setup.bash references unset AMENT_*/COLCON_* vars, which `set -u` treats as an
# error — drop nounset just around the sources, then restore it (recorder-boot.sh pattern).
set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# The comms profile — foxglove (dds-lan.sh) unless FM_COMMS or .fm_ros2.json says otherwise.
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh"
set -u

# ros2 launch rejects an empty-valued argument ("malformed launch argument
# 'config:='"), so optional overrides are appended only when actually set —
# absent, the launch file's empty defaults hold. Hit live on the first
# processor host, 2026-07-22.
LAUNCH_ARGS=(recordings_dir:="$RECORDINGS_DIR" output_dir:="$OUTPUT_DIR")
LAUNCH_ARGS+=(lerobot_imports_dir:="$LEROBOT_IMPORTS_DIR")
LAUNCH_ARGS+=(annotation_attempts_dir:="$ANNOTATION_ATTEMPTS_DIR")
LAUNCH_ARGS+=(annotation_reviews_dir:="$ANNOTATION_REVIEWS_DIR")
LAUNCH_ARGS+=(annotation_corrections_dir:="$ANNOTATION_CORRECTIONS_DIR")
LAUNCH_ARGS+=(annotation_learning_dir:="$ANNOTATION_LEARNING_DIR")
if [ -n "$OPERATOR_EVIDENCE_DIR" ]; then
  LAUNCH_ARGS+=(operator_evidence_dir:="$OPERATOR_EVIDENCE_DIR")
fi
LAUNCH_ARGS+=(annotation_adjudications_dir:="$ANNOTATION_ADJUDICATIONS_DIR")
LAUNCH_ARGS+=(annotation_revocations_dir:="$ANNOTATION_REVOCATIONS_DIR")
LAUNCH_ARGS+=(annotation_learning_snapshots_dir:="$ANNOTATION_LEARNING_SNAPSHOTS_DIR")
LAUNCH_ARGS+=(annotation_improvement_runs_dir:="$ANNOTATION_IMPROVEMENT_RUNS_DIR")
LAUNCH_ARGS+=(release_root:="$RELEASE_ROOT")
if [ -n "$CONFIG" ]; then
  LAUNCH_ARGS+=(config:="$CONFIG")
fi
if [ -n "$ENGINE_PYTHON" ]; then
  LAUNCH_ARGS+=(engine_python:="$ENGINE_PYTHON")
fi
if [ -n "$ANNOTATIONS_DIR" ]; then
  LAUNCH_ARGS+=(annotations_dir:="$ANNOTATIONS_DIR")
fi
if [ -n "$RELEASE_DATASET_EXPORTER" ]; then
  LAUNCH_ARGS+=(release_dataset_exporter:="$RELEASE_DATASET_EXPORTER")
fi
if [ -n "$RELEASE_PYTHON" ]; then
  LAUNCH_ARGS+=(release_python:="$RELEASE_PYTHON")
fi
if [ -n "$RELEASE_PACK_CONFIG" ]; then
  LAUNCH_ARGS+=(release_pack_config:="$RELEASE_PACK_CONFIG")
fi
if [ -n "$RELEASE_HUGGINGFACE_CLI" ]; then
  LAUNCH_ARGS+=(release_huggingface_cli:="$RELEASE_HUGGINGFACE_CLI")
fi
if [ -n "$RELEASE_HUGGINGFACE_REPOSITORY" ]; then
  LAUNCH_ARGS+=(release_huggingface_repository:="$RELEASE_HUGGINGFACE_REPOSITORY")
fi
# The app-triggerable real-model provisioning (/process/provision) runs this
# workspace's own setup-qwen.sh; passing the path here keeps the supervisor
# free of workspace-layout knowledge.
LAUNCH_ARGS+=(provision_script:="$ROOT/scripts/install/setup-qwen.sh")
# App-approved real annotation stages through the annotation package's own
# staging script in this workspace's source tree.
LAUNCH_ARGS+=(stage_script:="$ROOT/src/fm_data/fm_data_annotate/scripts/stage_qwen_run.sh")
if [ -n "$ANNOTATE_GIT_COMMIT" ]; then
  LAUNCH_ARGS+=(annotate_git_commit:="$ANNOTATE_GIT_COMMIT")
fi
if [ -n "$AWS_INFERENCE_SCRIPT" ]; then
  LAUNCH_ARGS+=(aws_inference_script:="$AWS_INFERENCE_SCRIPT")
fi
# Stopped on purpose, or failed? A stop reaches this wrapper as a signal on the
# native runtime, and as a TERM on the launch itself in the container runtime,
# where the unit's ExecStop kills it by name from outside (container-exec.sh).
# Both are clean; anything else is a failure systemd should act on.
stopping=0
trap 'stopping=1; [ -n "${launch_pid:-}" ] && kill -TERM "$launch_pid" 2>/dev/null' TERM INT

ros2 launch fm_data process_session.launch.py "${LAUNCH_ARGS[@]}" &
launch_pid=$!
wait "$launch_pid"
status=$?
# The trap interrupts `wait`, which then returns 128+signal rather than the
# launch's own status — wait again, now that the launch is tearing down.
if [ "$stopping" = 1 ]; then
  wait "$launch_pid" 2>/dev/null
  exit 0
fi
# 143 = SIGTERM, 130 = SIGINT: the launch was killed from outside, which is what
# a `systemctl stop` looks like under the container runtime.
if [ "$status" = 143 ] || [ "$status" = 130 ]; then
  exit 0
fi
if [ "$status" = 0 ]; then
  echo "ERROR: the processing launch returned with its nodes stopped. ros2 launch exits" >&2
  echo "       0 even when every node has died, so this reports the failure instead —" >&2
  echo "       the service must not come back as 'inactive (dead), status=0/SUCCESS'." >&2
  echo "       The node that died first is in the log above (journalctl -u fm-processor)." >&2
  status=1
fi
exit "$status"
