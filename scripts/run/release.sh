#!/usr/bin/env bash
# Thin client for the processor-owned release contract. No Pack logic lives here.
set -euo pipefail

main() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.."
  local special=false host="" dry_run=false argument quoted replacement="'\\''"
  local -a forwarded=()
  if [[ "${1:-}" == viewer || "${1:-}" == huggingface ]]; then
    special=true
    shift
  elif [[ "${1:-}" == --host && $# -ge 3 && ( "${3:-}" == viewer || "${3:-}" == huggingface ) ]]; then
    host="$2"
    [[ "$host" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { echo "error: --host needs one SSH host or alias" >&2; return 2; }
    special=true
    shift 3
  fi
  if [[ "$special" == true ]]; then
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --host)
          [[ $# -ge 2 && -z "$host" && "$2" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || {
            echo "error: --host needs one SSH host or alias" >&2; return 2;
          }
          host="$2"; shift 2 ;;
        --dry-run) dry_run=true; forwarded+=("$1"); shift ;;
        *) forwarded+=("$1"); shift ;;
      esac
    done
    if [[ -n "$host" ]]; then
      local remote_command="exec fm dataset-release viewer"
      for argument in "${forwarded[@]}"; do
        quoted="${argument//\'/$replacement}"
        remote_command+=" '$quoted'"
      done
      exec ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$remote_command"
    fi
    if [[ -n "${FM_SELFTEST:-}" ]]; then
      echo "selftest ok: release viewer resolved"
      return 0
    fi
    if [[ "$dry_run" == true ]]; then
      UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/fm-parity-uv-cache}" uv run --no-project python scripts/internal/catalogue-client.py viewer "${forwarded[@]}"
      return $?
    fi
    local timeout_value="${FM_SUPERVISOR_TIMEOUT:-20}"
    source scripts/internal/lib-supervisor.sh
    fm_supervisor_require
    fm_supervisor_exec python3 scripts/internal/catalogue-client.py viewer "${forwarded[@]}" --timeout "$timeout_value"
    return $?
  fi
  if [[ -n "${FM_SELFTEST:-}" ]]; then
    set -- "$@" --dry-run
  fi
  exec bash scripts/internal/catalogue.sh release "$@"
}

main "$@"
