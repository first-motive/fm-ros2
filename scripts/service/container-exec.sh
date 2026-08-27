#!/usr/bin/env bash
# container-exec.sh — run a boot wrapper inside the processor container, for a
# systemd unit on a host whose processor runtime is `container`.
#
#   ExecStart=/bin/bash scripts/service/container-exec.sh scripts/service/processor-boot.sh
#
# Brings the compose service up (idempotent), then execs the wrapper through the
# image entrypoint so ROS and the overlay are sourced. The unit's environment
# (its EnvironmentFile knobs) is passed through for FM_* and ROS_* values plus
# the non-secret AWS profile/region selectors needed by credential_process. Do
# not forward arbitrary AWS_* values: the archive service may still use static
# B2 credentials, but those must not cross into the processor container's
# Roles Anywhere process environment.
#
# `docker compose exec` does not forward SIGTERM to the process it started, so
# the unit pairs this with an ExecStop that stops the wrapper's launch by name.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/scripts/internal/lib-processor.sh"

#   container-exec.sh stop <pattern>
#
# is the ExecStop half: it ends the matching process inside the container.
fm_processor_compose "$ROOT"

if [ "${1:-}" = stop ]; then
  pattern="${2:?process pattern to stop}"
  "${FM_COMPOSE[@]}" exec fm pkill -f "$pattern" || true
  exit 0
fi

wrapper="${1:?boot wrapper path, relative to the workspace root}"
"${FM_COMPOSE[@]}" up -d fm

pass=()
while IFS= read -r name; do
  case "$name" in
    FM_*|ROS_*|AWS_CONFIG_FILE|AWS_PROFILE|AWS_DEFAULT_PROFILE|AWS_REGION|AWS_DEFAULT_REGION|AWS_CA_BUNDLE)
      pass+=(-e "$name")
      ;;
  esac
done < <(env | grep -E '^(FM_|ROS_|AWS_)' | cut -d= -f1)

exec "${FM_COMPOSE[@]}" exec ${pass[@]+"${pass[@]}"} fm /ros_entrypoint.sh bash "/ws/$wrapper"
