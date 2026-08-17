#!/usr/bin/env bash
# Lint the GitHub Actions workflows and the composite actions under .github/.
#
#   ./scripts/ci/lint-workflows.sh
#
# actionlint parses every workflow, type-checks the expressions (`inputs.foo` that no
# input declares, a step output that no step produces), and runs shellcheck over each
# `run:` block. CI calls it, and it runs locally the same way.
#
# Resolution order, so a contributor needs nothing installed:
#
#   actionlint on PATH  ->  use it
#   docker present      ->  run the pinned image
#   neither             ->  say how to get one, and fail
#
# The version is pinned in both paths: a lint that changes under you is a lint that
# blocks an unrelated PR.
set -euo pipefail

ACTIONLINT_VERSION="1.7.12"
IMAGE="rhysd/actionlint:${ACTIONLINT_VERSION}"

usage() {
  cat <<'EOF'
lint-workflows.sh — actionlint over .github/workflows and .github/actions

Usage: ./scripts/ci/lint-workflows.sh [-h]

  -h, --help   show this help

Install actionlint locally (optional — docker is used as a fallback):
  brew install actionlint            # macOS
  go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$ROOT"

  if command -v actionlint >/dev/null 2>&1; then
    local have
    have="$(actionlint --version 2>/dev/null | head -1)"
    if [ "$have" != "$ACTIONLINT_VERSION" ]; then
      echo "note: local actionlint is $have, this repo pins $ACTIONLINT_VERSION"
    fi
    echo "==> actionlint $have (local)"
    actionlint -color
  elif command -v docker >/dev/null 2>&1; then
    echo "==> actionlint $ACTIONLINT_VERSION (docker)"
    # Read-only mount: the linter never writes, and a container that cannot write
    # cannot surprise a working tree.
    docker run --rm -v "$ROOT:/repo:ro" -w /repo "$IMAGE" -color
  else
    echo "error: neither actionlint nor docker found." >&2
    echo "       brew install actionlint   (or see --help)" >&2
    return 1
  fi

  echo "==> workflows lint clean"
}

main "$@"
