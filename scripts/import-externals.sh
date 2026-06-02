#!/usr/bin/env bash
# Vendor external dependencies into src/external/ from external.repos.
# Pins are placeholders (see external.repos) — failures are loud, never silent.
# src/external/ is gitignored; this is a local working copy, not committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v vcs >/dev/null 2>&1; then
  echo "ERROR: vcstool not found. Run inside the container, or: pip install vcstool" >&2
  exit 1
fi

mkdir -p src/external
# Keep colcon out of the vendored tree: externals are sources to read or build
# selectively, not part of the workspace build. COLCON_IGNORE skips the subtree.
touch src/external/COLCON_IGNORE
echo "==> Importing externals into src/external/ ..."
vcs import src/external < external.repos
echo "==> Current versions:"
vcs custom src/external --git --args rev-parse --short HEAD 2>/dev/null || vcs status src/external
echo "==> Done. Reminder: pins in external.repos are placeholders — pin real tags."
