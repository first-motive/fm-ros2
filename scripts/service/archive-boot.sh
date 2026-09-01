#!/usr/bin/env bash
# Start the processor-owned archive browser in its own systemd service.
#
# The optional LeRobot source is configured only through the processor's
# environment file: FM_ARCHIVE_LEROBOT_CATALOGUE_FILE names a local closed
# catalogue, and FM_ARCHIVE_LEROBOT_STAGE_ENABLED gates its bounded stage job.
# Desktop cannot provide either value over ROS.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "${FM_ARCHIVE_ENABLED:-false}" in
  true) ;;
  false) echo "archive-boot: disabled in /etc/fm-archive.env"; exit 0 ;;
  *) echo "archive-boot: FM_ARCHIVE_ENABLED must be true or false" >&2; exit 2 ;;
esac

case "${FM_ARCHIVE_STAGE_ENABLED:-false}" in
  true|false) ;;
  *) echo "archive-boot: FM_ARCHIVE_STAGE_ENABLED must be true or false" >&2; exit 2 ;;
esac

case "${FM_ARCHIVE_LEROBOT_STAGE_ENABLED:-false}" in
  true|false) ;;
  *) echo "archive-boot: FM_ARCHIVE_LEROBOT_STAGE_ENABLED must be true or false" >&2; exit 2 ;;
esac

for name in FM_ARCHIVE_MAX_OBJECTS FM_ARCHIVE_MAX_TOTAL_BYTES \
  FM_ARCHIVE_MAX_EPISODES FM_ARCHIVE_RETENTION_DAYS FM_ARCHIVE_MAX_ATTEMPTS; do
  value="${!name:-}"
  if [ -n "$value" ] && ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "archive-boot: $name must be a positive integer" >&2
    exit 2
  fi
done

set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh"
set -u

if ! ros2 pkg prefix fm_data_archive >/dev/null 2>&1; then
  echo "archive-boot: fm_data_archive is not built; run setup-processor.sh" >&2
  exit 1
fi

if [ -z "${BACKBLAZE_B2_PROCARCH_KEY_ID:-}" ] ||
   [ -z "${BACKBLAZE_B2_PROCARCH_APPLICATION_KEY:-}" ]; then
  echo "archive-boot: enabled but the read-only processor-archive B2 credentials are absent" >&2
  exit 1
fi

# The object-store adapter consumes the standard boto3 names. Keep the
# canonical 1Password names in the service environment and export these only
# in the node's process environment; they are never printed or passed as ROS
# arguments. The uploader has its own service and credential pair.
export AWS_ACCESS_KEY_ID="$BACKBLAZE_B2_PROCARCH_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$BACKBLAZE_B2_PROCARCH_APPLICATION_KEY"

ARCHIVE_DATA_ROOT=/data
if [ ! -d "$ARCHIVE_DATA_ROOT" ] || [ ! -w "$ARCHIVE_DATA_ROOT" ]; then
  ARCHIVE_DATA_ROOT="$HOME"
fi
# Where a staged episode is published. It MUST be the same root the processor
# reads: `bag_dir_for_record` resolves a session record by joining its basename
# under this directory, so publishing anywhere else leaves the episode
# undiscoverable. Mirrors archive-uploader-boot.sh, and prefers the processor's
# own configured root the way the service installers do.
RECORDINGS_DIR="${FM_ARCHIVE_RECORDINGS_DIR:-}"
if [ -z "$RECORDINGS_DIR" ]; then
  # Parsed rather than sourced: the processor env file belongs to a systemd unit
  # and may carry anything. Same read as `fm_processor_env`, which is an
  # installer library and is not sourced into a boot path.
  RECORDINGS_DIR="$(sed -n 's/^FM_PROCESSOR_RECORDINGS_DIR=//p' \
    "${FM_PROCESSOR_ENV_FILE:-/etc/fm-processor.env}" 2>/dev/null | tail -1)"
fi
RECORDINGS_DIR="${RECORDINGS_DIR:-$ARCHIVE_DATA_ROOT/recordings}"

CACHE_DIR="${FM_ARCHIVE_CACHE_DIR:-$ARCHIVE_DATA_ROOT/fm-data-runs/archive-cache}"
STAGE_DIR="${FM_ARCHIVE_STAGE_DIR:-$ARCHIVE_DATA_ROOT/fm-data-runs/archive-cache/staged}"
LEROBOT_CATALOGUE_FILE="${FM_ARCHIVE_LEROBOT_CATALOGUE_FILE:-}"
LEROBOT_STAGE_DIR="${FM_ARCHIVE_LEROBOT_STAGE_DIR:-$ARCHIVE_DATA_ROOT/lerobot-staged}"
LEROBOT_CATALOGUE_ARGS=()
if [ -n "$LEROBOT_CATALOGUE_FILE" ]; then
  LEROBOT_CATALOGUE_ARGS=(-p "lerobot_catalogue_file:=$LEROBOT_CATALOGUE_FILE")
fi

echo "archive-boot: starting the local archive browser"
# These are bridge contract topics, shared with Desktop. Keep them fixed so a
# stale env-file override cannot make a healthy reader invisible to the app.
exec ros2 run fm_data_archive archive_browser --ros-args \
  -p cache_dir:="$CACHE_DIR" \
  -p index_topic:=/archive/index \
  -p detail_topic:=/archive/detail \
  -p status_topic:=/archive/status \
  -p select_topic:=/archive/select \
  -p sync_topic:=/archive/sync \
  -p stage_topic:=/archive/stage \
  -p stage_dir:="$STAGE_DIR" \
  -p recordings_dir:="$RECORDINGS_DIR" \
  -p stage_enabled:="${FM_ARCHIVE_STAGE_ENABLED:-false}" \
  ${LEROBOT_CATALOGUE_ARGS[@]+"${LEROBOT_CATALOGUE_ARGS[@]}"} \
  -p lerobot_stage_dir:="$LEROBOT_STAGE_DIR" \
  -p lerobot_stage_enabled:="${FM_ARCHIVE_LEROBOT_STAGE_ENABLED:-false}" \
  -p stage_max_objects:="${FM_ARCHIVE_MAX_OBJECTS:-16}" \
  -p stage_max_total_bytes:="${FM_ARCHIVE_MAX_TOTAL_BYTES:-2147483648}" \
  -p stage_max_episodes:="${FM_ARCHIVE_MAX_EPISODES:-32}" \
  -p stage_retention_days:="${FM_ARCHIVE_RETENTION_DAYS:-30}" \
  -p stage_max_attempts:="${FM_ARCHIVE_MAX_ATTEMPTS:-3}"
