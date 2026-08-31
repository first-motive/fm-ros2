#!/usr/bin/env bash
# comms.sh — select the inter-device comms profile and source it.
#
# Every ROS terminal sources THIS rather than a transport script directly, so the
# transport is one decision in one place. The decision itself is not made here:
# it is written on this machine's identity card, which `fm machine init` wrote
# and which fm-comms renders its zenoh configs from. A host that says
# `transport: zenoh` on its card and runs FastDDS in its shells is a host whose
# bridge routes an empty graph.
#
# Resolution order, first hit wins:
#
#   FM_TRANSPORT / FM_COMMS        one run, one shell — the escape hatch
#   machine.json "transport"       what this host actually is
#   .fm_ros2.json "comms"          a checkout with no card yet
#   zenoh                          the default
#
# Profiles:
#   zenoh      DDS pinned to loopback on every host, one zenoh-bridge-ros2dds
#              per machine, one zenohd router. The default and the supported path.
#   dds-lan    FastDDS pinned to the LAN interface. The labelled escape hatch,
#              kept for hardware that has not been through the transport
#              migration. `foxglove` is the old name for it and still works.
#   none       change nothing. Inherit whatever middleware the environment
#              already carries — the container image's own default, or an
#              operator's hand-set variables. For a context that has no transport
#              decision to make: a single self-contained container with no bridge
#              and no router in it, or a debugging session where the profile is
#              the thing under suspicion.
#
# An unknown profile warns and falls back to the default: a headless rig coming
# up on the working transport beats one that does not come up at all.
#
# Usage — SOURCE this in every ROS terminal on every machine:
#     source scripts/env/comms.sh
# Override for one run:
#     FM_TRANSPORT=dds-lan source scripts/env/comms.sh

# Self-locating: ~/.bashrc sources this from an arbitrary cwd, so the workspace
# root (and with it .fm_ros2.json) is resolved from this file's own path. zsh —
# the macOS default shell — has no BASH_SOURCE; without its %x prompt escape the
# root would silently resolve to the cwd's parent and read the wrong
# .fm_ros2.json. The zsh expansion hides inside eval so bash never parses it —
# and inside eval only %x still names the sourced file (%N names the eval).
_fm_comms_self="${BASH_SOURCE[0]:-}"
if [ -z "$_fm_comms_self" ] && [ -n "${ZSH_VERSION:-}" ]; then
  eval '_fm_comms_self="${(%):-%x}"'
fi
if [ ! -f "$_fm_comms_self" ]; then
  echo "comms: cannot locate myself — source this from bash or zsh; direct execution unsupported." >&2
  unset _fm_comms_self
  # shellcheck disable=SC2317  # reached when this file is executed, not sourced
  return 1 2>/dev/null || exit 1
fi
_fm_comms_root="$(cd "$(dirname "$_fm_comms_self")/../.." && pwd)"
unset _fm_comms_self

# What every host gets when nothing says otherwise.
_fm_comms_default=zenoh

# The card this machine's identity is written on. fm-setup writes it; every repo
# that needs a per-host fact reads it. FM_MACHINE_FILE points the whole toolchain
# at another card, which is how a test and a rehearsal container work.
_fm_comms_card() {
  if [ -n "${FM_MACHINE_FILE:-}" ]; then echo "$FM_MACHINE_FILE"; return; fi
  case "$(uname -s)" in
    Darwin) echo "${XDG_CONFIG_HOME:-$HOME/.config}/fm/machine.json" ;;
    *)      echo /etc/fm/machine.json ;;
  esac
}

# The card schema this checkout understands. A card stamped with anything else is
# ignored with a warning rather than guessed at — a transport field that changed
# meaning between versions would otherwise silently pick the wrong middleware.
_fm_comms_schema=1

# Echo the card's transport, or nothing. Deliberately quiet on absence: a laptop
# running in client mode has no card, and that is a legitimate thing to be.
_fm_comms_from_card() {
  local file version
  file="$(_fm_comms_card)"
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || {
    echo "comms: $file exists but jq is not installed — falling back to the profile file." >&2
    return 0
  }
  version="$(jq -r '.schema_version // empty' "$file" 2>/dev/null)"
  if [ "$version" != "$_fm_comms_schema" ]; then
    echo "comms: $file is schema_version ${version:-<none>}; this checkout reads $_fm_comms_schema — ignoring it." >&2
    return 0
  fi
  jq -r '.transport // empty' "$file" 2>/dev/null
}

_fm_comms_profile() {
  # FM_TRANSPORT is the documented escape hatch and names the same values the
  # card does; FM_COMMS is the older spelling and still works.
  if [ -n "${FM_TRANSPORT:-}" ]; then echo "$FM_TRANSPORT"; return; fi
  if [ -n "${FM_COMMS:-}" ]; then echo "$FM_COMMS"; return; fi

  local value
  value="$(_fm_comms_from_card)"
  [ -n "$value" ] && { echo "$value"; return; }

  # A checkout on a machine that has no card yet. Kept so a developer laptop and
  # a half-provisioned rig still start, and deliberately last: the card is the
  # source of truth the moment there is one.
  local file="$_fm_comms_root/.fm_ros2.json"
  if [ -f "$file" ]; then
    value=$(sed -n 's/.*"comms"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1)
    [ -n "$value" ] && { echo "$value"; return; }
  fi

  echo "$_fm_comms_default"
}

_fm_comms="$(_fm_comms_profile)"

# The profile name becomes a path segment, so hold it to the shape a filename can
# take — otherwise a stray value walks out of scripts/env/ and sources something else.
if ! printf '%s' "$_fm_comms" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
  echo "comms: invalid profile name '$_fm_comms' (want lowercase, digits, dashes) — using $_fm_comms_default." >&2
  _fm_comms="$_fm_comms_default"
fi

# `foxglove` was this profile's name before the card gave the same idea the name
# `dds-lan`. Both spellings reach the same script, so an old .fm_ros2.json and an
# old runbook keep working.
[ "$_fm_comms" = foxglove ] && _fm_comms=dds-lan

# `none` is answered here and nothing is sourced. Deliberately not a profile file
# that exports nothing: the point is that this shell's middleware variables are
# left exactly as they were found, and an empty profile script would still have
# to be reasoned about every time someone reads one.
if [ "$_fm_comms" = none ]; then
  export FM_COMMS_PROFILE=none
  echo "comms: none — inheriting this environment's middleware, unchanged"
  unset -f _fm_comms_profile _fm_comms_from_card _fm_comms_card
  unset _fm_comms _fm_comms_root _fm_comms_default _fm_comms_schema
  # Sourced, always — the front doors and every verb `source` this file. The
  # guard keeps a stray direct execution from dying on a bare `return`.
  # shellcheck disable=SC2317  # reached when this file is executed, not sourced
  return 0 2>/dev/null || true
fi

case "$_fm_comms" in
  dds-lan) _fm_comms_script="$_fm_comms_root/scripts/env/dds-lan.sh" ;;
  *)       _fm_comms_script="$_fm_comms_root/scripts/env/comms-$_fm_comms.sh" ;;
esac

if [ ! -f "$_fm_comms_script" ]; then
  echo "comms: unknown profile '$_fm_comms' (no $_fm_comms_script) — using $_fm_comms_default." >&2
  _fm_comms="$_fm_comms_default"
  _fm_comms_script="$_fm_comms_root/scripts/env/comms-$_fm_comms.sh"
fi

# Exported so a caller that has to carry the transport somewhere else — the
# container path builds a compose environment out of it — reads the resolved
# answer rather than resolving it a second time and possibly differently.
export FM_COMMS_PROFILE="$_fm_comms"

# shellcheck disable=SC1090
source "$_fm_comms_script"

unset -f _fm_comms_profile _fm_comms_from_card _fm_comms_card
unset _fm_comms _fm_comms_root _fm_comms_script _fm_comms_default _fm_comms_schema
