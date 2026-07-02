#!/usr/bin/env bash
# Serve a headless rviz over VNC — the macOS rviz path. rviz has no native macOS
# build, and its Ogre GL backend cannot render over XQuartz's indirect GLX on
# Apple Silicon (X connects, GL fails). So rviz renders inside the container
# against a virtual X server (Xvfb) with software GL (llvmpipe), and x11vnc +
# noVNC export that framebuffer over HTTP. The host opens a browser at the
# container's address; run.sh handles that and sets DISPLAY for the rviz launch.
#
# This runs INSIDE the container — run.sh invokes it via `docker compose exec -d`
# before it hands the terminal to the launcher. It only starts the display and
# the VNC bridge; the launcher starts rviz itself (on DISPLAY below) when the
# operator selects a robot description.
#
# Idempotent: it kills any stale servers and restarts them. The deps are baked
# into the fm-app image; a runtime apt install covers an image built before they
# were added, so the path works on a not-yet-rebuilt image too.
set -euo pipefail

DISPLAY_NUM="${FM_RVIZ_DISPLAY:-:99}"
VNC_PORT="${FM_RVIZ_VNC_PORT:-6080}"
GEOMETRY="${FM_RVIZ_GEOMETRY:-1280x800x24}"
NOVNC_DIR=/usr/share/novnc

ensure_deps() {
  if command -v Xvfb >/dev/null 2>&1 \
    && command -v x11vnc >/dev/null 2>&1 \
    && command -v websockify >/dev/null 2>&1 \
    && [ -f "$NOVNC_DIR/vnc.html" ]; then
    return 0
  fi
  echo "rviz-vnc: installing viewer deps (one-time; rebuild the image to skip)..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    xvfb x11vnc websockify novnc libgl1-mesa-dri libglu1-mesa >/dev/null
}

# Wait for a TCP port on localhost to accept a connection (bounded).
wait_for_port() {
  local port="$1" tries="${2:-20}"
  for ((i = 0; i < tries; i++)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      exec 3>&-
      return 0
    fi
    sleep 0.5
  done
  return 1
}

main() {
  ensure_deps

  # Restart cleanly so a re-run never stacks servers on the same display/port.
  pkill -f "Xvfb ${DISPLAY_NUM}" 2>/dev/null || true
  pkill -f "x11vnc.*${DISPLAY_NUM}" 2>/dev/null || true
  pkill -f "websockify.*${VNC_PORT}" 2>/dev/null || true
  sleep 1

  # Virtual X with GLX so rviz's Ogre backend finds a software (llvmpipe) visual.
  # setsid detaches each server from this exec session so they outlive it.
  setsid Xvfb "${DISPLAY_NUM}" -screen 0 "${GEOMETRY}" +extension GLX +render -noreset \
    >/tmp/fm-xvfb.log 2>&1 &
  # Wait for the X socket before the VNC server attaches to the display.
  for ((i = 0; i < 20; i++)); do
    [ -e "/tmp/.X11-unix/X${DISPLAY_NUM#:}" ] && break
    sleep 0.5
  done

  setsid x11vnc -display "${DISPLAY_NUM}" -forever -shared -nopw -rfbport 5900 \
    -o /tmp/fm-x11vnc.log >/dev/null 2>&1 &
  setsid websockify --web "${NOVNC_DIR}" "${VNC_PORT}" localhost:5900 \
    >/tmp/fm-novnc.log 2>&1 &

  if wait_for_port "${VNC_PORT}"; then
    echo "rviz-vnc: serving noVNC on :${VNC_PORT} (display ${DISPLAY_NUM})"
  else
    echo "rviz-vnc: WARNING noVNC did not bind :${VNC_PORT} — see /tmp/fm-novnc.log" >&2
    return 1
  fi
}

main "$@"
