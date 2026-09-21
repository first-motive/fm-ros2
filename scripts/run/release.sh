#!/usr/bin/env bash
# Thin client for the processor-owned release contract. No Pack logic lives here.
set -euo pipefail

main() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.."
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    set -- "$@" --dry-run
  fi
  exec bash scripts/internal/catalogue.sh release "$@"
}

main "$@"
