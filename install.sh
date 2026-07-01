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
item() { echo "$1"; }  # status line under a step — one place to restyle later

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
install.sh — provision the fm_ros2 workspace (clone + import + viewer)

Setup only. To build and launch, run ./run.sh from a terminal afterwards.

Usage: ./install.sh [install|uninstall] [options]

  install      clone + import + install the macOS viewer (default)
  uninstall    tear down the compose stack and clear the fm-tools lib cache
               (the workspace clone and pulled images are left in place)

Options:
  --learning          also import the private learning overlay (fm-learning.repos)
  --dry-run           print what would happen, change nothing (uninstall)
  -h, --help          show this help
EOF
}

# Tear down the running stack and clear the fm-tools lib cache. Removes only what
# this bootstrap owns transiently — never the cloned workspace (the user's work)
# or pulled images (shared, re-pullable).
do_uninstall() {
  local dry="$1"
  if [[ "$dry" == 1 ]]; then
    say "would tear down the compose stack (docker compose down)"
    say "would remove the fm-tools lib cache ($CACHE_DIR)"
    return 0
  fi
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
  say "uninstall complete — workspace clone and pulled images left in place."
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

main() {
  local cmd=install learning=false dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|uninstall) cmd="$1"; shift ;;
      --learning) learning=true; shift ;;
      --dry-run) dry=1; shift ;;
      -h|--help) usage; return 0 ;;
      *)
        echo "error: unknown argument '$1'" >&2
        usage >&2
        return 1
        ;;
    esac
  done

  if [[ "$cmd" == uninstall ]]; then
    do_uninstall "$dry"
    return $?
  fi

  # CI self-test hook: arg parse survived the curl|bash pipe — stop before any
  # clone or import. Lets the curl-path test prove the script loads, no auth.
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: install.sh parsed under curl|bash"
    return 0
  fi

  # Clone on first run, reuse an existing checkout on re-run — never clobber a tree
  # the user already has work in. On reuse, try a fast-forward-only pull to pick up
  # upstream: --ff-only refuses on local commits, divergence, or a dirty tree, so it
  # never resets their work. A refusal is fine — warn and carry on with their tree.
  step "Clone fm-ros2"
  if [[ -d "$TARGET/.git" ]]; then
    item "reusing existing $TARGET/ — fast-forwarding to upstream ..."
    git -C "$TARGET" pull --ff-only \
      || item "could not fast-forward (local changes or divergence) — keeping your tree"
  else
    item "cloning into $TARGET/ ..."
    git clone --depth 1 "$REPO_URL" "$TARGET"
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

  # Optional private learning overlay (fm-data + fm-policy + fm-learning).
  if [[ "$learning" == true ]]; then
    item "importing the learning overlay into src/ ..."
    if ! spin "importing learning overlay" vcs import src < fm-learning.repos; then
      echo "error: failed to import the learning overlay (fm-learning.repos)." >&2
      echo "       This needs access to the private learning repos. Check your auth." >&2
      return 1
    fi
  fi
  item "imported — $(du -sh src 2>/dev/null | cut -f1) in src/"

  # Vendor the external sources the build consumes into external/.
  step "Vendor Externals"
  ./scripts/import-externals.sh

  # Install the macOS robot viewer so run.sh can auto-open it pre-connected to the
  # bridge. Best-effort and macOS-only (the script self-skips on Linux) — a failure
  # never blocks provisioning. No container exec here, so no terminal is needed.
  step "Install Viewer"
  item "Foxglove Studio (macOS; skipped on Linux) ..."
  ./scripts/install-foxglove.sh

  # Setup ends here. run.sh builds and launches the interactive TUI, which needs a
  # controlling terminal — so it is the user's next step, not a curl|bash handoff.
  step "Ready"
  item "workspace provisioned at $PWD"
  item "next: cd $TARGET && ./run.sh    (build + launch, from your terminal)"
}

main "$@"
