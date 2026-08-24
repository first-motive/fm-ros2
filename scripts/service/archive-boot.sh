#!/usr/bin/env bash
# Start the processor-owned archive browser in its own systemd service.
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

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "archive-boot: enabled but the read-only B2 credentials are absent" >&2
  exit 1
fi

CACHE_DIR="${FM_ARCHIVE_CACHE_DIR:-$HOME/.cache/fm-archive}"
STAGE_DIR="${FM_ARCHIVE_STAGE_DIR:-$HOME/.cache/fm-archive/staged}"

echo "archive-boot: starting the local archive browser"
exec ros2 run fm_data_archive archive_browser --ros-args \
  -p cache_dir:="$CACHE_DIR" \
  -p stage_dir:="$STAGE_DIR" \
  -p stage_enabled:="${FM_ARCHIVE_STAGE_ENABLED:-false}" \
  -p stage_max_objects:="${FM_ARCHIVE_MAX_OBJECTS:-16}" \
  -p stage_max_total_bytes:="${FM_ARCHIVE_MAX_TOTAL_BYTES:-2147483648}" \
  -p stage_max_episodes:="${FM_ARCHIVE_MAX_EPISODES:-32}" \
  -p stage_retention_days:="${FM_ARCHIVE_RETENTION_DAYS:-30}" \
  -p stage_max_attempts:="${FM_ARCHIVE_MAX_ATTEMPTS:-3}"
