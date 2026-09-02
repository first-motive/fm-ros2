#!/usr/bin/env bash
# Deterministic check for the shared LeRobot archive -> Process root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

grep -q 'FM_PROCESSOR_LEROBOT_IMPORTS_DIR=/data/staged/lerobot' \
  scripts/install/install-processor-service.sh
grep -q 'FM_PROCESSOR_LEROBOT_IMPORTS_DIR' scripts/service/processor-boot.sh
grep -q 'lerobot_imports_dir:=' scripts/service/processor-boot.sh
grep -q 'FM_ARCHIVE_LEROBOT_STAGE_DIR=/data/staged/lerobot' \
  scripts/install/install-archive-service.sh
grep -q 'staged:/data/staged' compose.processor.yaml

# The launch file is imported under src/ before this CI check. An explicit
# override lets a developer run the same source contract against a sibling
# checkout without encoding a private repository name here.
LAUNCH="${FM_PROCESSOR_SOURCE_LAUNCH:-${ROOT}/src/fm_data/launch/process_session.launch.py}"
[ -f "$LAUNCH" ] || {
  echo "process_session.launch.py is unavailable; import the data source first" >&2
  exit 1
}
grep -q '"lerobot_imports_dir"' "$LAUNCH"
grep -q '"lerobot_imports_dir": LaunchConfiguration' "$LAUNCH"

echo "test-processor-lerobot-root: passed"
