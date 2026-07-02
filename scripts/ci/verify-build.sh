#!/usr/bin/env bash
# Build and test the workspace inside the base image. Same commands CI runs.
# Usage:
#   ./scripts/ci/verify-build.sh            # run inside the container
#   docker compose -f docker/compose.yaml -f docker/compose.macos.yaml \
#     run --rm fm ./scripts/ci/verify-build.sh    # from the macOS host
set -euo pipefail

usage() {
  cat <<'EOF'
verify-build.sh — build and test the workspace inside the base image (same as CI)

Usage: ./scripts/ci/verify-build.sh [-h]

  -h, --help   show this help
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$ROOT"

  # ROS setup files reference unbound vars; relax `set -u` only across sourcing.
  set +u
  # shellcheck source=/dev/null
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
  set -u

  echo "==> colcon build"
  colcon build --symlink-install

  echo "==> colcon test"
  colcon test --return-code-on-test-failure

  echo "==> colcon test-result"
  colcon test-result --verbose

  echo "==> Build + test green."
}

main "$@"
