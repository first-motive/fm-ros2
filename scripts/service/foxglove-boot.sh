#!/usr/bin/env bash
# foxglove-boot.sh — run the one standalone First Motive Foxglove bridge.
#
# The paired installer persists /etc/fm-bridge.env and disables the recorder's
# embedded bridge before this unit starts. The wrapper still checks the port so a
# stray Axol inference server or stale bridge produces a useful journal error.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/env/bridge.sh"

if [ "$FM_BRIDGE_OWNER" != standalone ]; then
  echo "fm-foxglove: FM_BRIDGE_OWNER=$FM_BRIDGE_OWNER; refusing to start the standalone owner" >&2
  echo "  set FM_BRIDGE_OWNER=standalone with install-foxglove-service.sh" >&2
  exit 78
fi

if ! fm_bridge_require_free "$FM_BRIDGE_PORT"; then
  echo "fm-foxglove: cannot start; the configured port is already owned" >&2
  exit 78
fi

# ROS setup.bash references unset AMENT_*/COLCON_* variables. Relax nounset only
# while sourcing the generated environments, then restore it for the exec path.
set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh"
set -u

echo "fm-foxglove: starting standalone foxglove_bridge on 0.0.0.0:$FM_BRIDGE_PORT"
exec ros2 launch foxglove_bridge foxglove_bridge_launch.xml \
  "port:=${FM_BRIDGE_PORT}" "address:=0.0.0.0"
