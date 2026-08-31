#!/usr/bin/env bash
# macOS (M5) setup: verify OrbStack is the Docker provider, then build the base image.
# Dev + build + sim + dataset only — no GPU, no hardware on this path.
set -euo pipefail

# fm-render:begin fm-docker-pin sha256:19a047f515a3016c31c93a42aef126d53c3efd4aa3f314511e4c1a49ba4ce6d7 — rendered by the First Motive render plane — edit the upstream source, not this file
# The container runtime install is delegated to fm-docker, fetched from one
# pinned release tag. Re-pin in the render plane, never in a consumer.
# shellcheck disable=SC2034
FM_DOCKER_RAW="https://raw.githubusercontent.com/first-motive/fm-docker/v0.1.7"
# fm-render:end fm-docker-pin

usage() {
  cat <<'EOF'
setup-macos.sh — macOS (M5) setup: verify OrbStack is the Docker provider, build base image

Dev + build + sim + dataset only — no GPU, no hardware on this path.

Usage: ./scripts/install/setup-macos.sh [-h]

  -h, --help   show this help
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$ROOT"

  echo "==> Setting up Docker / OrbStack via fm-docker..."
  # Delegate the runtime bring-up to fm-docker — no vendored helper here. Use the
  # imported installer when docker/ is present; fall back to the pinned tag.
  if [[ -f docker/install.sh ]]; then
    bash docker/install.sh --no-pull
  else
    curl -fsSL --proto '=https' --proto-redir '=https' \
      "$FM_DOCKER_RAW/install.sh" | bash -s -- --no-pull
  fi
  if docker info 2>/dev/null | grep -qi orbstack; then
    echo "    OrbStack detected."
  else
    echo "    WARNING: Docker is running but does not look like OrbStack."
    echo "    On M5 macOS we standardise on OrbStack (arm64, no GPU)."
  fi

  echo "==> Importing external dependencies (placeholder pins)..."
  if command -v vcs >/dev/null 2>&1; then
    ./scripts/install/import-externals.sh
  else
    echo "    vcs not on host; import runs inside the container instead:"
    echo "      docker compose -f docker/compose.yaml -f docker/compose.macos.yaml run --rm fm \\"
    echo "        ./scripts/install/import-externals.sh"
  fi

  echo "==> Building base image (arm64)..."
  docker compose -f docker/compose.yaml -f docker/compose.macos.yaml build

  echo "==> Done. Bring the stack up with:"
  echo "    docker compose -f docker/compose.yaml -f docker/compose.macos.yaml up"
  echo "    Then connect Foxglove Studio to ws://localhost:8765"
}

main "$@"
