#!/usr/bin/env bash
# Front door for the fm_ros2 stack. The run logic lives in scripts/run/; this
# forwards to the container path for now. A later step turns this into a thin
# dispatcher that reads the persisted profile (.fm_ros2.json) and routes to the
# native or container path.
#
# Wrapped so a truncated curl|bash never half-runs.
set -euo pipefail

exec "$(dirname "$0")/scripts/run/container.sh" "$@"
