#!/usr/bin/env bash
# Talk to the processor's supervisors from a shell. Sourced by process.sh and
# release.sh — never executed.
#
# Desktop drives the processor over latched JSON-on-String topics
# (/process/*, /release/*). These helpers publish the same requests and read
# the same latched answers, inside the processor's own runtime, so a verb sees
# exactly what Desktop sees and nothing else. No engine logic lives here.
# shellcheck source=lib-processor.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-processor.sh"

FM_SUPERVISOR_TIMEOUT="${FM_SUPERVISOR_TIMEOUT:-20}" # seconds per topic read or publish

# fm_supervisor_require
# The supervisors run where the processor role is installed; anywhere else
# there is no graph to read, and saying so beats an empty payload.
fm_supervisor_require() {
  if ! fm_processor_installed; then
    echo "error: the processor role is not installed on this host (no ${FM_PROCESSOR_ENV_FILE:-/etc/fm-processor.env})" >&2
    echo "       run this where fm-processor.service lives" >&2
    return 1
  fi
}

# fm_supervisor_exec <command...>
# One command in the processor's runtime with ROS sourced, argv preserved.
fm_supervisor_exec() {
  fm_processor_exec "$PWD" bash -lc 'exec "$@"' bash "$@"
}

# fm_supervisor_read <topic>
# Print the latched JSON payload on <topic>. Fails when nothing is publishing
# it within the timeout — the supervisor is down, or not on this graph.
fm_supervisor_read() {
  local topic="$1" payload
  payload=$(fm_supervisor_exec timeout "$FM_SUPERVISOR_TIMEOUT" \
    ros2 topic echo --once --field data "$topic" 2>/dev/null || true)
  if [[ -z "$payload" ]]; then
    echo "error: nothing published on $topic within ${FM_SUPERVISOR_TIMEOUT}s — is fm-processor.service running?" >&2
    return 1
  fi
  printf '%s\n' "$payload"
}

# fm_supervisor_publish <topic> <payload>
# Publish one String request and wait for the supervisor to be subscribed
# first; a request published into a graph nobody has joined is silently lost.
fm_supervisor_publish() {
  local topic="$1" payload="$2"
  local yaml="{data: \"${payload//\"/\\\"}\"}"
  if ! fm_supervisor_exec timeout "$FM_SUPERVISOR_TIMEOUT" \
    ros2 topic pub -1 -w 1 "$topic" std_msgs/msg/String "$yaml" >/dev/null 2>&1; then
    echo "error: no subscriber on $topic within ${FM_SUPERVISOR_TIMEOUT}s — is fm-processor.service running?" >&2
    return 1
  fi
}

# fm_supervisor_format <python-source>
# Pretty-print the JSON on stdin with a small formatter, run in the processor's
# runtime rather than the host's — the same reason dataset.sh parses the
# manifest there: jq is not in the image, python always is.
fm_supervisor_format() {
  fm_supervisor_exec python3 -c "$1"
}

# fm_supervisor_request_id
# A contract-safe id for a release request: lowercase, digits, dashes.
fm_supervisor_request_id() {
  printf 'cli-%s-%04x\n' "$(date -u +%Y%m%dt%H%M%Sz)" "$((RANDOM % 65536))"
}
