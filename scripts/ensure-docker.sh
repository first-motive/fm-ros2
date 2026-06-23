#!/usr/bin/env bash
# Ensure a Docker daemon is running on macOS, starting OrbStack (preferred) or
# Docker Desktop if needed. Idempotent: a no-op when the daemon is already up.
set -euo pipefail

WAIT_SECONDS="${DOCKER_WAIT_SECONDS:-60}"

# Already up? Nothing to do.
if docker info >/dev/null 2>&1; then
  echo "Docker daemon already running"
  exit 0
fi

start_orbstack() {
  echo "Starting OrbStack..."
  if command -v orb >/dev/null 2>&1; then
    orb start >/dev/null 2>&1 || open -a OrbStack
  else
    open -a OrbStack
  fi
}

start_docker_desktop() {
  echo "Starting Docker Desktop..."
  open -a Docker
}

# Pick a provider. Prefer OrbStack on M-series macOS.
if command -v orb >/dev/null 2>&1 || [ -d "/Applications/OrbStack.app" ]; then
  start_orbstack
elif [ -d "/Applications/Docker.app" ]; then
  start_docker_desktop
else
  echo "ERROR: No Docker provider found. Install OrbStack: https://orbstack.dev" >&2
  exit 1
fi

# Wait for the daemon to accept connections.
echo "Waiting up to ${WAIT_SECONDS}s for the Docker daemon..."
for ((i = 0; i < WAIT_SECONDS; i++)); do
  if docker info >/dev/null 2>&1; then
    echo "Docker daemon ready"
    exit 0
  fi
  sleep 1
done

echo "ERROR: Docker daemon did not start within ${WAIT_SECONDS}s." >&2
exit 1
