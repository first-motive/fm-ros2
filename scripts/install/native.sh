#!/usr/bin/env bash
# Native ROS2 Humble install path via pixi + RoboStack (macOS / Windows).
# Bootstraps pixi, materializes the workspace env from pixi.lock, and installs the
# selected viewer. rviz ships inside the pixi env (ros-humble-desktop), so it needs
# no host install; foxglove is a separate GUI app installed per platform.
#
# Called by install.sh on the native profile; also runnable directly:
#   ./scripts/install/native.sh --viewer foxglove
#
# rosdep does not work inside a pixi env — add ROS deps with `pixi add ros-humble-<pkg>`.
set -euo pipefail

# Reach the repo root (pixi.toml lives there) — this script sits in scripts/install/.
cd "$(dirname "$0")/../.."

VIEWER=foxglove

usage() {
  cat <<'EOF'
native.sh — install the native ROS2 env via pixi + RoboStack (macOS / Windows)

Bootstraps pixi, solves the workspace env from pixi.lock, installs the viewer.

Usage: ./scripts/install/native.sh [--viewer foxglove|rviz|none] [-h]

  --viewer   foxglove (default) | rviz | none
             rviz ships inside the pixi env; foxglove is a per-platform GUI app;
             none installs no viewer.
  -h, --help show this help
EOF
}

# Ensure pixi is on PATH; install via the official script when missing. The
# installer drops the binary in $HOME/.pixi/bin — add it for this process.
ensure_pixi() {
  command -v pixi >/dev/null 2>&1 && return
  if [ -x "$HOME/.pixi/bin/pixi" ]; then
    export PATH="$HOME/.pixi/bin:$PATH"
    return
  fi
  echo "installing pixi ..."
  # Pin the installed pixi to a known-good version (reproducible, matches the
  # convention of pinning fm-tools / fm-docker); the installer reads PIXI_VERSION.
  curl -fsSL --proto '=https' --proto-redir '=https' https://pixi.sh/install.sh \
    | PIXI_VERSION="${PIXI_VERSION:-v0.72.0}" bash
  export PATH="$HOME/.pixi/bin:$PATH"
  command -v pixi >/dev/null 2>&1 \
    || { echo "error: pixi install failed — see https://pixi.sh" >&2; exit 1; }
}

# Install the foxglove GUI per platform. rviz + none need nothing — rviz is in the
# pixi env, none installs no viewer. Best-effort: a viewer failure never aborts.
install_viewer() {
  case "$VIEWER" in
    rviz|none) return 0 ;;
    foxglove) ;;
    *) echo "error: unknown viewer '$VIEWER'" >&2; return 1 ;;
  esac
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # Windows via Git Bash — foxglove_bridge has no win-64 RoboStack build, so
      # foxglove can't connect to the native env; install the Studio app anyway.
      if command -v winget >/dev/null 2>&1; then
        winget install --id Foxglove.Studio -e --silent --accept-package-agreements --accept-source-agreements \
          || echo "WARNING: Foxglove winget install failed — get it from https://foxglove.dev/download" >&2
      else
        echo "WARNING: winget not found — install Foxglove from https://foxglove.dev/download" >&2
      fi
      ;;
    *)
      # macOS (Homebrew cask) and any other host reuse the shared installer, which
      # self-skips off macOS. Guard so a viewer failure never aborts the install.
      ./scripts/install/install-foxglove.sh \
        || echo "WARNING: Foxglove install failed — continuing without it." >&2
      ;;
  esac
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --viewer) VIEWER="${2:?--viewer needs a value}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
    esac
  done

  # CI self-test hook: arg parse survived — stop before any pixi install or
  # network. Lets the smoke test prove the script loads without a real env solve.
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: native.sh parsed, viewer=$VIEWER"
    return 0
  fi

  ensure_pixi
  echo "solving the native ROS2 env (pixi install) ..."
  pixi install
  install_viewer
  echo "native env ready — run.sh builds and launches from here."
}

main "$@"
