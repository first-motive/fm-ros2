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
echo "==> Importing externals into src/external/ ..."
vcs import src/external < external.repos

# Selective workspace build: externals are sources to read or file-vendor, NOT to
# build — except openarm_description, a real ament_cmake package whose xacro needs
# $(find openarm_description) + package:// to resolve, so it must join the build.
# Drop a COLCON_IGNORE into every imported external EXCEPT openarm_description.
BUILD_DIR="openarm_description"
# Drop any blanket top-level ignore from an earlier import — markers are per-dir now.
rm -f src/external/COLCON_IGNORE
echo "==> Marking externals COLCON_IGNORE (keeping ${BUILD_DIR} in the build) ..."
for dir in src/external/*/; do
  name="$(basename "$dir")"
  if [ "$name" = "$BUILD_DIR" ]; then
    rm -f "$dir/COLCON_IGNORE"  # ensure it builds even on re-import
    continue
  fi
  touch "$dir/COLCON_IGNORE"
done

# openarm_description must exist post-import or the arm view cannot build — fail loud.
if [ ! -d "src/external/${BUILD_DIR}" ]; then
  echo "ERROR: src/external/${BUILD_DIR} missing after import — OpenArm view cannot build." >&2
  echo "       Check the openarm_description entry in external.repos and re-run." >&2
  exit 1
fi

echo "==> Current versions:"
vcs custom src/external --git --args rev-parse --short HEAD 2>/dev/null || vcs status src/external
echo "==> Done. ${BUILD_DIR} joins the workspace build; other externals are COLCON_IGNORE'd."
echo "==> Reminder: pins in external.repos are placeholders — pin real tags."
