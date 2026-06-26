#!/usr/bin/env bash
# macOS (M5) setup: verify OrbStack is the Docker provider, then build the base image.
# Dev + build + sim + dataset only — no GPU, no hardware on this path.
set -euo pipefail

usage() {
  cat <<'EOF'
setup-macos.sh — macOS (M5) setup: verify OrbStack is the Docker provider, build base image

Dev + build + sim + dataset only — no GPU, no hardware on this path.

Usage: ./scripts/setup-macos.sh [-h]

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

  echo "==> Setting up Docker / OrbStack via fm-docker..."
  # Delegate the runtime bring-up to fm-docker — no vendored helper here. Use the
  # imported installer when docker/ is present; fall back to the pinned tag.
  if [[ -f docker/install.sh ]]; then
    bash docker/install.sh --no-pull
  else
    curl -fsSL --proto '=https' --proto-redir '=https' \
      "https://raw.githubusercontent.com/first-motive/fm-docker/v0.1.0/install.sh" | bash -s -- --no-pull
  fi
  if docker info 2>/dev/null | grep -qi orbstack; then
    echo "    OrbStack detected."
  else
    echo "    WARNING: Docker is running but does not look like OrbStack."
    echo "    On M5 macOS we standardise on OrbStack (arm64, no GPU)."
  fi

  echo "==> Importing external dependencies (placeholder pins)..."
  if command -v vcs >/dev/null 2>&1; then
    ./scripts/import-externals.sh
  else
    echo "    vcs not on host; import runs inside the container instead:"
    echo "      docker compose -f docker/compose.yaml -f docker/compose.macos.yaml run --rm fm \\"
    echo "        ./scripts/import-externals.sh"
  fi

  echo "==> Building base image (arm64)..."
  docker compose -f docker/compose.yaml -f docker/compose.macos.yaml build

  echo "==> Done. Bring the stack up with:"
  echo "    docker compose -f docker/compose.yaml -f docker/compose.macos.yaml up"
  echo "    Then connect Foxglove Studio to ws://localhost:8765"
}

main "$@"
