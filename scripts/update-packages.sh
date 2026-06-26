#!/usr/bin/env bash
# Sync the public First Motive package repos into src/ from fm-ros2.repos, plus
# the private learning stack from fm-learning.repos when that overlay is present.
# Imports any missing repo, then pulls every repo to its tracked ref (main).
# src/ is gitignored; each src/fm-* is its own clone with its own remote —
# commit and push package changes from inside that repo, not from here.
set -euo pipefail

usage() {
  cat <<'EOF'
update-packages.sh — sync the package repos into src/ from the .repos manifests

Imports any missing public repo (plus the private learning overlay when
fm-learning.repos is present), then pulls every repo to its tracked ref.

Usage: ./scripts/update-packages.sh [-h]

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

  # Resolve a vcs runner: prefer an installed `vcs`, else run it ephemerally via
  # uv (no global install, no PATH pollution). Fail loud if neither is available.
  local VCS
  if command -v vcs >/dev/null 2>&1; then
    VCS=(vcs)
  elif command -v uv >/dev/null 2>&1; then
    echo "==> vcstool not found; running via uv (ephemeral) ..."
    # vcstool imports pkg_resources; setuptools>=81 dropped it (see CI pin).
    VCS=(uv tool run --from vcstool --with "setuptools<81" vcs)
  else
    echo "ERROR: need vcstool or uv. Install uv: https://docs.astral.sh/uv/" >&2
    return 1
  fi

  mkdir -p src

  # vcs import clones repos missing from src/ and leaves existing clones untouched.
  echo "==> Importing missing package repos into src/ ..."
  "${VCS[@]}" import src < fm-ros2.repos

  # Private learning-stack overlay: imported only when the gitignored manifest is
  # present (team members with access). Public clones skip it silently.
  if [[ -f fm-learning.repos ]]; then
    echo "==> Importing private learning overlay into src/ ..."
    "${VCS[@]}" import src < fm-learning.repos
  fi

  # vcs pull fast-forwards every clone already in src/ to its tracked ref.
  echo "==> Pulling all package repos to latest ..."
  "${VCS[@]}" pull src

  echo "==> Status:"
  "${VCS[@]}" status src
}

main "$@"
