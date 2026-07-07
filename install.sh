#!/usr/bin/env bash
# One-curl provisioner for the fm_ros2 stack. Clones this repo, assembles the
# colcon workspace from the package + external manifests, and installs the macOS
# viewer. Setup only — it does not build or launch; that is run.sh's job, run
# from a real terminal. Designed to be piped:
#
#   curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh | bash
#
# Then, in your terminal:
#   cd fm_ros2 && ./run.sh
#
# install and run are split on purpose: install is non-interactive and safe to
# pipe through curl|bash or run in CI, while run.sh drives an interactive TUI and
# needs a controlling terminal a pipe cannot supply.
#
# Inspect before running (always offer this path):
#   curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh -o install.sh
#   less install.sh && bash install.sh
#
# fm-ros2 is public, so the script is reachable; the package repos are private,
# so the import step assumes git auth (SSH key or a credential helper) and fails
# with a clear "need org access" message without it. Team-only by design.
#
# Flags (pass through the pipe with `bash -s --`):
#   curl ... | bash -s -- --learning    # also import the private learning overlay
#
# The body is wrapped in main() and called on the last line, so a truncated
# curl|bash leaves an incomplete function that never runs.
set -euo pipefail

# Silence the child-process noise the imports spew: git's detached-HEAD advice
# (repeated once per imported repo) and vcstool's pkg_resources deprecation
# warning. Scoped to this process env and inherited by vcs -> git/python children
# — no global git-config mutation.
export GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false
export PYTHONWARNINGS='ignore:pkg_resources is deprecated:UserWarning'

REPO_URL="https://github.com/first-motive/fm-ros2.git"
# Branch/tag to clone (default: the repo's default branch). CI sets FM_REPO_REF to
# the PR branch so the installer tests the ref under review, not the merged main.
REPO_REF="${FM_REPO_REF:-}"
TARGET="fm_ros2"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fm_ros2"

# Step narration lives in the shared fm-tools wheel (fm_tools.tui.banner) so
# install.sh and run.sh share one source of brand colour. `step` draws a numbered
# header block as a rich rule; `item` prints a plain status line beneath it. Reach
# the banner through `uv run --with` (pinned to fm-tools v0.2.0); fall back to a
# plain header when uv is absent. Keep this pin in sync with run.sh.
FM_TOOLS="fm-tools @ git+https://github.com/first-motive/fm-tools@v0.2.0"

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
item() { echo "$1"; }  # status line under a step — inline copy of lib.sh's item

# Run a long command with live feedback. TTY: fork it, spin a frame + elapsed
# seconds on one \r line until it exits, then clear the line — replaying the
# captured output only on failure so a green run stays quiet and a red one is
# still debuggable. Piped (no TTY): run inline so output and errors stream
# straight through, no \r control chars in a log. Returns the command's exit.
# Inline copy of lib.sh's spin — this script runs curl-piped before the clone
# exists, so there is no repo file to source. Keep in sync with lib.sh.
spin() {  # label  cmd...
  local label="$1"; shift
  if [ ! -t 1 ]; then
    "$@"
    return $?
  fi
  local log; log="$(mktemp)" || return 1
  # <&0 forwards our stdin to the async job — a backgrounded command otherwise
  # gets stdin from /dev/null (POSIX), starving `vcs import < manifest`.
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

# Plain narration for secondary paths (uninstall, dependency bootstrap) that sit
# outside the numbered install flow.
say() { echo "==> $1"; }

usage() {
  cat <<'EOF'
install.sh — provision the fm_ros2 workspace (clone + import + env + viewer)

Setup only. To build and launch, run ./run.sh from a terminal afterwards.

Usage: ./install.sh [install|uninstall] [options]

  install      clone + import + set up the selected path and viewer (default)
  uninstall    remove what install added: the private team extras (members —
               First Motive app, fm CLI, fm-ai), the compose stack, and the
               fm-tools lib cache. The workspace clone and pulled images stay.

Path (where the stack runs):
  --native            native ROS2 via pixi + RoboStack (default on macOS/Windows)
  --container         Docker + compose (default on Linux; tests/CI/parity elsewhere)

Viewer:
  --viewer VIEWER     foxglove (default) | rviz | none

Options:
  --learning          also import the private learning overlay (private-overlay.repos)
  --no-desktop        skip the First Motive app in the team-extras step (members)
  --no-ai             skip the fm-ai harness in the team-extras step (members)
  --purge             uninstall only: also drop clean imported repos under src/
                      and external/ (dirty checkouts are kept)
  --dry-run           print what would happen, change nothing (uninstall)
  -h, --help          show this help

The chosen path + viewer are written to .fm_ros2.json at the workspace root, which
run.sh reads to route the launch. Flags override; headless + unflagged falls back
to the OS default path and the foxglove viewer.
EOF
}

# Persist the selected path + viewer to .fm_ros2.json at the workspace root. run.sh
# reads this to route native vs container. Written after a successful setup.
write_profile() {  # path  viewer
  cat > .fm_ros2.json <<EOF
{
  "path": "$1",
  "viewer": "$2"
}
EOF
  item "profile written: .fm_ros2.json (path=$1, viewer=$2)"
}

# Tear down the running stack and clear the fm-tools lib cache. Removes only what
# this bootstrap owns transiently — never the cloned workspace (the user's work)
# or pulled images (shared, re-pullable).
do_uninstall() {  # dry no_desktop no_ai purge
  local dry="$1" no_desktop="${2:-false}" no_ai="${3:-false}" purge="${4:-0}"
  # Forwarded flags for the team-setup uninstall.
  local -a xf=()
  [[ "$no_desktop" == true ]] && xf+=(--no-desktop)
  [[ "$no_ai" == true ]] && xf+=(--no-ai)
  [[ "$purge" == 1 ]] && xf+=(--purge)

  if [[ "$dry" == 1 ]]; then
    say "would remove the private team extras for members (First Motive app, fm CLI, fm-ai)"
    say "would tear down the compose stack (docker compose down)"
    say "would remove the fm-tools lib cache ($CACHE_DIR)"
    [[ "$purge" == 1 ]] && say "would purge clean imported repos under src/ and external/ (dirty ones kept)"
    return 0
  fi

  # Remove the private team extras first (members only; silent for the rest).
  # bash 3.2 (macOS) needs the empty-array guard under set -u.
  maybe_uninstall_team_extras ${xf[@]+"${xf[@]}"}

  if [[ -f docker/compose.yaml ]]; then
    # One overlay is enough to address the compose project for teardown; pick
    # whichever this host has. Best-effort — a stack that is already down is fine.
    local overlay=""
    local o
    for o in docker/compose.macos.yaml docker/compose.linux.yaml; do
      [[ -f "$o" ]] && { overlay="$o"; break; }
    done
    say "tearing down the compose stack ..."
    if [[ -n "$overlay" ]]; then
      docker compose -f docker/compose.yaml -f "$overlay" down 2>/dev/null || true
    else
      docker compose -f docker/compose.yaml down 2>/dev/null || true
    fi
  fi
  say "removing the fm-tools lib cache ($CACHE_DIR) ..."
  rm -rf "$CACHE_DIR"

  # --purge additionally drops the clean imported repos so a reinstall re-imports
  # fresh; dirty checkouts are kept. Without it, the imported src/external stay.
  if [[ "$purge" == 1 ]]; then
    say "purging clean imported repos under src/ and external/ ..."
    purge_workspace_repos
    say "uninstall complete — imported repos purged (dirty ones kept); the fm_ros2 clone and pulled images are left in place."
  else
    say "uninstall complete — workspace clone and pulled images left in place (use --purge to also drop imported repos)."
  fi
}

# vcs (vcstool) drives the imports. Prefer one already on PATH; otherwise install
# it with uv so the `vcs` import-externals.sh shells out to is also available.
ensure_vcs() {
  command -v vcs >/dev/null 2>&1 && return
  if ! command -v uv >/dev/null 2>&1; then
    echo "error: need vcstool or uv on PATH — install uv (https://docs.astral.sh/uv/)" >&2
    exit 1
  fi
  say "installing vcstool via uv ..."
  # vcstool imports pkg_resources, which setuptools 81 dropped — pin setuptools
  # below 81 in the tool env so the import does not crash.
  uv tool install --quiet vcstool --with "setuptools<81"
  # uv drops console scripts into its tool bin dir; make sure it is on PATH for
  # this process and the import-externals.sh child.
  local bin
  bin="$(uv tool dir --bin 2>/dev/null || echo "$HOME/.local/bin")"
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) export PATH="$bin:$PATH" ;;
  esac
}

# Offer the private team stack — the First Motive app and the fm-ai harness — once
# the public workspace is assembled. Everything private lives behind an auth-gated
# setup script in the private .github-private repo; this public installer names no
# private repo beyond fetching that one script through gh, which only resolves for
# an authenticated org member. A machine without gh, without auth, or without org
# access probes false and skips silently, keeping just the public workspace. The
# desktop app runs this same installer to provision the workspace and exports
# FM_DESKTOP_BOOTSTRAP=1 so team-setup skips re-installing the app from under it.
# The org-membership gate: gh present, authenticated, and able to read the
# private config repo. Only a member passes. Non-members skip the team extras.
team_member() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  gh api repos/first-motive/.github-private >/dev/null 2>&1 || return 1
}

# Fetch the auth-gated team-setup.sh over gh's authenticated API and run it with
# the given args (subcommand + flags) — no extra clone, no token handling.
fetch_run_team_setup() {  # args...
  gh api repos/first-motive/.github-private/contents/internal/team-setup.sh \
    --jq '.content' | base64 --decode | bash -s -- "$@"
}

# Offer the private team stack — the First Motive app and the fm-ai harness — once
# the public workspace is assembled. Everything private lives behind the auth-gated
# setup script in the private .github-private repo; this public installer names no
# private repo beyond fetching that one script through gh, which only resolves for
# an authenticated org member. A non-member probes false and skips silently. The
# desktop app runs this same installer to provision the workspace and exports
# FM_DESKTOP_BOOTSTRAP=1 so team-setup skips re-installing the app from under it.
maybe_install_team_extras() {  # forwarded flags...
  team_member || return 0
  step "Team Extras"
  item "org access detected — installing the private team stack:"
  item "  • First Motive (native macOS app)   skip with --no-desktop"
  item "  • fm-ai (AI skills + harness)      skip with --no-ai"
  item "  (non-members never reach this step; the public workspace is already done)"
  # A failure leaves the public workspace intact; team extras are additive.
  if ! fetch_run_team_setup "$@"; then
    item "team-extras step did not complete — the public workspace is ready regardless"
  fi
  return 0
}

# Mirror of the install path for teardown: remove the private team extras through
# the same auth-gated script (uninstall subcommand). Members only; silent for the
# rest. --purge is forwarded so a purge run also drops the private clones.
maybe_uninstall_team_extras() {  # forwarded flags...
  team_member || return 0
  say "org access detected — removing the private team extras (First Motive, fm CLI, fm-ai) ..."
  if ! fetch_run_team_setup uninstall "$@"; then
    say "team-extras removal did not complete — continuing with the rest of the teardown"
  fi
  return 0
}

# --purge: remove the vcs-imported repos under src/ and external/ that are clean,
# so a reinstall re-imports them fresh. A dirty checkout is kept and reported —
# never delete uncommitted work. The fm_ros2 clone itself is left in place.
purge_workspace_repos() {
  local base d kept=0
  for base in src external; do
    [[ -d "$base" ]] || continue
    for d in "$base"/*/; do
      [[ -d "$d.git" ]] || continue
      if [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]]; then
        say "keeping $d — uncommitted changes (not purged)"
        kept=1
      else
        say "purging $d"
        rm -rf "$d"
      fi
    done
  done
  [[ "$kept" == 1 ]] && say "some repos kept due to local changes — commit or stash, then re-run with --purge"
  return 0
}

main() {
  local cmd=install learning=false dry=0 path="" viewer=foxglove
  local no_desktop=false no_ai=false purge=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|uninstall) cmd="$1"; shift ;;
      --native) path=native; shift ;;
      --container) path=container; shift ;;
      --viewer) viewer="${2:?--viewer needs a value}"; shift 2 ;;
      --learning) learning=true; shift ;;
      --no-desktop) no_desktop=true; shift ;;
      --no-ai) no_ai=true; shift ;;
      --purge) purge=1; shift ;;
      --dry-run) dry=1; shift ;;
      -h|--help) usage; return 0 ;;
      *)
        echo "error: unknown argument '$1'" >&2
        usage >&2
        return 1
        ;;
    esac
  done

  case "$viewer" in
    foxglove|rviz|none) ;;
    *) echo "error: --viewer must be foxglove, rviz, or none (got '$viewer')" >&2; return 1 ;;
  esac

  # Default path by OS when unflagged: native is the recommended path on macOS and
  # Windows; Linux stays on the container (native Linux is deferred). The flag wins
  # when set. The interactive fm-tools selector (menu via /dev/tty) is a pending
  # cross-repo component — until it lands, unflagged runs take this OS default.
  if [[ -z "$path" ]]; then
    case "$(uname -s)" in
      Darwin|MINGW*|MSYS*|CYGWIN*) path=native ;;
      *) path=container ;;
    esac
  fi

  # CI self-test hook: arg parse + profile resolution survived the curl|bash pipe —
  # stop before any clone, import, or teardown (covers install AND uninstall). Lets
  # the curl-path test prove the script loads and flag/default routing works, no auth.
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: install.sh parsed under curl|bash (cmd=$cmd, path=$path, viewer=$viewer, no_desktop=$no_desktop, no_ai=$no_ai, purge=$purge)"
    return 0
  fi

  if [[ "$cmd" == uninstall ]]; then
    do_uninstall "$dry" "$no_desktop" "$no_ai" "$purge"
    return $?
  fi

  # Clone on first run, reuse an existing checkout on re-run — never clobber a tree
  # the user already has work in. On reuse, try a fast-forward-only pull to pick up
  # upstream: --ff-only refuses on local commits, divergence, or a dirty tree, so it
  # never resets their work. A refusal is fine — warn and carry on with their tree.
  step "Clone fm-ros2"
  if [[ -f fm-ros2.repos && -d .git ]]; then
    # ./install.sh from inside a checkout: this tree IS the workspace — nothing
    # to clone. No pull either: the running script belongs to this tree, and
    # fetching under it mid-run invites skew. Probe manifest + .git, not -d
    # "$TARGET" — the fm_ros2/ visible at the root here is the workspace
    # metapackage dir, not a clone.
    item "already inside an fm_ros2 checkout — using this tree"
    TARGET="."
  elif [[ -d "$TARGET/.git" ]]; then
    item "reusing existing $TARGET/ — fast-forwarding to upstream ..."
    git -C "$TARGET" pull --ff-only \
      || item "could not fast-forward (local changes or divergence) — keeping your tree"
  elif [[ -e "$TARGET" ]]; then
    # A non-git fm_ros2/ in the way — fail with a plain message, not git's fatal.
    echo "error: ./$TARGET exists but is not a git checkout — move it aside and re-run." >&2
    return 1
  else
    item "cloning into $TARGET/ ..."
    # --quiet: the item line above already narrates this; git's clone progress is
    # the only raw child output in the flow, so silence it for a uniform transcript.
    git clone --quiet --depth 1 ${REPO_REF:+--branch "$REPO_REF"} "$REPO_URL" "$TARGET"
  fi
  cd "$TARGET"

  ensure_vcs

  # Pull the container infra into docker/ and the four public package repos into
  # src/ (manifest paths are root-relative, so import from the root). A failure here
  # is almost always missing org access to the private repos — say so plainly, then
  # exit non-zero.
  step "Import Packages"
  local n; n=$(grep -c 'version:' fm-ros2.repos)
  item "importing $n repos (container infra + packages) — first run clones, sit tight ..."
  if ! spin "importing $n repos" vcs import < fm-ros2.repos; then
    echo "error: failed to import the package repos." >&2
    echo "       The fm-* package repos are private — this needs git access to the" >&2
    echo "       first-motive org (SSH key or a credential helper). Check your auth" >&2
    echo "       and retry." >&2
    return 1
  fi

  # Optional private learning overlay.
  if [[ "$learning" == true ]]; then
    item "importing the learning overlay into src/ ..."
    if ! spin "importing learning overlay" vcs import src < private-overlay.repos; then
      echo "error: failed to import the learning overlay (private-overlay.repos)." >&2
      echo "       This needs access to the private learning repos. Check your auth." >&2
      return 1
    fi
  fi
  # LC_ALL=C: du's size unit honours locale (a comma decimal separator reads as a
  # typo in the transcript) — pin the C locale for a stable "5.5M".
  item "imported — $(LC_ALL=C du -sh src 2>/dev/null | cut -f1) in src/"

  # Vendor the external sources the build consumes into external/.
  step "Vendor Externals"
  ./scripts/install/import-externals.sh

  # Set up the selected path and viewer, then persist the profile. run.sh reads
  # .fm_ros2.json to route the launch; both paths share the imported workspace above.
  if [[ "$path" == native ]]; then
    # Native: bootstrap pixi, solve the RoboStack env, install the viewer. native.sh
    # installs foxglove itself (per platform) and leaves rviz/none to the pixi env.
    step "Native Env"
    item "pixi + RoboStack (viewer: $viewer) ..."
    ./scripts/install/native.sh --viewer "$viewer"
  else
    # Container: the fm-app image carries ROS + rviz, so only foxglove needs a host
    # install. rviz renders in the container over VNC (scripts/run/rviz-vnc.sh) and
    # none installs nothing — so the host viewer install is foxglove-only.
    step "Install Viewer"
    if [[ "$viewer" == foxglove ]]; then
      item "Foxglove Studio (macOS; skipped on Linux) ..."
      ./scripts/install/install-foxglove.sh
    else
      item "viewer '$viewer' needs no host install (renders in the container)"
    fi
  fi

  write_profile "$path" "$viewer"

  # Team members with org access get the private extras layered on top; everyone
  # else stops at the provisioned public workspace above. Forward the skip flags.
  local -a extra_flags=()
  [[ "$no_desktop" == true ]] && extra_flags+=(--no-desktop)
  [[ "$no_ai" == true ]] && extra_flags+=(--no-ai)
  # bash 3.2 (macOS) errors on "${arr[@]}" for an empty array under set -u — guard
  # the expansion so an unflagged run passes no args instead of tripping unbound.
  maybe_install_team_extras ${extra_flags[@]+"${extra_flags[@]}"}

  # Setup ends here. run.sh builds and launches the interactive TUI, which needs a
  # controlling terminal — so it is the user's next step, not a curl|bash handoff.
  step "Ready"
  item "workspace provisioned at $PWD (path=$path, viewer=$viewer)"
  # In-tree re-run: the user is already in the workspace, so drop the cd hint.
  local next="cd $TARGET && ./run.sh"
  if [[ "$TARGET" == "." ]]; then next="./run.sh"; fi
  item "next: $next    (build + launch, from your terminal)"
}

main "$@"
