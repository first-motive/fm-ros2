#!/usr/bin/env bash
# Linux (native) setup: verify Docker + NVIDIA toolkit, then build the base image.
# Full hardware path — GPU, device passthrough, X11.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon not reachable. Start Docker and retry." >&2
  exit 1
fi

echo "==> Checking NVIDIA container toolkit (GPU path)..."
if docker info 2>/dev/null | grep -qi nvidia; then
  echo "    NVIDIA runtime detected."
else
  echo "    WARNING: NVIDIA runtime not detected. Install nvidia-container-toolkit"
  echo "    for GPU access, or the linux overlay's GPU reservation will fail."
fi

echo "==> Allowing local X11 connections (for GUI tools)..."
command -v xhost >/dev/null 2>&1 && xhost +local:docker || \
  echo "    xhost not available — skip if running headless."

echo "==> Importing external dependencies (placeholder pins)..."
if command -v vcs >/dev/null 2>&1; then
  vcs import src/external < external.repos || \
    echo "    vcs import failed — pins are placeholders, edit external.repos."
else
  echo "    vcs not on host; import runs inside the container instead."
fi

echo "==> Building base image..."
docker compose -f docker/compose.yaml -f docker/compose.linux.yaml build

echo "==> Done. Bring the stack up with:"
echo "    docker compose -f docker/compose.yaml -f docker/compose.linux.yaml up"
