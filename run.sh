#!/usr/bin/env bash
# Front door for the fm_ros2 stack — a thin dispatcher. It reads the install
# profile (.fm_ros2.json) to route the launch to the native path (pixi/RoboStack)
# or the container path (Docker + compose), then hands off all remaining args.
#
#   ./run.sh                 # route by the persisted profile (or OS default)
#   ./run.sh --native        # force the native path
#   ./run.sh --container     # force the container path
#   ./run.sh --no-foxglove   # (native) skip auto-opening Foxglove Studio
#   ./run.sh --macos|--linux # (container) force the compose overlay
#
# Native is the recommended path on macOS + Windows; the container is the default
# on Linux and the parity/tests path elsewhere. Windows has no container path
# (OrbStack is macOS-only) — it points WSL2 users at the Linux path instead.
#
# Wrapped so a truncated curl|bash never half-runs.
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
run.sh — dispatch the fm_ros2 launch to the native or container path

Usage: ./run.sh [--native|--container] [path-specific args...] [-h|--help]

  --native      force the native path (pixi/RoboStack); passes on --no-foxglove
  --container   force the container path (Docker); passes on --macos/--linux/--no-foxglove
  -h, --help    show this help

With no path flag, the profile in .fm_ros2.json decides; absent that, the OS
default applies (macOS/Windows -> native, Linux -> container). Remaining args are
forwarded to the chosen path — see ./scripts/run/native.sh -h or container.sh -h.
EOF
}

# Detect Windows (Git Bash / MSYS). The container path can't run there.
is_windows() {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac
}

# The OS default when no flag and no profile: native on macOS/Windows, container
# on Linux (native Linux is deferred).
os_default_path() {
  case "$(uname -s)" in
    Darwin|MINGW*|MSYS*|CYGWIN*) echo native ;;
    *) echo container ;;
  esac
}

main() {
  local forced=""
  # Peel a leading path flag; everything else forwards to the path script.
  if [[ "${1:-}" == --native ]]; then forced=native; shift
  elif [[ "${1:-}" == --container ]]; then forced=container; shift
  elif [[ "${1:-}" == -h || "${1:-}" == --help ]]; then usage; return 0
  fi

  # Resolve the path: forced flag > persisted profile > OS default.
  local path="$forced"
  if [[ -z "$path" && -f .fm_ros2.json ]]; then
    path=$(sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      .fm_ros2.json | head -1)
  fi
  [[ -z "$path" ]] && path="$(os_default_path)"

  # CI self-test hook: the dispatcher parsed and resolved a path over the curl|bash
  # pipe — stop before exec'ing a path script (which the piped one-liner has not
  # checked out). Proves the front door loads without the rest of the tree.
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: run.sh dispatch resolved (path=$path)"
    return 0
  fi

  case "$path" in
    native)
      exec ./scripts/run/native.sh "$@"
      ;;
    container)
      if is_windows; then
        echo "error: the container path is not supported on Windows — OrbStack is" >&2
        echo "       macOS-only. Run the native path (./run.sh --native), or use the" >&2
        echo "       Linux container path from a WSL2 shell instead." >&2
        return 1
      fi
      exec ./scripts/run/container.sh "$@"
      ;;
    *)
      echo "error: unknown path '$path' in .fm_ros2.json (want native|container)" >&2
      return 1
      ;;
  esac
}

main "$@"
