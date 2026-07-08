#!/usr/bin/env bash
# Host-side camera relay manager for vision teleop (macOS).
#
# The operator picks the camera in the TUI, which runs INSIDE the container and so
# cannot start the relay the vision node reads from (:8090 on the Mac host). The TUI
# instead persists the choice to the shared .fm_tui.json; this watches that file and
# keeps :8090 fed by the chosen source:
#
#   camera = mac    -> mac_camera_bridge.py  (Mac AVFoundation camera) on :8090
#   camera = phone  -> socat :8090 -> <phone_ip>[:8081]   (the container can't reach
#                      the LAN directly, so the phone stream is relayed via the host)
#
# The vision camera reader reconnects with backoff (fm_teleop_vision capture.py), so a
# relay that comes up shortly after the launch still connects — no strict ordering.
#
# Lifetime is bound to the fm container: it exits (dropping its relay) once the
# container stops, and a fresh run replaces any prior manager via the pidfile.
#
#   camera-bridge.sh <config-path> [container-id]
set -uo pipefail

CONFIG="${1:?usage: camera-bridge.sh <config-path> [container-id]}"
CONTAINER="${2:-}"
PORT=8090
HERE="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="${TMPDIR:-/tmp}/fm-camera-bridge.pid"

log() { printf 'camera-bridge: %s\n' "$*" >&2; }

# --- singleton: replace any prior manager (its EXIT trap drops that relay) --------
if [[ -f "$PIDFILE" ]]; then
  old="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$old" && "$old" != "$$" ]] && kill -0 "$old" 2>/dev/null; then
    kill "$old" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$old" 2>/dev/null || break; sleep 0.2; done
  fi
fi
echo "$$" >"$PIDFILE"

relay_pid=""  # the socat / bridge process we started, if any
relay_key=""  # "mac" or "phone <ip>" — what relay_pid currently serves

# Drop any listener on :PORT. On this host that is only ever the camera relay, so
# clearing it (a stale bridge/socat, ours or a manual one) before we bind is safe.
free_port() {
  local pids
  pids="$(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
}

stop_relay() {
  [[ -n "$relay_pid" ]] && kill "$relay_pid" 2>/dev/null || true
  relay_pid=""
  relay_key=""
}

cleanup() {
  stop_relay
  free_port
  [[ "$(cat "$PIDFILE" 2>/dev/null || true)" == "$$" ]] && rm -f "$PIDFILE"
  exit 0
}
trap cleanup INT TERM EXIT

# Read the desired camera from the shared config (sed, like container.sh's viewer
# read). Echoes "mac", "phone <ip>", or nothing (no choice yet / phone without IP).
desired_from_config() {
  local cam ip
  cam="$(sed -n 's/.*"camera"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" 2>/dev/null | head -1)"
  ip="$(sed -n 's/.*"phone_ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" 2>/dev/null | head -1)"
  case "$cam" in
    mac) echo "mac" ;;
    phone) [[ -n "$ip" ]] && echo "phone $ip" ;;
  esac
}

start_relay() { # $1 = "mac" | "phone <ip>"
  stop_relay
  free_port
  if [[ "$1" == mac ]]; then
    log "mac camera bridge -> :$PORT"
    uv run --with opencv-python-headless python "$HERE/mac_camera_bridge.py" \
      --port "$PORT" >/dev/null 2>&1 &
  else # phone <ip>
    local target="${1#phone }"
    [[ "$target" == *:* ]] || target="$target:8081"
    log "phone relay :$PORT -> $target"
    socat "TCP-LISTEN:$PORT,reuseaddr,fork" "TCP:$target" >/dev/null 2>&1 &
  fi
  relay_pid=$!
  relay_key="$1"
}

container_up() {
  [[ -z "$CONTAINER" ]] ||
    docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true
}

log "watching $CONFIG (relay on :$PORT)"
while :; do
  desired="$(desired_from_config)"
  if [[ -n "$desired" && "$desired" != "$relay_key" ]]; then
    start_relay "$desired"
  elif [[ -n "$relay_pid" ]] && ! kill -0 "$relay_pid" 2>/dev/null; then
    log "relay exited; restarting"
    relay_key="" # force a restart on the next tick
  fi
  container_up || {
    log "fm container stopped; exiting"
    break
  }
  sleep 2
done
