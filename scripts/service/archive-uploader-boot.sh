#!/usr/bin/env bash
# Start the processor-owned Backblaze uploader in its own systemd service.
#
# The uploader is deliberately a sibling of fm-archive.service. It owns the
# write-scoped key, queue, receipts, and retention checks; the archive browser
# owns the read-scoped key and catalogue. A disabled uploader is a successful
# no-op so a fresh appliance can install the unit without starting cloud work.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PYTHONPATH="$ROOT/.ros-runtime${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1

case "${FM_ARCHIVE_UPLOADER_ENABLED:-false}" in
  true) ;;
  false) echo "archive-uploader-boot: disabled in /etc/fm-archive-uploader.env"; exit 0 ;;
  *) echo "archive-uploader-boot: FM_ARCHIVE_UPLOADER_ENABLED must be true or false" >&2; exit 2 ;;
esac

case "${FM_ARCHIVE_UPLOADER_DELETE_ENABLED:-false}" in
  true|false) ;;
  *) echo "archive-uploader-boot: FM_ARCHIVE_UPLOADER_DELETE_ENABLED must be true or false" >&2; exit 2 ;;
esac

_positive_integer() {
  local name="$1" value="${!1:-}"
  if [ -z "$value" ] || ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "archive-uploader-boot: $name must be a positive integer" >&2
    return 1
  fi
}

for name in FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS \
  FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES \
  FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS \
  FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S; do
  _positive_integer "$name" || exit 2
done

if [ "${FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS:-0}" -lt 30 ]; then
  echo "archive-uploader-boot: minimum retention must be at least 30 days" >&2
  exit 2
fi
if [ "${FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES:-0}" -lt 15 ]; then
  echo "archive-uploader-boot: eligibility window must be at least 15 minutes" >&2
  exit 2
fi
if [ "${FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS:-0}" -ne 1 ]; then
  echo "archive-uploader-boot: max concurrent uploads must remain exactly one" >&2
  exit 2
fi

case "${FM_ARCHIVE_UPLOADER_DRY_RUN:-false}" in
  true|false) ;;
  *) echo "archive-uploader-boot: FM_ARCHIVE_UPLOADER_DRY_RUN must be true or false" >&2; exit 2 ;;
esac

if [ "${FM_ARCHIVE_UPLOADER_DRY_RUN:-false}" != true ]; then
  if [ -z "${BACKBLAZE_B2_FMREC_KEY_ID:-}" ] ||
     [ -z "${BACKBLAZE_B2_FMREC_APPLICATION_KEY:-}" ]; then
    echo "archive-uploader-boot: enabled but the write-scoped B2 credentials are absent" >&2
    exit 1
  fi
fi

set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh"
set -u

if [ "${FM_ARCHIVE_UPLOADER_DRY_RUN:-false}" != true ]; then
  python3 -c 'import boto3' >/dev/null 2>&1 || {
    echo "archive-uploader-boot: archive provider runtime is missing; run setup-processor.sh" >&2
    exit 1
  }
fi

if ! ros2 pkg prefix fm_data_archive >/dev/null 2>&1; then
  echo "archive-uploader-boot: fm_data_archive is not built; run setup-processor.sh" >&2
  exit 1
fi

# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # fm_data_root
ARCHIVE_DATA_ROOT="$(fm_data_root "$ROOT")"
RECORDINGS_DIR="${FM_ARCHIVE_UPLOADER_RECORDINGS_DIR:-$ARCHIVE_DATA_ROOT/recordings}"
# The uploader's queue and receipts are archive state, so they sit beside the
# archive's other stage directories rather than in the recording root it reads.
STATE_DIR="${FM_ARCHIVE_UPLOADER_STATE_DIR:-$ARCHIVE_DATA_ROOT/staged/archive-uploader}"

echo "archive-uploader-boot: starting the uploader"
# These are bridge contract topics, shared with Desktop. They are deliberately
# fixed here; an env-file typo must not leave a healthy uploader invisible to the
# app or route a command to an unrelated graph topic.
# A live provider check is a hard start gate. It verifies bucket Object Lock and
# default retention against the provider before one byte is queued.
if [ "${FM_ARCHIVE_UPLOADER_DRY_RUN:-false}" != true ]; then
  ros2 run fm_data_archive archive_preflight || exit $?
fi
exec ros2 run fm_data_archive archive_uploader --ros-args \
  -p recordings_dir:="$RECORDINGS_DIR" \
  -p state_dir:="$STATE_DIR" \
  -p upload_enabled:=true \
  -p deletion_enabled:="${FM_ARCHIVE_UPLOADER_DELETE_ENABLED:-false}" \
  -p dry_run:="${FM_ARCHIVE_UPLOADER_DRY_RUN:-false}" \
  -p min_retention_days:="${FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS:-30}" \
  -p eligibility_window_minutes:="${FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES:-15}" \
  -p max_concurrent_uploads:="${FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS:-1}" \
  -p max_bandwidth_bytes_s:="${FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S:-8388608}" \
  -p storage_index_topic:=/archive/storage/index \
  -p status_topic:=/archive/storage/status \
  -p retry_topic:=/archive/upload/retry \
  -p verify_topic:=/archive/retention/verify \
  -p delete_topic:=/archive/retention/delete
