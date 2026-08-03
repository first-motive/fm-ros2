#!/usr/bin/env bash
# processor-boot.sh — non-interactive bring-up of the dataset-processing appliance,
# for the fm-processor.service systemd unit (installed by install-processor-service.sh).
#
# A systemd unit reads NONE of ~/.bashrc, so this sources ROS + the colcon overlay +
# the DDS LAN profile explicitly, then execs the processing launch. It is the boot-time
# equivalent of the three `source` lines setup-processor.sh prints for an interactive
# terminal, so the processor host serves /process/* itself, including bounded
# bundle-bound review media, and the desktop app's Process surface drives it.
# Runnable by hand too: `bash scripts/run/processor-boot.sh`.
#
# Knobs (set in /etc/fm-processor.env, the unit's EnvironmentFile):
#   FM_PROCESSOR_RECORDINGS_DIR=<dir>  recorder output dir with sessions.jsonl + bags
#   FM_PROCESSOR_OUTPUT_DIR=<dir>      per-episode processing output root
#   FM_PROCESSOR_CONFIG=<file>         processing profile JSON (empty = engine default)
#   FM_PROCESSOR_ENGINE_PYTHON=<exe>   interpreter for the dataset_process subprocess
#                                      (default: the workspace .engine-venv when present)
#   FM_PROCESSOR_ANNOTATIONS_DIR=<dir> per-episode annotation bundle root
#   FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=<dir> durable attempt evidence root
#   FM_PROCESSOR_ANNOTATION_REVIEWS_DIR=<dir> durable human review receipts
#   FM_PROCESSOR_ANNOTATION_CORRECTIONS_DIR=<dir> durable corrected outputs
#   FM_PROCESSOR_ANNOTATION_LEARNING_DIR=<dir> durable learning records
#   FM_PROCESSOR_RELEASE_ROOT=<dir>     candidates, Packs, jobs, and deliveries
#   FM_PROCESSOR_RELEASE_DATASET_EXPORTER=<exe> pinned real-dataset exporter
#   FM_PROCESSOR_RELEASE_PYTHON=<exe>   pinned Python for Pack and strict loaders
#   FM_PROCESSOR_RELEASE_PACK_CONFIG=<file> reviewed Dataset Release Pack v2 config
#   FM_PROCESSOR_RELEASE_HUGGINGFACE_CLI=<exe> pinned hf executable (optional)
#   FM_PROCESSOR_RELEASE_HUGGINGFACE_REPOSITORY=<owner/name> approved private dataset
#   FM_LAN_IP=<ip>                     pin the DDS LAN interface (else auto-detected)
#
# No `set -e`: this is a long-lived bring-up wrapper, and a non-matching grep in the
# wait loop must not abort it. It ends in `exec ros2 launch`, so the launch's exit is
# the service's exit (systemd restarts it per the unit's Restart= policy).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RECORDINGS_DIR="${FM_PROCESSOR_RECORDINGS_DIR:-~/recordings}"
OUTPUT_DIR="${FM_PROCESSOR_OUTPUT_DIR:-~/processed}"
CONFIG="${FM_PROCESSOR_CONFIG:-}"
ANNOTATIONS_DIR="${FM_PROCESSOR_ANNOTATIONS_DIR:-}"
ANNOTATION_ATTEMPTS_DIR="${FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR:-~/fm-data-runs/annotation-attempts}"
ANNOTATION_REVIEWS_DIR="${FM_PROCESSOR_ANNOTATION_REVIEWS_DIR:-~/fm-data-runs/annotation-reviews}"
ANNOTATION_CORRECTIONS_DIR="${FM_PROCESSOR_ANNOTATION_CORRECTIONS_DIR:-~/fm-data-runs/annotation-corrections}"
ANNOTATION_LEARNING_DIR="${FM_PROCESSOR_ANNOTATION_LEARNING_DIR:-~/fm-data-runs/annotation-learning}"
ANNOTATION_ADJUDICATIONS_DIR="${FM_PROCESSOR_ANNOTATION_ADJUDICATIONS_DIR:-~/fm-data-runs/annotation-adjudications}"
ANNOTATION_REVOCATIONS_DIR="${FM_PROCESSOR_ANNOTATION_REVOCATIONS_DIR:-~/fm-data-runs/annotation-revocations}"
ANNOTATION_LEARNING_SNAPSHOTS_DIR="${FM_PROCESSOR_ANNOTATION_LEARNING_SNAPSHOTS_DIR:-~/fm-data-runs/annotation-learning-snapshots}"
ANNOTATION_IMPROVEMENT_RUNS_DIR="${FM_PROCESSOR_ANNOTATION_IMPROVEMENT_RUNS_DIR:-~/fm-data-runs/annotation-improvement-runs}"
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
source "$ROOT/scripts/run/comms.sh"
set -u

# ros2 launch rejects an empty-valued argument ("malformed launch argument
# 'config:='"), so optional overrides are appended only when actually set —
# absent, the launch file's empty defaults hold. Hit live on the first
# processor host, 2026-07-22.
LAUNCH_ARGS=(recordings_dir:="$RECORDINGS_DIR" output_dir:="$OUTPUT_DIR")
LAUNCH_ARGS+=(annotation_attempts_dir:="$ANNOTATION_ATTEMPTS_DIR")
LAUNCH_ARGS+=(annotation_reviews_dir:="$ANNOTATION_REVIEWS_DIR")
LAUNCH_ARGS+=(annotation_corrections_dir:="$ANNOTATION_CORRECTIONS_DIR")
LAUNCH_ARGS+=(annotation_learning_dir:="$ANNOTATION_LEARNING_DIR")
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
exec ros2 launch fm_data process_session.launch.py "${LAUNCH_ARGS[@]}"
