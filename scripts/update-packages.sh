#!/usr/bin/env bash
# Sync the seven First Motive package repos into src/ from fm-ros2.repos.
# Imports any missing repo, then pulls every repo to its tracked ref (main).
# src/ is gitignored; each src/fm-* is its own clone with its own remote —
# commit and push package changes from inside that repo, not from here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v vcs >/dev/null 2>&1; then
  echo "ERROR: vcstool not found. Run inside the container, or: pip install vcstool" >&2
  exit 1
fi

mkdir -p src

# vcs import clones repos missing from src/ and leaves existing clones untouched.
echo "==> Importing missing package repos into src/ ..."
vcs import src < fm-ros2.repos

# vcs pull fast-forwards every clone already in src/ to its tracked ref.
echo "==> Pulling all package repos to latest ..."
vcs pull src

echo "==> Status:"
vcs status src
