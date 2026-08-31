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
mode="${1:-start}"
wrapper="${1:-}"
if [ "$mode" != stop ] && [ "$wrapper" = scripts/service/processor-boot.sh ]; then
  # The nested data package checkout is owned by the appliance user on the host. Git
  # quite correctly rejects that checkout from the container's root user, so
  # resolve its exact source identity before entering Docker and pass it through
  # the narrow FM_* environment allowlist below.
  _is_full_commit() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]] &&
      [ "$1" != 0000000000000000000000000000000000000000 ]
  }
  _host_data_commit=""
  _host_data_dirty=0
  if [ -e "$ROOT/src/fm_data/.git" ]; then
    _host_data_commit="$(git -C "$ROOT/src/fm_data" rev-parse --verify HEAD 2>/dev/null || true)"
    _is_full_commit "$_host_data_commit" || _host_data_commit=""
    # HEAD is not a truthful source identity when tracked files differ from it.
    # Ignore untracked runtime outputs (the processor creates those under the
    # checkout), but refuse a cloud launch from a tracked dirty checkout.
    if [ -n "$_host_data_commit" ] && ! git -C "$ROOT/src/fm_data" diff --quiet HEAD -- >/dev/null 2>&1; then
      _host_data_dirty=1
      _host_data_commit=""
    fi
  fi
  _cloud_requested=0
  [ -n "${FM_PROCESSOR_AWS_INFERENCE_SCRIPT:-}" ] && _cloud_requested=1
  [ "${FM_AWS_INFERENCE_SERVICE_MODE:-0}" = 1 ] && _cloud_requested=1
  if [ "$_host_data_dirty" = 1 ]; then
    if [ -n "${FM_PROCESSOR_ANNOTATE_GIT_COMMIT:-}" ] || [ "$_cloud_requested" = 1 ]; then
      echo "ERROR: tracked changes in $ROOT/src/fm_data prevent a trusted annotation source identity" >&2
      echo "       Commit or stash tracked data package changes before the AWS annotation launch." >&2
      exit 1
    fi
  fi
  if [ -n "${FM_PROCESSOR_ANNOTATE_GIT_COMMIT:-}" ]; then
    _is_full_commit "$FM_PROCESSOR_ANNOTATE_GIT_COMMIT" || {
      echo "ERROR: FM_PROCESSOR_ANNOTATE_GIT_COMMIT must be a full 40-character lowercase Git commit" >&2
      exit 1
    }
    if [ -n "$_host_data_commit" ] && [ "$FM_PROCESSOR_ANNOTATE_GIT_COMMIT" != "$_host_data_commit" ]; then
      echo "ERROR: FM_PROCESSOR_ANNOTATE_GIT_COMMIT does not match the host data package checkout" >&2
      echo "       expected $_host_data_commit" >&2
      exit 1
    fi
  elif [ -n "$_host_data_commit" ]; then
    export FM_PROCESSOR_ANNOTATE_GIT_COMMIT="$_host_data_commit"
  elif [ "$_cloud_requested" = 1 ]; then
    echo "ERROR: AWS annotation requires a resolvable host data package source commit" >&2
    echo "       Check out $ROOT/src/fm_data or set a matching reviewed full commit." >&2
    exit 1
  fi
fi

fm_processor_compose "$ROOT"

if [ "$mode" = stop ]; then
  pattern="${2:?process pattern to stop}"
  # docker compose exec does not forward SIGTERM to the process it starts. Run
  # the canonical, bounded process-tree helper inside the role-owned container;
  # it never kills by name on the host and never changes container lifecycle.
  "${FM_COMPOSE[@]}" exec -T -e "FM_STOP_PATTERN=$pattern" \
    -e FM_CONTAINER_STOP_IN_CONTAINER=1 fm \
    bash /ws/scripts/service/container-stop.sh || true
  exit 0
fi

wrapper="${1:?boot wrapper path, relative to the workspace root}"
# The normal processor service owns the container lifecycle and brings its role
# container up when needed.  A standalone bridge must never do that: `up -d`
# may recreate a prepared processor container when compose inputs changed, which
# would interrupt the processor (or a sibling role) just to restore the viewer.
# Its caller opts into an existing-only check and receives an actionable failure
# when the processor role is not already running.
if [ "${FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING:-0}" = 1 ]; then
  if ! "${FM_COMPOSE[@]}" ps --status running --services 2>/dev/null \
      | grep -Fxq fm; then
    echo "ERROR: processor container is not already running; refusing to start $wrapper" >&2
    echo "       Start the prepared processor role first (fm-processor.service), then retry." >&2
    exit 1
  fi
else
  # Same reason as the stack path: a replaced container leaves the host bridge
  # routing for participants that no longer exist, doubling every stream.
  _up_log="$(mktemp)"
  "${FM_COMPOSE[@]}" up -d fm 2>&1 | tee "$_up_log"
  if fm_compose_created_container "$_up_log"; then
    fm_compose_restart_bridge
  fi
  rm -f "$_up_log"
fi

pass=()
while IFS= read -r name; do
  case "$name" in
    FM_*|ROS_*|AWS_CONFIG_FILE|AWS_PROFILE|AWS_DEFAULT_PROFILE|AWS_REGION|AWS_DEFAULT_REGION|AWS_CA_BUNDLE)
      pass+=(-e "$name")
      ;;
  esac
done < <(env | grep -E '^(FM_|ROS_|AWS_)' | cut -d= -f1)

exec "${FM_COMPOSE[@]}" exec ${pass[@]+"${pass[@]}"} fm /ros_entrypoint.sh bash "/ws/$wrapper"
