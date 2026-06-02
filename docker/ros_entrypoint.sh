#!/usr/bin/env bash
# Source the ROS distro, then the workspace overlay if it has been built.
set -e

source "/opt/ros/${ROS_DISTRO}/setup.bash"

if [ -f /ws/install/setup.bash ]; then
  source /ws/install/setup.bash
fi

exec "$@"
