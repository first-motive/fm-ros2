#!/usr/bin/env bash
# Create the lerobot env: an editable install from the vendored source in
# external/lerobot. fm_ros2 owns its robotics deps, so lerobot is installed
# host-native (like the mujoco env on the M5) rather than in the container.
#
# Order: run scripts/import-externals.sh first — this needs the vendored source.
# Idempotent: skips if ~/.venvs/lerobot already exists.
#   --force  wipe and reinstall editable. Use it to migrate an old PyPI lerobot
#            venv (uv pip install lerobot) to this editable source install.
set -euo pipefail

usage() {
  cat <<'EOF'
setup-lerobot.sh — create the lerobot env: editable install from external/lerobot

Run scripts/import-externals.sh first (this needs the vendored source).
Idempotent: skips if ~/.venvs/lerobot already exists.

Usage: ./scripts/setup-lerobot.sh [--force] [-h]

  --force      wipe and reinstall editable (migrate an old PyPI lerobot venv)
  -h, --help   show this help
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$ROOT"

  local VENV="$HOME/.venvs/lerobot"
  local SRC="external/lerobot"

  local FORCE=0
  [[ "${1:-}" == "--force" ]] && FORCE=1

  if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv not found. Install uv first (see README)." >&2
    return 1
  fi

  # The editable install points at the vendored source — fail loud if it is absent.
  if [ ! -d "$SRC" ]; then
    echo "ERROR: $SRC missing. Run scripts/import-externals.sh first." >&2
    return 1
  fi

  if [ -d "$VENV" ]; then
    if [ "$FORCE" -eq 1 ]; then
      echo "==> --force: removing existing venv at $VENV ..."
      rm -rf "$VENV"
    else
      echo "==> lerobot venv exists at $VENV — skipping (use --force to recreate)."
      return 0
    fi
  fi

  echo "==> Creating lerobot venv at $VENV (python 3.12) ..."
  uv venv "$VENV" --python 3.12

  echo "==> Installing lerobot (editable, dataset + feetech extras) from $SRC ..."
  uv pip install --python "$VENV/bin/python" -e "${SRC}[dataset,feetech]"

  echo "==> Done. lerobot installed editable from $SRC."
  echo "==> Activate: source $VENV/bin/activate"
}

main "$@"
