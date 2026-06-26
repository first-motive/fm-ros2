#!/usr/bin/env bash
# One-curl bootstrap for the fm_ros2 stack. Clones this repo, assembles the
# colcon workspace from the package + external manifests, then hands off to
# run.sh. Designed to be piped:
#
#   curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh | bash
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
#   curl ... | bash -s -- --linux       # force the Linux overlay on run.sh
#   curl ... | bash -s -- --macos       # force the macOS overlay on run.sh
#   curl ... | bash -s -- --learning    # also import the private learning overlay
#   curl ... | bash -s -- --no-run      # clone + import only, stop before run.sh (CI)
#
# The body is wrapped in main() and called on the last line, so a truncated
# curl|bash leaves an incomplete function that never runs.
set -euo pipefail

REPO_URL="https://github.com/first-motive/fm-ros2.git"
TARGET="fm-ros2"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fm-ros2"

say() { echo "==> $1"; }

usage() {
  cat <<'EOF'
install.sh — bootstrap the fm_ros2 workspace (clone + import + run)

Usage: ./install.sh [install|uninstall] [options]

  install      clone + import + run (default)
  uninstall    tear down the compose stack and clear the fm-tools lib cache
               (the workspace clone and pulled images are left in place)

Options:
  --macos | --linux   force the overlay handed to run.sh (default: auto-detect)
  --learning          also import the private learning overlay (fm-learning.repos)
  --no-run            clone + import only, stop before run.sh (CI)
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
  local cmd=install learning=false no_run=false dry=0
  local -a run_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|uninstall) cmd="$1"; shift ;;
      --learning) learning=true; shift ;;
      --no-run) no_run=true; shift ;;
      --dry-run) dry=1; shift ;;
      --macos|--linux) run_args+=("$1"); shift ;;  # forwarded to run.sh
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

  # Clone on first run, reuse an existing checkout on re-run — never clobber a tree
  # the user already has work in. On reuse, try a fast-forward-only pull to pick up
  # upstream: --ff-only refuses on local commits, divergence, or a dirty tree, so it
  # never resets their work. A refusal is fine — warn and carry on with their tree.
  if [[ -d "$TARGET/.git" ]]; then
    say "reusing existing $TARGET/ — fast-forwarding to upstream ..."
    git -C "$TARGET" pull --ff-only \
      || say "could not fast-forward (local changes or divergence) — keeping your tree"
  else
    say "cloning fm-ros2 into $TARGET/ ..."
    git clone --depth 1 "$REPO_URL" "$TARGET"
  fi
  cd "$TARGET"

  ensure_vcs

  # Pull the container infra into docker/ and the four public package repos into
  # src/ (manifest paths are root-relative, so import from the root). A failure here
  # is almost always missing org access to the private repos — say so plainly, then
  # exit non-zero.
  say "importing container infra + package repos ..."
  if ! vcs import < fm-ros2.repos; then
    echo "error: failed to import the package repos." >&2
    echo "       The fm-* package repos are private — this needs git access to the" >&2
    echo "       first-motive org (SSH key or a credential helper). Check your auth" >&2
    echo "       and retry." >&2
    return 1
  fi

  # Optional private learning overlay (fm-data + fm-policy + fm-learning).
  if [[ "$learning" == true ]]; then
    say "importing learning overlay into src/ ..."
    if ! vcs import src < fm-learning.repos; then
      echo "error: failed to import the learning overlay (fm-learning.repos)." >&2
      echo "       This needs access to the private learning repos. Check your auth." >&2
      return 1
    fi
  fi

  # Vendor the external sources the build consumes into external/.
  say "vendoring externals into external/ ..."
  ./scripts/import-externals.sh

  if [[ "$no_run" == true ]]; then
    say "import complete — stopping before run.sh (--no-run)."
    return 0
  fi

  # Install the macOS robot viewer so run.sh can auto-open it pre-connected to the
  # bridge. Best-effort and macOS-only (the script self-skips on Linux) — a failure
  # never blocks the bootstrap.
  say "ensuring Foxglove Studio (macOS viewer) ..."
  ./scripts/install-foxglove.sh

  # Hand off to the front door: detect OS, build, open the launcher.
  say "launching run.sh ..."
  exec ./run.sh ${run_args[@]+"${run_args[@]}"}
}

main "$@"
