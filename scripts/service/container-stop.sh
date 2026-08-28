#!/usr/bin/env bash
# Stop one role-owned process tree inside the processor container.
#
# FM_STOP_PATTERN is a fixed command-line substring supplied by
# container-exec.sh. The wrapper/launch roots are signalled first so ros2 launch
# can propagate TERM to its nodes; surviving descendants are signalled only
# after a bounded grace period, then escalated by their original PID and
# /proc start time. This helper must run inside the fm processor container.
set -u

if [ "${FM_CONTAINER_STOP_IN_CONTAINER:-0}" != 1 ] && [ ! -f /.dockerenv ]; then
  echo "ERROR: container-stop.sh must run inside the processor container" >&2
  exit 78
fi

pattern="${FM_STOP_PATTERN:-}"
[ -n "$pattern" ] || exit 0

# Fixed-substring process discovery avoids regex/self-match surprises. Exclude
# this helper and every ancestor explicitly; the pattern is passed in the
# environment rather than argv, so the diagnostic shell cannot match itself.
# Use indexed arrays instead of associative arrays: the appliance's Bash is
# modern, but the same helper remains parseable by macOS Bash 3 for CI fixtures.
skip=()
matches=()
match_parents=()
starts_pids=()
starts_values=()
self="$$"
skip+=("$self")

contains() { # needle array...
  local needle="$1" value
  shift
  for value in "${@}"; do
    [ "$value" = "$needle" ] && return 0
  done
  return 1
}

is_skipped() {
  [ "${#skip[@]}" -gt 0 ] && contains "$1" "${skip[@]}"
}

has_match() {
  [ "${#matches[@]}" -gt 0 ] && contains "$1" "${matches[@]}"
}

set_start() { # pid starttime
  local pid="$1" value="$2" i
  for i in "${!starts_pids[@]}"; do
    if [ "${starts_pids[i]}" = "$pid" ]; then
      starts_values[i]="$value"
      return 0
    fi
  done
  starts_pids+=("$pid")
  starts_values+=("$value")
}

start_for() {
  local pid="$1" i
  for i in "${!starts_pids[@]}"; do
    if [ "${starts_pids[i]}" = "$pid" ]; then
      printf '%s\n' "${starts_values[i]}"
      return 0
    fi
  done
  return 1
}

proc_stat() { # pid -> state ppid starttime
  local pid="$1"
  [ -r "/proc/$pid/stat" ] || return 1
  awk '{sub(/^.*\) /, ""); print $1, $2, $20}' "/proc/$pid/stat" 2>/dev/null
}

ancestor="$(proc_stat "$self" 2>/dev/null | awk '{print $2}' || true)"
while [ -n "$ancestor" ] && [ "$ancestor" -gt 1 ] 2>/dev/null; do
  skip+=("$ancestor")
  ancestor="$(proc_stat "$ancestor" 2>/dev/null | awk '{print $2}' || true)"
done

proc_start() {
  local pid="$1" state parent start
  read -r state parent start < <(proc_stat "$pid") || return 1
  [ -n "$start" ] || return 1
  printf '%s\n' "$start"
}

proc_alive() {
  local pid="$1" expected="$2" state parent start
  read -r state parent start < <(proc_stat "$pid") || return 1
  [ "$start" = "$expected" ] || return 1
  [ "$state" != Z ]
}

# Find fixed-substring matches and retain only roots whose parent is not also a
# match. A root can be a wrapper or a launch process, depending on the stop
# pattern sent by the systemd unit.
for proc in /proc/[0-9]*; do
  pid="${proc##*/}"
  [ -d "$proc" ] || continue
  is_skipped "$pid" && continue
  [ -r "$proc/cmdline" ] || continue
  cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
  case "$cmd" in
    *"$pattern"*)
      read -r state parent start < <(proc_stat "$pid") || continue
      [ -n "$start" ] || continue
      matches+=("$pid")
      match_parents+=("$parent")
      set_start "$pid" "$start"
      ;;
  esac
done

roots=()
for i in "${!matches[@]}"; do
  pid="${matches[i]}"
  parent="${match_parents[i]}"
  has_match "$parent" && continue
  roots+=("$pid")
done

pids=()
add_tree() {
  local pid="$1" child start
  [ "$pid" -gt 1 ] || return 0
  [ "${#pids[@]}" -gt 0 ] && contains "$pid" "${pids[@]}" && return 0
  start="$(proc_start "$pid" 2>/dev/null || true)"
  [ -n "$start" ] || return 0
  set_start "$pid" "$start"
  pids+=("$pid")
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    add_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
}

[ "${#roots[@]}" -gt 0 ] || exit 0
for pid in "${roots[@]}"; do
  add_tree "$pid"
done
[ "${#pids[@]}" -gt 0 ] || exit 0

wait_tree() { # polling rounds (250ms each)
  local rounds="$1" round pid alive expected
  for ((round=0; round<rounds; round++)); do
    alive=0
    for pid in "${pids[@]}"; do
      expected="$(start_for "$pid" 2>/dev/null || true)"
      if proc_alive "$pid" "$expected"; then
        alive=1
        break
      fi
    done
    [ "$alive" -eq 0 ] && return 0
    sleep 0.25
  done
  return 1
}

# Each grace phase below is 12 × 250 ms (3 s). The processor unit has two
# ExecStop calls (wrapper, then launch pattern), so both bounded helpers remain
# within its 15 s TimeoutStopSec even when the first tree needs escalation.
# Give ros2 launch the first chance to shut down its node tree cleanly. Waiting
# on the full captured tree preserves a short grace even when the root exits
# before its children finish their own teardown.
for pid in "${roots[@]}"; do
  expected="$(start_for "$pid" 2>/dev/null || true)"
  proc_alive "$pid" "$expected" && kill -TERM "$pid" 2>/dev/null || true
done
wait_tree 12 || true

# Signal only original descendants that survived the root grace period. The
# PID+start-time check prevents signalling an unrelated process after reuse.
for ((i=${#pids[@]}-1; i>=0; i--)); do
  pid="${pids[i]}"
  expected="$(start_for "$pid" 2>/dev/null || true)"
  proc_alive "$pid" "$expected" && kill -TERM "$pid" 2>/dev/null || true
done
wait_tree 12 || true

# Final bounded escalation remains inside this container and process identity
# set. There is no host-level pkill or name-based kill.
for pid in "${pids[@]}"; do
  expected="$(start_for "$pid" 2>/dev/null || true)"
  proc_alive "$pid" "$expected" && kill -KILL "$pid" 2>/dev/null || true
done
