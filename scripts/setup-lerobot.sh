#!/usr/bin/env bash
# Create the lerobot env: an editable install from the vendored source in
# src/external/lerobot. fm_ros2 owns its robotics deps, so lerobot is installed
# host-native (like the mujoco env on the M5) rather than in the container.
#
# Order: run scripts/import-externals.sh first — this needs the vendored source.
# Idempotent: skips if ~/.venvs/lerobot already exists.
#   --force  wipe and reinstall editable. Use it to migrate an old PyPI lerobot
#            venv (uv pip install lerobot) to this editable source install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VENV="$HOME/.venvs/lerobot"
SRC="src/external/lerobot"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: uv not found. Install uv first (see README)." >&2
  exit 1
fi

# The editable install points at the vendored source — fail loud if it is absent.
if [ ! -d "$SRC" ]; then
  echo "ERROR: $SRC missing. Run scripts/import-externals.sh first." >&2
  exit 1
fi

if [ -d "$VENV" ]; then
  if [ "$FORCE" -eq 1 ]; then
    echo "==> --force: removing existing venv at $VENV ..."
    rm -rf "$VENV"
  else
    echo "==> lerobot venv exists at $VENV — skipping (use --force to recreate)."
    exit 0
  fi
fi

echo "==> Creating lerobot venv at $VENV (python 3.11) ..."
uv venv "$VENV" --python 3.11

echo "==> Installing lerobot (editable) from $SRC ..."
uv pip install --python "$VENV/bin/python" -e "$SRC"

echo "==> Done. lerobot installed editable from $SRC."
echo "==> Activate: source $VENV/bin/activate"
