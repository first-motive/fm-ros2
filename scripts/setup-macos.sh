#!/usr/bin/env bash
# macOS (M5) setup: verify OrbStack is the Docker provider, then build the base image.
# Dev + build + sim + dataset only — no GPU, no hardware on this path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Checking Docker / OrbStack..."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found. Install OrbStack: https://orbstack.dev" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon not reachable. Start OrbStack and retry." >&2
  exit 1
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
  echo "      docker compose -f docker/compose.yaml -f docker/compose.macos.yaml run --rm fm_ros2 \\"
  echo "        ./scripts/import-externals.sh"
fi

echo "==> Building base image (arm64)..."
docker compose -f docker/compose.yaml -f docker/compose.macos.yaml build

echo "==> Done. Bring the stack up with:"
echo "    docker compose -f docker/compose.yaml -f docker/compose.macos.yaml up"
echo "    Then connect Foxglove Studio to ws://localhost:8765"
