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

# A non-Humble Linux host (for example the Ubuntu 26.04 workstation) runs the
# processor role in the published Humble container. Reuse that role's compose
# project and entrypoint for the bridge rather than sourcing a host path that
# does not exist. The marker is forwarded through the FM_* environment allowlist
# in container-exec.sh and prevents the nested invocation from recursing.
if [ "${FM_FOXGLOVE_IN_CONTAINER:-0}" != 1 ] && [ ! -f /.dockerenv ]; then
  # shellcheck disable=SC1091
  source "$ROOT/scripts/internal/lib-processor.sh"
  FM_FOXGLOVE_RUNTIME="$(fm_processor_runtime)" || {
    echo "fm-foxglove: cannot resolve a ROS 2 runtime for the standalone bridge" >&2
    exit 1
  }
  case "$FM_FOXGLOVE_RUNTIME" in
    native) ;;
    container)
      echo "fm-foxglove: using the existing fm-processor container for foxglove_bridge"
      export FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1
      export FM_FOXGLOVE_IN_CONTAINER=1
      exec /bin/bash "$ROOT/scripts/service/container-exec.sh" \
        scripts/service/foxglove-boot.sh
      ;;
    *)
      echo "fm-foxglove: unsupported processor runtime '$FM_FOXGLOVE_RUNTIME'" >&2
      exit 1
      ;;
  esac
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
if [ "${FM_FOXGLOVE_IN_CONTAINER:-0}" = 1 ]; then
  # docker compose exec does not forward SIGTERM to the process it starts. Keep
  # this wrapper in the container process table so the service's scoped
  # ExecStop can signal it, then forward the signal to ros2 launch and wait for
  # the bridge to release its listener before systemd considers the unit stopped.
  stopping=0
  launch_pid=""
  trap 'stopping=1; [ -n "${launch_pid:-}" ] && kill -TERM "$launch_pid" 2>/dev/null || true' TERM INT
  ros2 launch foxglove_bridge foxglove_bridge_launch.xml \
    "port:=${FM_BRIDGE_PORT}" "address:=0.0.0.0" &
  launch_pid=$!
  wait "$launch_pid"
  status=$?
  if [ "$stopping" = 1 ] || [ "$status" = 143 ] || [ "$status" = 130 ]; then
    wait "$launch_pid" 2>/dev/null || true
    exit 0
  fi
  exit "$status"
fi

# Native Humble keeps the historical direct exec path.
exec ros2 launch foxglove_bridge foxglove_bridge_launch.xml \
  "port:=${FM_BRIDGE_PORT}" "address:=0.0.0.0"
