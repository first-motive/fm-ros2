#!/usr/bin/env bash
# Container run path for the fm_ros2 stack, dispatched from ./run.sh. Brings the
# dev container up and opens the fm_tui launcher — an arrow-key menu that walks
# action -> robot -> variant
# (-> backend for sim/teleop) and dispatches the launch. Wired actions: robot
# description, simulation, and teleop; autonomous is stubbed.
#
# It auto-detects the host OS to pick the compose overlay (macOS / Linux) and
# reuses the shared-stack pattern from scripts/run/view-robot.sh: `up -d`, build the
# workspace, then `exec` the launcher through the image entrypoint so ROS + the
# workspace overlay are sourced.
#
#   ./run.sh                  # auto-detect overlay, build, open the launcher
#   ./run.sh --linux          # force the Linux overlay (GPU / hardware)
#   ./run.sh --macos          # force the macOS overlay (OrbStack, sim only)
#   ./run.sh --foxglove       # also open Foxglove Studio (macOS; 3D arm is in the panel)
#   ./run.sh --no-webgui      # skip auto-opening the fm_viewer panel (macOS, viewer=panel)
#
# Every run rebuilds the workspace (colcon) before opening the launcher, so source
# and console-script changes are always picked up. The build is incremental, so a
# warm tree is quick. The package repos and externals are imported first, once:
#   vcs import < fm-ros2.repos       # pull docker/ infra + the package repos into src/
#   ./scripts/install/import-externals.sh    # vendor robot sources into external/
#
# scripts/run/view-robot.sh, scripts/run/sim.sh, and scripts/run/teleop.sh coexist as the
# direct, scriptable paths to the same launches — use them when you want one
# capability without the menu.
#
# The body is wrapped in main() and called on the last line, so a truncated
# curl|bash never half-runs.
set -euo pipefail

# Reach the repo root — this script now lives two levels down in scripts/internal/.
cd "$(dirname "$0")/../.."

# Shared build-tree guard (foreign-toolchain tree detection + clear). Sourced from
# the repo root, where we just cd'd. See the preflight in main().
# shellcheck source=scripts/internal/lib-buildtree.sh
source scripts/internal/lib-buildtree.sh

# The compose project this checkout's stack runs under (#135).
# shellcheck source=scripts/internal/lib-compose.sh
source scripts/internal/lib-compose.sh

# The repo's own shared library, for the org gate and the auth-gated team-setup
# fetch (team_member / fetch_run_team_setup). install.sh owns the same two through
# this file, and the run path needs them to import an overlay a launch is missing.
# Its narration helpers are redefined below, which is deliberate: the container
# path draws its own step banners.
#
# Sourced from the clone, never fetched: this path always has a checkout, so the
# gate it runs is the one git handed the user and reviewed here. Only install.sh's
# curl-pipe path fetches this file, and it fetches itself over the same ref, so
# that trust chain is unchanged by the two functions living here.
# shellcheck source=../../lib.sh disable=SC1091
source lib.sh

# Step narration lives in the shared fm-tools wheel (fm_tools.tui.banner) so
# run.sh and the TUIs share one source of brand colour. `step` draws a numbered
# header block as a rich rule; `item` prints a plain status line beneath it. The
# first steps run on the host before the container exists, so reach the banner
# through `uv run --with`. Fall back to a plain header when uv is absent. lib.sh
# comes from the same pinned tag for the host checks (fm_detect_os).
# fm-render:begin fm-tools-pin sha256:5de9c0a921c441407f1aea8b6e32f37ca9d3f654d1116c636f0a7136da03b7d2 — rendered by the First Motive render plane — edit the upstream source, not this file
# fm-tools owns both shared bootstrap pieces: lib.sh (fetched raw, before any
# clone exists) and the fm_tools wheel (the shared TUI banner). Both come from
# one pinned release tag — the single reuse home. Re-pin in the render plane,
# never in a consumer. A host that needs only one of the two still carries both,
# so the pin reads the same everywhere it appears; the disables below declare
# that, rather than splitting the pin into two blocks that can disagree.
# shellcheck disable=SC2034
FM_TOOLS_RAW="https://raw.githubusercontent.com/first-motive/fm-tools/v0.4.1"
# shellcheck disable=SC2034
FM_TOOLS="fm-tools @ git+https://github.com/first-motive/fm-tools@v0.4.1"
# fm-render:end fm-tools-pin
# fm-render:begin fm-docker-pin sha256:532190583135a4c86953f451232f5e222ebd1750e65438ea252618f0c3b44cd2 — rendered by the First Motive render plane — edit the upstream source, not this file
# The container runtime install is delegated to fm-docker, fetched from one
# pinned release tag. Re-pin in the render plane, never in a consumer.
# shellcheck disable=SC2034
FM_DOCKER_RAW="https://raw.githubusercontent.com/first-motive/fm-docker/v0.1.3"
# fm-render:end fm-docker-pin
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fm_ros2"

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

Usage: ./run.sh [--macos|--linux] [--foxglove] [--no-webgui] [-h|--help]

  --macos | --linux   force the compose overlay (default: auto-detect)
  --foxglove          also open Foxglove Studio (the 3D arm is already in the panel)
  --no-webgui         skip auto-opening the fm_viewer panel (macOS, viewer=panel)
  -h, --help          show this help
EOF
}

# Open the host views once a view is actually launched from the TUI — not while the
# menu is still open. The bridge runs inside the container and binds 8765 only on
# launch, but the macOS overlay publishes 8765 to the host at `up -d`, so the host
# port answers before the bridge is up — a false signal. So poll the port FROM INSIDE
# the container, where a listener exists only when foxglove_bridge is running, and
# open the moment it binds. The watcher is forked before the launcher `exec` so it
# outlives this shell, and bounded so a quit (or a non-bridge view) leaves nothing
# polling. macOS GUI path only — skipped on Linux/CI/headless; never blocks the
# launcher. Opens two surfaces: the fm_viewer panel (a local web page — 3D arm,
# plots, recordings, plus the vision panes when a vision session feeds them) when
# the panel viewer is chosen, and, opt-in via --foxglove, Foxglove Studio. The panel
# needs no app install (default browser); Foxglove needs the desktop app. Reads
# OVERLAY / OPEN_FOXGLOVE / OPEN_WEBGUI / COMPOSE / SERVICE / FM_WS set by main
# (dynamic scope).
open_views_when_ready() {
  [[ "$OPEN_FOXGLOVE" == true || "$OPEN_WEBGUI" == true ]] || return 0
  [[ "$OVERLAY" == docker/compose.macos.yaml ]] || return 0
  command -v open >/dev/null 2>&1 || return 0
  local fg_url="foxglove://open?ds=foxglove-websocket&ds.url=ws://localhost:8765"
  # The panel page ships in the fm_viewer package — the colcon overlay install copy
  # (mounted at $FM_WS/install on the host) first, then the source tree as a fallback.
  local gui_path="" p
  for p in \
    "$FM_WS/install/fm_viewer/share/fm_viewer/webgui/index.html" \
    "$FM_WS/src/fm_app/fm_viewer/webgui/index.html"; do
    [[ -f "$p" ]] && { gui_path="$p"; break; }
  done
  local open_fg=false open_gui=false
  if [[ "$OPEN_FOXGLOVE" == true ]]; then
    if [[ -d "/Applications/Foxglove.app" ]]; then
      open_fg=true
    else
      item "Foxglove Studio not installed — run ./install.sh or: brew install --cask foxglove"
    fi
  fi
  if [[ "$OPEN_WEBGUI" == true && -n "$gui_path" ]]; then
    open_gui=true
  fi
  [[ "$open_fg" == true || "$open_gui" == true ]] || return 0
  (
    # ~10 min budget (300 × 2s) — enough to navigate the menu and launch, then
    # give up so a quit without launching never leaves this polling forever.
    for ((i = 0; i < 300; i++)); do
      if "${COMPOSE[@]}" exec -T "$SERVICE" \
           bash -c 'exec 3<>/dev/tcp/127.0.0.1/8765' 2>/dev/null; then
        if [[ "$open_gui" == true ]]; then open "file://$gui_path" 2>/dev/null || true; fi
        if [[ "$open_fg" == true ]]; then open "$fg_url" 2>/dev/null || true; fi
        exit 0
      fi
      sleep 2
    done
  ) &
  disown 2>/dev/null || true
  if [[ "$open_gui" == true ]]; then item "fm_viewer panel: opens when a view starts (ws://localhost:8765)"; fi
  if [[ "$open_fg" == true ]]; then item "Foxglove Studio (3D arm): opens when a view starts"; fi
}

# Serve the macOS rviz view over VNC. rviz has no native macOS build and cannot
# render over XQuartz's indirect GLX on Apple Silicon, so it renders inside the
# container against Xvfb + software GL (llvmpipe); scripts/internal/rviz-vnc.sh starts that
# display and a noVNC bridge, and this opens the host browser at the container's
# address. OrbStack routes the host to the container IP, so no published port is
# needed. The launcher starts rviz itself on the shared DISPLAY (:99, set on its
# exec) when the operator picks a robot description. macOS GUI path; reads COMPOSE
# / SERVICE set by main (dynamic scope).
open_rviz_vnc() {
  "${COMPOSE[@]}" exec -d "$SERVICE" bash /ws/scripts/internal/rviz-vnc.sh
  local ip url i
  ip=$("${COMPOSE[@]}" exec -T "$SERVICE" hostname -I 2>/dev/null | awk '{print $1}')
  url="http://${ip:-localhost}:6080/vnc.html?autoconnect=1&resize=scale"
  # Wait for noVNC to answer on the host before opening — up to ~30s, which covers
  # a one-time in-container dep install on an image built before the VNC bits.
  for ((i = 0; i < 60; i++)); do
    curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null && break
    sleep 0.5
  done
  command -v open >/dev/null 2>&1 && open "$url" 2>/dev/null || true
  item "rviz in browser: ${url}"
  item "(blank until you pick a robot description — rviz starts on selection)"
}

# Bring the compose stack up, and turn a Foxglove-port bind failure into an
# actionable message. The macOS overlay publishes 8765 to the host; if a
# non-container process already holds it — classically a foxglove_bridge left by a
# crashed native run — docker's `up` fails with a cryptic "port is already
# allocated". We let docker be the source of truth (no guessing who owns the port —
# an earlier version pattern-matched lsof command names and mis-flagged docker's
# own `com.docker.*` helper, whose name lsof truncates), stream its output, and
# only when it fails on 8765 append the hint. Reads COMPOSE set by main.
compose_up() {
  local log rc
  log=$(mktemp)
  set +e
  "${COMPOSE[@]}" up -d --remove-orphans 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    if grep -qiE '8765|address already in use|port is already allocated' "$log"; then
      echo "" >&2
      echo "hint: port 8765 could not be bound — usually a foxglove_bridge left by a" >&2
      echo "      crashed native run. Find who holds it, then stop it and re-run:" >&2
      echo "        lsof -nP -iTCP:8765 -sTCP:LISTEN     # see who holds it" >&2
      echo "        pkill -f foxglove_bridge             # if that's the culprit" >&2
    fi
    rm -f "$log"
    exit "$rc"
  fi
  # Keyed on compose actually saying it created or recreated the container, so a
  # warm re-run that reuses one leaves the fabric alone.
  if fm_compose_created_container "$log"; then
    fm_compose_restart_bridge
  fi
  rm -f "$log"
}

# Guarantee /ws is a LIVE bind mount before anything execs into it. `up -d` reports a
# pre-existing container as "Running" and moves on — but a container left over from an
# earlier run can come back up with its workspace bind DETACHED: classically after a
# host reboot, an OrbStack restart, or the laptop sleeping. The container is "running",
# yet /ws is gone, so the first `docker compose exec` (which lands in working_dir /ws)
# dies with the cryptic:
#   chdir to cwd ("/ws") set in config.json failed: no such file or directory
# `up -d` will not fix it: the compose config is unchanged, so it reuses the broken
# container instead of recreating it. So we probe here. The probe runs from `-w /` (a
# directory that always exists, so the probe itself never trips the chdir) and checks
# for a file only the mounted workspace carries (run.sh). If it is missing, the bind is
# stale/wrong — force ONE clean recreate, which re-establishes the mount from the
# current FM_WS, then re-probe. Reads COMPOSE / SERVICE / FM_WS set by main.
ensure_ws_live() {
  local attempt
  for attempt in 1 2; do
    if "${COMPOSE[@]}" exec -T -w / "$SERVICE" test -f /ws/run.sh 2>/dev/null; then
      return 0
    fi
    [ "$attempt" -eq 1 ] || break
    item "workspace mount /ws is not live in the container — recreating it"
    item "  (usually a container left running with a stale bind after a reboot/sleep)"
    "${COMPOSE[@]}" up -d --force-recreate "$SERVICE" >/dev/null 2>&1 || true
  done
  echo "error: /ws is not a live mount of $FM_WS inside the '$SERVICE' container, even" >&2
  echo "       after a recreate. Clear the container and re-run:" >&2
  echo "         ${COMPOSE[*]} down && ./run.sh --container" >&2
  exit 1
}

main() {
  local transport_overlay
  # OVERLAY / OPEN_FOXGLOVE / OPEN_WEBGUI / COMPOSE / SERVICE / HOST / FM_WS stay global
  # (no `local`) so the forked open_views_when_ready watcher sees them.
  OVERLAY=""
  OPEN_FOXGLOVE=false # the 3D arm now lives in the web GUI; opt in with --foxglove to also open it
  OPEN_WEBGUI=true    # auto-open the fm_viewer panel on macOS when viewer=panel; --no-webgui disables
  RVIZ_VNC=false      # set when the persisted viewer is rviz on the macOS overlay

  # Parse before loading lib so --help works offline, with no network fetch.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --macos) OVERLAY=docker/compose.macos.yaml; shift ;;
      --linux) OVERLAY=docker/compose.linux.yaml; shift ;;
      --foxglove) OPEN_FOXGLOVE=true; shift ;;
      --no-webgui) OPEN_WEBGUI=false; shift ;;
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
  # FM_HOST_OS carries the same fact into the container so the launcher can warn
  # when rviz is chosen on macOS (no X display there).
  case "$OVERLAY" in
    *macos*) HOST="macOS"; FM_HOST_OS=macos ;;
    *linux*) HOST="Linux"; FM_HOST_OS=linux ;;
  esac
  export FM_HOST_OS

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
  # The launcher persists its viewer preference here. FM_WS mounts to /ws in the
  # container, so the same file is $FM_WS/.fm_tui.json on the host and
  # /ws/.fm_tui.json inside — the one path that survives a container teardown.
  export FM_TUI_CONFIG=/ws/.fm_tui.json

  # The transport the container speaks, resolved on the HOST from this machine's
  # identity card and handed down. Resolving it inside the container instead
  # would read a card the container does not have, and the container would come
  # up on a different middleware than the host's bridge is routing — a stack that
  # starts, publishes, and is heard by nobody.
  #
  # Only what a container can act on crosses the boundary, and which values those
  # are depends on the overlay — fm_compose_transport owns that decision for every
  # role that starts a container. The dds-lan profile's FastDDS XML lives in the
  # host's $HOME and is not mounted, which is the other reason the container path
  # wants zenoh: under it there is nothing host-specific left to carry.
  # shellcheck source=../env/comms.sh disable=SC1091
  source scripts/env/comms.sh
  fm_compose_transport "$OVERLAY"
  item "comms profile: $FM_COMMS_PROFILE (RMW ${RMW_IMPLEMENTATION:-the image default})"
  if [[ -n "${FM_CYCLONEDDS_XML:-}" ]]; then
    item "  DDS on the host's loopback island ($FM_CYCLONEDDS_XML)"
  fi

  COMPOSE=(docker compose -p "$(fm_compose_project sim)"
    -f docker/compose.yaml -f "$OVERLAY")
  transport_overlay="$(fm_compose_transport_overlay "$PWD")" || return 1
  [[ -n "$transport_overlay" ]] && COMPOSE+=(-f "$transport_overlay")
  SERVICE=fm

  # The panel auto-open is viewer-driven: only the `panel` viewer opens the fm_viewer
  # web page; every other viewer leaves OPEN_WEBGUI off. Read the persisted preference
  # from the host side of the mount. rviz needs no host-view watcher and on macOS
  # renders over VNC (started once the container is up — open_rviz_vnc needs a running
  # container to exec into). foxglove/none open no panel; Foxglove is opt-in via
  # --foxglove. Default (no file) is foxglove, so the panel stays closed unless chosen.
  local viewer=foxglove
  if [[ -f "$FM_WS/.fm_tui.json" ]]; then
    viewer=$(sed -n 's/.*"viewer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$FM_WS/.fm_tui.json" | head -1)
    viewer="${viewer:-foxglove}"
  fi
  case "$viewer" in
    rviz)
      OPEN_FOXGLOVE=false
      OPEN_WEBGUI=false
      [[ "$OVERLAY" == docker/compose.macos.yaml ]] && RVIZ_VNC=true ;;
    panel) ;;                 # OPEN_WEBGUI (default on, --no-webgui off) opens the panel
    *) OPEN_WEBGUI=false ;;    # foxglove/none: no panel page
  esac

  # macOS runs on OrbStack as the Docker provider. Install it if missing, then make
  # sure the daemon is up — both idempotent, and each prints its own status bullet.
  step "${HOST} Container"

  # Preflight the build tree before the container build reuses it. A build/install
  # tree baked by the native (pixi) toolchain (prefix not under /ws) can't be
  # reused by the container build — colcon aborts on the first package ("The build
  # time path ... doesn't exist"). Clear the regenerable artifacts so the build
  # below starts clean; they are gitignored and rebuilt. (The Foxglove-port
  # collision is handled by compose_up, which reads docker's own bind error rather
  # than guessing the port owner.)
  if fm_buildtree_is_foreign /ws; then
    item "native build tree detected (baked $(fm_buildtree_prefix)) — clearing build/ install/ log/"
    item "  gitignored + regenerable; the container build below rebuilds them clean"
    fm_buildtree_clear
  fi

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
  # up -d with --remove-orphans (reaps containers from a stale compose project that
  # would otherwise linger and hold the published port), and a clear hint when the
  # published Foxglove port can't bind.
  compose_up
  # A reused container can be "Running" with its /ws bind detached (post-reboot/sleep) —
  # heal it before step 3 execs into working_dir /ws and dies on the chdir.
  ensure_ws_live
  item "Container up"

  # The loop's record and process stages run packages that live in the private
  # overlay (fm_data), and the public manifest names no private repo. A member's
  # rig gets them at install time — but a rig provisioned by the appliance flash,
  # or a checkout that predates the overlay, reaches its first launch without them
  # and fails deep inside the loop with `Package 'fm_data_dataset' not found`
  # (fm-ros2#147). Import them here, behind the same org gate install.sh uses.
  #
  # Never fatal: the stack itself does not need the overlay, and a non-member's
  # workspace is a legitimate thing to launch.
  #
  # The import runs a script fetched from the private org through gh — the same
  # thing install.sh does, now reachable from a launch. Two bounds on that: the
  # org gate has to pass first, and it only fires when src/fm_data is absent, so a
  # provisioned workspace never reaches it twice. FM_NO_OVERLAY_IMPORT=1 declines
  # it outright, for a host that should fetch nothing at launch.
  step "Workspace Packages"
  if [[ -d src/fm_data ]]; then
    item "data packages present"
  elif [[ -n "${FM_NO_OVERLAY_IMPORT:-}" ]]; then
    item "data packages absent — import declined (FM_NO_OVERLAY_IMPORT)"
  elif team_member; then
    item "data packages absent — importing the private overlay (org access detected)"
    # --no-desktop --no-ai: the overlay import is the only half wanted here; the
    # app and the AI harness are an install-time concern, not a launch-time one.
    if fetch_run_team_setup --no-desktop --no-ai; then
      warn_kebab_checkouts "$PWD"
    else
      item "overlay import did not complete — the loop's record and process stages will not run"
    fi
  else
    item "data packages absent and no org access — the stack runs, the record and process stages do not"
  fi

  # The published image can lag its Dockerfile, on the apt side first. fm-app's
  # Dockerfile installs the MoveIt and MuJoCo runtime the sim stack needs, but a host
  # that pulled the published tag before those lines landed has an image without
  # them — and the failure is a build error in fm_control plus a mujoco backend that
  # cannot exist (fm-ros2#147), an hour into a fresh provision. Install whatever is
  # missing, apt cache and all.
  #
  # rosbag2-storage-mcap is the one the loop dies on: without it the recorder
  # comes up, subscribes, accepts the start marker and then fails to open a bag
  # ("Could not load/open plugin with storage id 'mcap'"), so no episode is ever
  # finalized and the loop reports the index as empty (gate 3.5).
  # Idempotent and self-neutralising: once the republished image carries them, the
  # check costs one `dpkg-query` and installs nothing.
  step "Stack Dependencies"
  fm_compose_heal_stack_deps "${COMPOSE[@]}"
  item "stack apt dependencies present"

  step "Vision Dependencies"
  "${COMPOSE[@]}" exec -T "$SERVICE" bash -c '
    need=""
    python3 -c "import mediapipe" 2>/dev/null || need="$need mediapipe==0.10.14"
    python3 -c "import trimesh"   2>/dev/null || need="$need trimesh==4.12.2"
    python3 -c "import collada"   2>/dev/null || need="$need pycollada==0.9.3"
    [ -n "$need" ] && { echo "installing python deps:$need"; pip install --no-cache-dir $need; }
    v=/ws/src/fm_teleop/fm_teleop_vision
    if [ -f "$v/scripts/download_model.sh" ] && ! ls "$v"/models/*.task >/dev/null 2>&1; then
      echo "fetching MediaPipe models (~30 MB) ..."; bash "$v/scripts/download_model.sh"
    fi
  '
  # Guard the upgrade path: if an earlier build cached fm_description's mesh conversion as
  # skipped (built before the converter deps existed), the visual meshes are missing and an
  # incremental build will not regenerate them. Force one clean reconfigure in that case — a
  # no-op on a fresh tree, where nothing is built yet and the main build generates them.
  "${COMPOSE[@]}" exec -T "$SERVICE" /ros_entrypoint.sh bash -c '
    stl=/ws/install/fm_description/share/fm_description/openarm_meshes/assets/robot/openarm_v2.0/meshes/arm/visual/base_link.stl
    if [ ! -s "$stl" ] && [ -d /ws/build/fm_description ]; then
      colcon build --packages-select fm_description --cmake-clean-cache
    fi
  '
  item "vision deps + models present"

  step "Build Workspace"
  # Route through the entrypoint so ROS is sourced; build from /ws (the compose
  # working_dir). Incremental, so a warm tree returns fast. -T disables TTY
  # allocation: the build is non-interactive, and `docker compose exec` otherwise
  # demands a terminal on stdin and aborts when there is none (e.g. a piped run).
  #
  # Through the verb, not a bare `colcon build`: the packages nested inside a repo
  # that ships a metapackage at its root need naming as extra base paths, and a
  # bare build silently omits them (fm-ros2#147).
  "${COMPOSE[@]}" exec -T "$SERVICE" /ros_entrypoint.sh ./scripts/run/build.sh

  step "Launcher"
  # The web GUI now carries everything: camera, controls, AND the 3D arm (self-rendered
  # with three.js over the same bridge). Foxglove is no longer required; pass --foxglove
  # to also open Foxglove Studio, or import foxglove/arm_3d.json there.
  item "Vision control GUI (camera + 3D arm + engage/reset/record): opens in your browser"
  item "teardown: ${COMPOSE[*]} down"
  open_views_when_ready
  # When rviz is the macOS default, bring up the in-container display + noVNC
  # bridge and open the browser. The launcher then renders rviz on that display.
  local launch_env=(-e COLORTERM -e TERM -e FM_TUI_CONFIG -e FM_HOST_OS)
  if [[ "$RVIZ_VNC" == true ]]; then
    open_rviz_vnc
    # rviz launches on the Xvfb display with software GL (llvmpipe).
    launch_env+=(-e DISPLAY=:99 -e LIBGL_ALWAYS_SOFTWARE=1)
  fi
  # `exec` skips the image ENTRYPOINT, so route through it to source ROS + overlay.
  # The launcher is an ament_python console_script (installed under lib/fm_tui/, not
  # on PATH), so reach it via `ros2 run`, not by name.
  # Forward the host terminal's colour capability (COLORTERM/TERM) into the
  # container; without it the TUI falls back to 16-colour and the brand palette
  # quantises to grey/white. -e VAR passes the host value through when set.
  # FM_TUI_CONFIG / FM_HOST_OS carry the viewer preference path and host OS into
  # the launcher.
  exec "${COMPOSE[@]}" exec \
    "${launch_env[@]}" \
    "$SERVICE" /ros_entrypoint.sh ros2 run fm_tui fm_tui_launcher
}

main "$@"
