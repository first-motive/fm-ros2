#!/usr/bin/env bash
# comms.sh — select the inter-device comms profile and source it.
#
# Every ROS terminal sources THIS rather than a transport script directly, so the
# transport is one decision in one place: a single run overrides it with
# FM_COMMS, a host pins it with the "comms" key in .fm_ros2.json, and changing
# what everyone gets by default is a one-line change here.
#
# Resolution order: FM_COMMS > "comms" in .fm_ros2.json > foxglove.
#
# Profiles:
#   foxglove   FastDDS pinned to the LAN interface (dds-lan.sh) under a
#              foxglove_bridge WebSocket. The default — what every demo runs.
#   <other>    scripts/env/comms-<other>.sh, when that file exists.
#
# An unknown profile warns and falls back to foxglove: a headless rig coming up
# on the working default beats one that does not come up at all.
#
# Usage — SOURCE this in every ROS terminal on every machine:
#     source scripts/env/comms.sh
# Override for one run:
#     FM_COMMS=zenoh source scripts/env/comms.sh

# Self-locating: ~/.bashrc sources this from an arbitrary cwd, so the workspace
# root (and with it .fm_ros2.json) is resolved from this file's own path.
_fm_comms_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_fm_comms_profile() {
  if [ -n "${FM_COMMS:-}" ]; then echo "$FM_COMMS"; return; fi
  local file="$_fm_comms_root/.fm_ros2.json" value
  if [ -f "$file" ]; then
    value=$(sed -n 's/.*"comms"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1)
    [ -n "$value" ] && { echo "$value"; return; }
  fi
  echo foxglove
}

_fm_comms="$(_fm_comms_profile)"
# The profile name becomes a path segment, so hold it to the shape a filename can
# take — otherwise a stray value walks out of scripts/run/ and sources something else.
if ! printf '%s' "$_fm_comms" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
  echo "comms: invalid profile name '$_fm_comms' (want lowercase, digits, dashes) — using foxglove." >&2
  _fm_comms=foxglove
fi

_fm_comms_script="$_fm_comms_root/scripts/env/comms-${_fm_comms}.sh"
if [ "$_fm_comms" != foxglove ] && [ ! -f "$_fm_comms_script" ]; then
  echo "comms: unknown profile '$_fm_comms' (no $_fm_comms_script) — using foxglove." >&2
  _fm_comms=foxglove
fi

if [ "$_fm_comms" = foxglove ]; then
  # shellcheck disable=SC1091
  source "$_fm_comms_root/scripts/env/dds-lan.sh"
else
  # shellcheck disable=SC1090
  source "$_fm_comms_script"
fi

unset -f _fm_comms_profile
unset _fm_comms _fm_comms_root _fm_comms_script
