#!/usr/bin/env bash
# One-curl bootstrap for the fm_ros2 stack. Clones this repo, assembles the
# colcon workspace from the package + external manifests, then hands off to
# run.sh. Designed to be piped:
#
#   curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh | bash
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
set -euo pipefail

REPO_URL="https://github.com/first-motive/fm-ros2.git"
TARGET="fm-ros2"

LEARNING=false
NO_RUN=false
RUN_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --learning) LEARNING=true; shift ;;
    --no-run) NO_RUN=true; shift ;;
    --macos|--linux) RUN_ARGS+=("$1"); shift ;;  # forwarded to run.sh
    *)
      echo "error: unknown argument '$1'" >&2
      echo "usage: install.sh [--macos|--linux] [--learning] [--no-run]" >&2
      exit 1
      ;;
  esac
done

say() { echo "==> $1"; }

# Clone on first run, reuse an existing checkout on re-run — never clobber a tree
# the user already has work in.
if [[ -d "$TARGET/.git" ]]; then
  say "reusing existing $TARGET/"
else
  say "cloning fm-ros2 into $TARGET/ ..."
  git clone --depth 1 "$REPO_URL" "$TARGET"
fi
cd "$TARGET"

# vcs (vcstool) drives the imports. Prefer one already on PATH; otherwise install
# it with uv so the `vcs` import-externals.sh shells out to is also available.
ensure_vcs() {
  command -v vcs >/dev/null 2>&1 && return
  if ! command -v uv >/dev/null 2>&1; then
    echo "error: need vcstool or uv on PATH — install uv (https://docs.astral.sh/uv/)" >&2
    exit 1
  fi
  say "installing vcstool via uv ..."
  uv tool install --quiet vcstool
  # uv drops console scripts into its tool bin dir; make sure it is on PATH for
  # this process and the import-externals.sh child.
  local bin
  bin="$(uv tool dir --bin 2>/dev/null || echo "$HOME/.local/bin")"
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) export PATH="$bin:$PATH" ;;
  esac
}
ensure_vcs

# Pull the four public package repos into src/. A failure here is almost always
# missing org access to the private repos — say so plainly, then exit non-zero.
say "importing package repos into src/ ..."
if ! vcs import src < fm-ros2.repos; then
  echo "error: failed to import the package repos." >&2
  echo "       The fm-* package repos are private — this needs git access to the" >&2
  echo "       first-motive org (SSH key or a credential helper). Check your auth" >&2
  echo "       and retry." >&2
  exit 1
fi

# Optional private learning overlay (fm-data + fm-policy + fm-learning).
if [[ "$LEARNING" == true ]]; then
  say "importing learning overlay into src/ ..."
  if ! vcs import src < fm-learning.repos; then
    echo "error: failed to import the learning overlay (fm-learning.repos)." >&2
    echo "       This needs access to the private learning repos. Check your auth." >&2
    exit 1
  fi
fi

# Vendor the external sources the build consumes into external/.
say "vendoring externals into external/ ..."
./scripts/import-externals.sh

if [[ "$NO_RUN" == true ]]; then
  say "import complete — stopping before run.sh (--no-run)."
  exit 0
fi

# Hand off to the front door: detect OS, build, open the launcher.
say "launching run.sh ..."
exec ./run.sh ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}
