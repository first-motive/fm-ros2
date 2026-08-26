#!/usr/bin/env bash
# Deterministic check for the shared LeRobot archive -> Process root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

grep -q 'FM_PROCESSOR_LEROBOT_IMPORTS_DIR=~/.cache/fm-archive/lerobot-staged' \
  scripts/install/install-processor-service.sh
grep -q 'FM_PROCESSOR_LEROBOT_IMPORTS_DIR' scripts/service/processor-boot.sh
grep -q 'lerobot_imports_dir:=' scripts/service/processor-boot.sh
grep -q 'FM_ARCHIVE_LEROBOT_STAGE_DIR=~/.cache/fm-archive/lerobot-staged' \
  scripts/install/install-archive-service.sh

# The launch file is imported under src/ in CI and lives beside fm-ros2 in this
# checkout. Check either location so the same contract test works before and
# after vcs import.
LAUNCH="${ROOT}/src/fm_data/launch/process_session.launch.py"
if [ ! -f "$LAUNCH" ]; then
  LAUNCH="${ROOT}/../fm-data/launch/process_session.launch.py"
fi
[ -f "$LAUNCH" ] || {
  echo "process_session.launch.py is unavailable; import fm-data first" >&2
  exit 1
}
grep -q '"lerobot_imports_dir"' "$LAUNCH"
grep -q '"lerobot_imports_dir": LaunchConfiguration' "$LAUNCH"

echo "test-processor-lerobot-root: passed"
