#!/usr/bin/env bash
set -euo pipefail

main() {
  exec bash "$(dirname "${BASH_SOURCE[0]}")/../internal/catalogue.sh" project "$@"
}

main "$@"
