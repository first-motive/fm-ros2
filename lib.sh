#!/usr/bin/env bash
# Shared narration helpers for the fm_ros2 scripts. Sourced, never executed.
#
# This file is the only copy. install.sh runs curl-piped before the clone exists,
# so it fetches this file and evals it (see load_lib there) rather than carrying
# duplicates that drift.

# Status line under a step header — one place to restyle later.
item() { echo "$1"; }

# Newest release tag of a checkout (vN.N.N-style, highest by version sort), or
# empty when the repo has none. The appliance release channel keys off this:
# installers pin to it and appliance-update.sh converges to it.
latest_release_tag() {  # dir
  git -C "$1" tag -l 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -1
}

# Move a checkout onto its newest release tag — the appliance install-time half
# of the release channel (appliance-update.sh is the converge-over-time half).
# Refuses to move a repo with local changes, and leaves an untagged repo where
# it is; both are warned, never fatal. Tag tips are fetched shallow when the
# repo itself is shallow, so a --depth 1 appliance clone stays lean.
pin_release() {  # dir
  local dir="$1" tag
  [ -d "$dir/.git" ] || return 0
  local -a depth=()
  [ -f "$(git -C "$dir" rev-parse --git-dir)/shallow" ] && depth=(--depth 1)
  git -C "$dir" fetch --quiet --force ${depth[@]+"${depth[@]}"} origin \
    '+refs/tags/*:refs/tags/*' 2>/dev/null || true
  tag="$(latest_release_tag "$dir")"
  if [ -z "$tag" ]; then
    item "WARNING: $(basename "$dir") has no release tag yet — staying on its current checkout"
    return 0
  fi
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    item "WARNING: $(basename "$dir") has local changes — not moving it to $tag"
    return 0
  fi
  [ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$dir" rev-parse "$tag^{commit}")" ] && return 0
  item "pinning $(basename "$dir") to release $tag ..."
  git -C "$dir" -c advice.detachedHead=false checkout --quiet "$tag"
}

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
