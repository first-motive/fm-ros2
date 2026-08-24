#!/usr/bin/env bash
# Clone the learning overlay into src/ for the loop job. The overlay's repos are
# private and this repo is public, so their slugs arrive through the
# FM_OVERLAY_REPOS Actions variable rather than a tracked manifest — the
# repo-hygiene scan refuses a private slug in any tracked file. The App token
# the import-packages action minted is already wired into git via insteadOf.
#
# Usage: FM_OVERLAY_REPOS="<slug> <slug>" ./scripts/ci/import-overlay.sh
set -euo pipefail

: "${FM_OVERLAY_REPOS:?set FM_OVERLAY_REPOS to the space-separated overlay repo slugs}"

mkdir -p src
for slug in $FM_OVERLAY_REPOS; do
  # Snake the checkout dir to match the package name, as import-packages does.
  dir="src/${slug//-/_}"
  if [ -d "$dir" ]; then
    echo "present  $dir"
    continue
  fi
  echo "cloning  $slug -> $dir"
  git clone --depth 1 "https://github.com/first-motive/${slug}.git" "$dir"
done
