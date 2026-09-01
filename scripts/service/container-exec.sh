#!/usr/bin/env bash
# container-exec.sh — run a boot wrapper inside the processor container, for a
# systemd unit on a host whose processor runtime is `container`.
#
#   ExecStart=/bin/bash scripts/service/container-exec.sh scripts/service/processor-boot.sh
#
# Brings the compose service up (idempotent), then execs the wrapper through the
# image entrypoint so ROS and the overlay are sourced. The unit's environment
# (its EnvironmentFile knobs) is passed through for FM_* and ROS_* values plus
# the non-secret AWS profile/region selectors needed by credential_process. The
# two exact Backblaze credential pairs are the only static secrets allowed
# through: each belongs to a separate service env file and is mapped to boto3
# names inside that service's boot wrapper. Do not widen this allowlist.
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
# Archive siblings are read/write-adjacent to the processor but do not own its
# lifecycle. Force their existing-only mode at the final boundary as well as in
# their systemd units, so a stale or hand-edited env file cannot turn a bridge
# restart into `compose up -d` and recreate the processor container.
case "$wrapper" in
  scripts/service/archive-boot.sh|scripts/service/archive-uploader-boot.sh)
    export FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1
    ;;
esac
# The normal processor service owns the container lifecycle and brings its role
# container up when needed.  A standalone bridge must never do that: `up -d`
# may recreate a prepared processor container when compose inputs changed, which
# would interrupt the processor (or a sibling role) just to restore the viewer.
# Its caller opts into an existing-only check and receives an actionable failure
# when the processor role is not already running.
#
# `After=fm-processor.service` is satisfied when systemd *starts* the processor
# unit, not when its role container is accepting exec. A sibling entered here on
# the same boot or deploy therefore reaches this check seconds before the
# container exists. Refusing at once made every boot and every converge log a
# unit failure that the following restart silently cleared, which is exactly the
# signal a fail-closed uploader cannot afford to lose. Wait a bounded time for
# the role to appear, and keep the refusal for a processor that never arrives.
if [ "${FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING:-0}" = 1 ]; then
  wait_seconds="${FM_PROCESSOR_CONTAINER_WAIT_SECONDS:-60}"
  case "$wait_seconds" in
    ''|*[!0-9]*)
      echo "ERROR: FM_PROCESSOR_CONTAINER_WAIT_SECONDS must be a whole number of seconds (got '$wait_seconds')" >&2
      exit 1
      ;;
  esac
  waited=0
  until "${FM_COMPOSE[@]}" ps --status running --services 2>/dev/null \
      | grep -Fxq fm; do
    if [ "$waited" -ge "$wait_seconds" ]; then
      echo "ERROR: processor container is not already running; refusing to start $wrapper" >&2
      echo "       Waited ${wait_seconds}s for the processor role container." >&2
      echo "       Start the prepared processor role first (fm-processor.service), then retry." >&2
      exit 1
    fi
    if [ "$waited" = 0 ]; then
      echo "waiting up to ${wait_seconds}s for the processor role container ..." >&2
    fi
    sleep 1
    waited=$((waited + 1))
  done
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
    BACKBLAZE_B2_PROCARCH_KEY_ID|BACKBLAZE_B2_PROCARCH_APPLICATION_KEY|\
    BACKBLAZE_B2_FMREC_KEY_ID|BACKBLAZE_B2_FMREC_APPLICATION_KEY)
      # Static B2 credentials are service-scoped. Never leak them into the
      # processor supervisor or an unrelated role wrapper just because a human
      # shell happened to export both pairs.
      case "$wrapper" in
        scripts/service/archive-boot.sh)
          case "$name" in
            BACKBLAZE_B2_PROCARCH_KEY_ID|BACKBLAZE_B2_PROCARCH_APPLICATION_KEY)
              pass+=(-e "$name")
              ;;
          esac
          ;;
        scripts/service/archive-uploader-boot.sh)
          case "$name" in
            BACKBLAZE_B2_FMREC_KEY_ID|BACKBLAZE_B2_FMREC_APPLICATION_KEY)
              pass+=(-e "$name")
              ;;
          esac
          ;;
      esac
      ;;
  esac
done < <(env | grep -E '^(FM_|ROS_|AWS_|BACKBLAZE_)' | cut -d= -f1)

exec "${FM_COMPOSE[@]}" exec ${pass[@]+"${pass[@]}"} fm /ros_entrypoint.sh bash "/ws/$wrapper"
