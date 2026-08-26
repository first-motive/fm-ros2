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

if FM_ARCHIVE_ENABLED=true FM_ARCHIVE_LEROBOT_STAGE_ENABLED=invalid \
  bash scripts/service/archive-boot.sh >/dev/null 2>&1; then
  echo "invalid LeRobot stage setting was accepted" >&2
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

# The archive request and completion contract stays on two topics: Desktop
# publishes `/archive/stage`, while the archive node reports queued, progress,
# refusal, failure, and completion in the `stage` block of latched
# `/archive/status`. Keep the bridge check aligned with those names.
grep -q '/archive/index /archive/status /archive/stage' \
  scripts/service/archive-check.sh
grep -q 'stage.*block' scripts/service/archive-check.sh

# The processor build must carry the archive package, but the service remains
# independently default-off. This keeps a fresh processor checkout able to
# expose the contract without silently enabling B2 reads or local staging.
grep -q 'fm_data_archive' scripts/install/setup-processor.sh
grep -q 'FM_ARCHIVE_ENABLED=false' scripts/install/install-archive-service.sh
grep -q 'FM_ARCHIVE_STAGE_ENABLED=false' scripts/install/install-archive-service.sh
grep -q 'FM_ARCHIVE_LEROBOT_CATALOGUE_FILE=' scripts/install/install-archive-service.sh
grep -q 'FM_ARCHIVE_LEROBOT_STAGE_ENABLED=false' scripts/install/install-archive-service.sh
grep -q -- '-p stage_topic:=/archive/stage' scripts/service/archive-boot.sh
grep -q -- '-p status_topic:=/archive/status' scripts/service/archive-boot.sh
grep -q -- '-p lerobot_catalogue_file:' scripts/service/archive-boot.sh
grep -q -- '-p lerobot_stage_dir:' scripts/service/archive-boot.sh
grep -q -- '-p lerobot_stage_enabled:' scripts/service/archive-boot.sh

# The app-facing boundary receives only ROS parameters. Credentials remain in
# the service environment and are never passed as node arguments.
if grep -E -- '-p (AWS_|B2_|bucket|key|prefix)' scripts/service/archive-boot.sh; then
  echo "archive credentials or provider selectors entered the node arguments" >&2
  exit 1
fi

echo "test-archive-service: passed"
