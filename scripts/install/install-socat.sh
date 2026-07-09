#!/usr/bin/env bash
# Ensure socat is installed on macOS. Idempotent: a no-op when it is already on
# PATH. Installs via the Homebrew formula when missing; if Homebrew is absent it
# points at the manual route.
#
# socat is the host-side relay for the PHONE camera on the container run path:
# scripts/run/camera-bridge.sh runs `socat TCP-LISTEN:8090 -> <phone_ip>:8081`, and
# the vision node inside the container reads that stream over host.docker.internal.
# The Mac's built-in camera goes through mac_camera_bridge.py (uv) and needs no
# socat, so a missing socat fails ONLY the phone source — silently, since the relay
# runs detached under the full-screen TUI. Vision teleop runs in the container on
# macOS even when the workspace was provisioned on the native profile, so this is
# installed on macOS regardless of the persisted install path.
#
# Best-effort like the Foxglove installer: every failure warns and returns 0 so the
# bootstrap never aborts on it — the mac-camera source still works without socat.
set -euo pipefail

usage() {
  cat <<'EOF'
install-socat.sh — ensure socat is installed on macOS (idempotent)

Installs via the Homebrew formula when missing; warns and returns 0 on any
failure (only the phone-camera source needs it). No-op off macOS.

Usage: ./scripts/install/install-socat.sh [-h]

  -h, --help   show this help
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  if [ "$(uname -s)" != "Darwin" ]; then
    return 0
  fi

  if command -v socat >/dev/null 2>&1; then
    echo "socat already installed"
    return 0
  fi

  echo "socat not found, installing (phone-camera relay for vision teleop)..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "WARNING: Homebrew not found — skipping socat." >&2
    echo "         Install it (https://brew.sh), then: brew install socat" >&2
    echo "         Without it, only the phone-camera source is unavailable; the Mac" >&2
    echo "         built-in camera still works." >&2
    return 0
  fi

  if brew install socat; then
    echo "socat installed"
  else
    echo "WARNING: socat install failed — continuing without it." >&2
    echo "         Retry later: brew install socat (needed only for the phone camera)" >&2
  fi

  # Best-effort: succeed regardless so the bootstrap never aborts on socat.
  return 0
}

main "$@"
