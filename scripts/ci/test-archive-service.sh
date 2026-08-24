#!/usr/bin/env bash
# Host-side checks for the default-off local archive service contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

output="$(FM_ARCHIVE_ENABLED=false bash scripts/service/archive-boot.sh)"
grep -q 'disabled' <<<"$output"

if FM_ARCHIVE_ENABLED=invalid bash scripts/service/archive-boot.sh \
  >/dev/null 2>&1; then
  echo "invalid archive setting was accepted" >&2
  exit 1
fi

if FM_ARCHIVE_ENABLED=true FM_ARCHIVE_STAGE_ENABLED=invalid \
  bash scripts/service/archive-boot.sh >/dev/null 2>&1; then
  echo "invalid stage setting was accepted" >&2
  exit 1
fi

grep -q 'src/fm_data/fm_data_archive' scripts/install/setup-processor.sh
grep -q 'fm_data_archive' scripts/install/setup-processor.sh
grep -q 'python3-boto3' scripts/install/setup-processor.sh
grep -q 'EnvironmentFile=-\$ENVFILE' scripts/install/install-archive-service.sh
if grep -q 'EnvironmentFile=-/etc/fm-processor.env' \
  scripts/install/install-archive-service.sh; then
  echo "archive service inherits the processor credential environment" >&2
  exit 1
fi
grep -q 'chmod 600' scripts/install/install-archive-service.sh
grep -q 'FM_ARCHIVE_STAGE_ENABLED=false' scripts/install/install-archive-service.sh

# The app-facing boundary receives only ROS parameters. Credentials remain in
# the service environment and are never passed as node arguments.
if grep -E -- '-p (AWS_|B2_|bucket|key|prefix)' scripts/service/archive-boot.sh; then
  echo "archive credentials or provider selectors entered the node arguments" >&2
  exit 1
fi

echo "test-archive-service: passed"
