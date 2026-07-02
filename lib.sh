#!/usr/bin/env bash
# Shared narration helpers for the fm_ros2 scripts. Sourced, never executed.
#
# install.sh carries inline copies of these: it runs curl-piped before the clone
# exists, so it has no repo file to source. When editing here, mirror the change
# into install.sh.

# Status line under a step header — one place to restyle later.
item() { echo "$1"; }

# Run a long command with live feedback. TTY: fork it, spin a frame + elapsed
# seconds on one \r line until it exits, then clear the line — replaying the
# captured output only on failure so a green run stays quiet and a red one is
# still debuggable. Piped (no TTY): run inline so output and errors stream
# straight through, no \r control chars in a log. Returns the command's exit.
spin() {  # label  cmd...
  local label="$1"; shift
  if [ ! -t 1 ]; then
    "$@"
    return $?
  fi
  local log; log="$(mktemp)" || return 1
  # <&0 forwards our stdin to the async job — a backgrounded command otherwise
  # gets stdin from /dev/null (POSIX), starving stdin-reading children like
  # `vcs import < manifest`.
  "$@" <&0 >"$log" 2>&1 &
  local pid=$! frames='|/-\' i=0 start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s %s (%ds)' "${frames:i%4:1}" "$label" "$((SECONDS - start))"
    i=$((i + 1))
    sleep 0.1
  done
  wait "$pid"; local rc=$?
  printf '\r\033[K'
  [ "$rc" -eq 0 ] || cat "$log" >&2
  rm -f "$log"
  return "$rc"
}
