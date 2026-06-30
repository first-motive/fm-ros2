#!/usr/bin/env bash
# Single front door for the fm_ros2 stack. Brings the dev container up and opens
# the fm_tui launcher — an arrow-key menu that walks action -> robot -> variant
# (-> backend for sim/teleop) and dispatches the launch. Wired actions: robot
# description, simulation, and teleop; autonomous is stubbed.
#
# It auto-detects the host OS to pick the compose overlay (macOS / Linux) and
# reuses the shared-stack pattern from scripts/view-robot.sh: `up -d`, build the
# workspace, then `exec` the launcher through the image entrypoint so ROS + the
# workspace overlay are sourced.
#
#   ./run.sh                  # auto-detect overlay, build, open the launcher
#   ./run.sh --linux          # force the Linux overlay (GPU / hardware)
#   ./run.sh --macos          # force the macOS overlay (OrbStack, sim only)
#   ./run.sh --no-foxglove    # skip auto-opening Foxglove Studio (macOS)
#
# Every run rebuilds the workspace (colcon) before opening the launcher, so source
# and console-script changes are always picked up. The build is incremental, so a
# warm tree is quick. The package repos and externals are imported first, once:
#   vcs import < fm-ros2.repos       # pull docker/ infra + the package repos into src/
#   ./scripts/import-externals.sh    # vendor robot sources into external/
#
# scripts/view-robot.sh, scripts/sim.sh, and scripts/teleop.sh coexist as the
# direct, scriptable paths to the same launches — use them when you want one
# capability without the menu.
#
# The body is wrapped in main() and called on the last line, so a truncated
# curl|bash never half-runs.
set -euo pipefail

cd "$(dirname "$0")"

# Step narration lives in the shared fm-tools wheel (fm_tools.tui.banner) so
# run.sh and the TUIs share one source of brand colour. `step` draws a numbered
# header block as a rich rule; `item` prints a plain status line beneath it. The
# first steps run on the host before the container exists, so reach the banner
# through `uv run --with` (pinned to fm-tools v0.2.0). Fall back to a plain
# header when uv is absent.
FM_TOOLS="fm-tools @ git+https://github.com/first-motive/fm-tools@v0.2.0"
# lib.sh is owned by fm-tools; fetch it from the same pinned tag for the host
# checks (fm_detect_os). The container runtime is delegated to fm-docker v0.1.0.
FM_TOOLS_RAW="https://raw.githubusercontent.com/first-motive/fm-tools/v0.2.0"
FM_DOCKER_RAW="https://raw.githubusercontent.com/first-motive/fm-docker/v0.1.0"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fm-ros2"

# Load the shared bootstrap library (fm-tools lib.sh) for fm_detect_os. Reuse a
# cached fetch, else fetch from the pinned fm-tools tag and cache it.
load_lib() {
  local cached="$CACHE_DIR/lib.sh"
  if [ ! -f "$cached" ]; then
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"  # lib.sh is sourced from here; keep the cache user-only
    local tmp="$cached.tmp.$$"
    curl -fsSL --proto '=https' --proto-redir '=https' "$FM_TOOLS_RAW/lib.sh" -o "$tmp" \
      || { rm -f "$tmp"; echo "error: failed to fetch lib.sh from fm-tools" >&2; exit 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "error: empty lib.sh download" >&2; exit 1; }
    mv "$tmp" "$cached"
  fi
  # shellcheck source=/dev/null
  source "$cached"
}

STEP=0
step() {  # title  [role]
  STEP=$((STEP + 1))
  if command -v uv >/dev/null 2>&1; then
    # -W ignore::RuntimeWarning silences runpy's harmless "already in sys.modules"
    # note: fm_tools.tui re-exports banner, so `-m` sees it pre-imported.
    uv run --quiet --no-project --with "$FM_TOOLS" \
      python3 -W ignore::RuntimeWarning -m fm_tools.tui.banner "$STEP" "$1" "${2:-step}"
  else
    echo "== $STEP. $1 =="
  fi
}
item() { echo "$1"; }  # status line under a step — one place to restyle later

usage() {
  cat <<'EOF'
run.sh — bring the fm_ros2 stack up and open the fm_tui launcher

Usage: ./run.sh [--macos|--linux] [--no-foxglove] [-h|--help]

  --macos | --linux   force the compose overlay (default: auto-detect)
  --no-foxglove       skip auto-opening Foxglove Studio (macOS)
  -h, --help          show this help
EOF
}

# Open Foxglove Studio on the host once a view is actually launched from the TUI —
# not while the menu is still open. The bridge runs inside the container and binds
# 8765 only on launch, but the macOS overlay publishes 8765 to the host at `up -d`,
# so the host port answers before the bridge is up — a false signal. So poll the
# port FROM INSIDE the container, where a listener exists only when foxglove_bridge
# is running, and open Studio (pre-connected) the moment it binds. The watcher is
# forked before the launcher `exec` so it outlives this shell, and bounded so a
# quit (or a non-Foxglove view) leaves nothing polling. macOS GUI path only —
# skipped on Linux/CI/headless and with --no-foxglove; never blocks the launcher.
# Reads OVERLAY / OPEN_FOXGLOVE / COMPOSE / SERVICE set by main (dynamic scope).
open_foxglove_when_ready() {
  [[ "$OPEN_FOXGLOVE" == true ]] || return 0
  [[ "$OVERLAY" == docker/compose.macos.yaml ]] || return 0
  command -v open >/dev/null 2>&1 || return 0
  if [[ ! -d "/Applications/Foxglove.app" ]]; then
    item "Foxglove Studio not installed — run ./install.sh or: brew install --cask foxglove"
    return 0
  fi
  local url="foxglove://open?ds=foxglove-websocket&ds.url=ws://localhost:8765"
  (
    # ~10 min budget (300 × 2s) — enough to navigate the menu and launch, then
    # give up so a quit without launching never leaves this polling forever.
    for ((i = 0; i < 300; i++)); do
      if "${COMPOSE[@]}" exec -T "$SERVICE" \
           bash -c 'exec 3<>/dev/tcp/127.0.0.1/8765' 2>/dev/null; then
        open "$url" 2>/dev/null || true
        exit 0
      fi
      sleep 2
    done
  ) &
  disown 2>/dev/null || true
  item "Foxglove Studio: opens when a view starts (ws://localhost:8765)"
}

main() {
  # OVERLAY / OPEN_FOXGLOVE / COMPOSE / SERVICE / HOST stay global (no `local`) so
  # the forked open_foxglove_when_ready watcher sees them.
  OVERLAY=""
  OPEN_FOXGLOVE=true  # auto-open Foxglove Studio on macOS; --no-foxglove disables

  # Parse before loading lib so --help works offline, with no network fetch.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --macos) OVERLAY=docker/compose.macos.yaml; shift ;;
      --linux) OVERLAY=docker/compose.linux.yaml; shift ;;
      --no-foxglove) OPEN_FOXGLOVE=false; shift ;;
      -h|--help) usage; return 0 ;;
      *)
        echo "error: unknown argument '$1'" >&2
        usage >&2
        return 1
        ;;
    esac
  done

  load_lib

  # Auto-detect the overlay from the host OS when not forced by a flag. fm_detect_os
  # (from the fm-tools lib) echoes macos|linux.
  if [[ -z "$OVERLAY" ]]; then
    case "$(fm_detect_os)" in
      macos) OVERLAY=docker/compose.macos.yaml ;;
      linux) OVERLAY=docker/compose.linux.yaml ;;
      *) echo "error: unsupported host OS — pass --macos or --linux" >&2; return 1 ;;
    esac
  fi

  # Friendly host label, derived from whichever overlay won (flag or auto-detect).
  case "$OVERLAY" in
    *macos*) HOST="macOS" ;;
    *linux*) HOST="Linux" ;;
  esac

  # CI self-test hook: lib loaded + overlay resolved — stop before any import,
  # container, or build. Lets the curl-path test exercise the piped lib fetch.
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: lib loaded, host=$HOST"
    return 0
  fi

  step "Detect OS"
  item "${HOST} detected"

  # fm-ros2 owns no image — it consumes the published fm-app full-stack image and
  # sources the compose overlays from fm-docker (imported into docker/ on first run
  # via fm-ros2.repos). FM_IMAGE/FM_WS feed the generic fm-docker compose base.
  if [[ ! -d docker ]]; then
    vcs import < fm-ros2.repos
  fi
  export FM_IMAGE="${FM_IMAGE:-ghcr.io/first-motive/fm-app:humble}"
  export FM_WS="$PWD"
  COMPOSE=(docker compose -f docker/compose.yaml -f "$OVERLAY")
  SERVICE=fm

  # macOS runs on OrbStack as the Docker provider. Install it if missing, then make
  # sure the daemon is up — both idempotent, and each prints its own status bullet.
  step "${HOST} Container"
  if [[ "$OVERLAY" == docker/compose.macos.yaml ]]; then
    # Delegate the container runtime (OrbStack install + daemon start) to fm-docker
    # — no vendored helper here. docker/ is imported above, so use the imported
    # installer; fall back to the pinned fm-docker tag when it is absent.
    if [[ -f docker/install.sh ]]; then
      bash docker/install.sh --no-pull
    else
      curl -fsSL --proto '=https' --proto-redir '=https' "$FM_DOCKER_RAW/install.sh" | bash -s -- --no-pull
    fi
  fi
  "${COMPOSE[@]}" up -d
  item "Container up"

  step "Build Workspace"
  # Route through the entrypoint so ROS is sourced; build from /ws (the compose
  # working_dir). Incremental, so a warm tree returns fast. -T disables TTY
  # allocation: the build is non-interactive, and `docker compose exec` otherwise
  # demands a terminal on stdin and aborts when there is none (e.g. a piped run).
  "${COMPOSE[@]}" exec -T "$SERVICE" /ros_entrypoint.sh colcon build --symlink-install

  step "Launcher"
  item "Foxglove Studio: ws://localhost:8765"
  item "teardown: ${COMPOSE[*]} down"
  open_foxglove_when_ready
  # `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
  # The launcher is an ament_python console_script (installed under lib/fm_tui/, not
  # on PATH), so reach it via `ros2 run`, not by name.
  # Forward the host terminal's colour capability (COLORTERM/TERM) into the
  # container; without it the TUI falls back to 16-colour and the brand palette
  # quantises to grey/white. -e VAR passes the host value through when set.
  exec "${COMPOSE[@]}" exec -e COLORTERM -e TERM "$SERVICE" /ros_entrypoint.sh ros2 run fm_tui fm_tui_launcher
}

main "$@"
