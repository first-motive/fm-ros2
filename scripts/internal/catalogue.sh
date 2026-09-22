#!/usr/bin/env bash
set -euo pipefail

recorder_environment() {
  local file="$1" key value
  # Read only transport fields; an EnvironmentFile is data, not shell code.
  while IFS='=' read -r key value; do
    case "$key" in
      ROS_DOMAIN_ID|FM_TRANSPORT|FM_COMMS|FM_LAN_IP)
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        export "$key=$value" ;;
    esac
  done < "$file"
}

main() {
  local domain="$1" host="" argument quoted replacement="'\\''" local_only=false
  shift
  local -a forwarded=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        [[ $# -ge 2 && -z "$host" && "$2" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || {
          echo "error: --host needs one SSH host or alias" >&2; return 2;
        }
        host="$2"; shift 2 ;;
      *)
        case "$1" in --help|-h|--dry-run) local_only=true ;; esac
        forwarded+=("$1"); shift ;;
    esac
  done
  local remote_command="exec fm $domain"
  [[ "$domain" != capture ]] || remote_command="exec fm episode catalog"
  [[ "$domain" != qa ]] || remote_command="exec fm episode qa"
  [[ "$domain" != dataset ]] || remote_command+=" catalog"
  [[ "$domain" != profile ]] || remote_command="exec fm process profiles"
  [[ "$domain" != provision ]] || remote_command="exec fm process provision"
  [[ "$domain" != release ]] || remote_command="exec fm dataset-release"
  if [[ -n "$host" ]]; then
    for argument in "${forwarded[@]}"; do
      quoted="${argument//\'/$replacement}"
      remote_command+=" '$quoted'"
    done
    exec ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$remote_command"
  fi
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  if [[ "$local_only" == true ]]; then
    exec uv run --no-project python "$root/scripts/internal/catalogue-client.py" "$domain" "${forwarded[@]}"
  fi
  cd "$root"
  if [[ "$domain" == project || "$domain" == capture || "$domain" == qa ]] && [[ ! -f "${FM_PROCESSOR_ENV_FILE:-/etc/fm-processor.env}" ]]; then
    if [[ ! -f /etc/fm-recorder.env || ! -f /opt/ros/humble/setup.bash || ! -f "$root/install/setup.bash" ]]; then
      echo "error: this host has no supported recorder or processor runtime" >&2
      return 1
    fi
    recorder_environment /etc/fm-recorder.env
    # The recorder service uses these same native Humble and workspace overlays.
    set +u
    # shellcheck disable=SC1091
    source /opt/ros/humble/setup.bash >&2
    # shellcheck disable=SC1091
    source "$root/install/setup.bash" >&2
    # shellcheck source=scripts/env/comms.sh
    source "$root/scripts/env/comms.sh" >&2
    set -u
    /usr/bin/python3 -c "$(cat scripts/internal/catalogue-client.py)" "$domain" "${forwarded[@]}"
    return
  fi
  # shellcheck source=scripts/internal/lib-supervisor.sh
  source scripts/internal/lib-supervisor.sh
  fm_supervisor_require
  if [[ "$(fm_processor_runtime)" == native ]]; then
    recorder_environment "${FM_PROCESSOR_ENV_FILE:-/etc/fm-processor.env}"
    set +u
    # Match the processor service rather than the operator's login dotfiles.
    # shellcheck disable=SC1091
    source /opt/ros/humble/setup.bash >&2
    # shellcheck disable=SC1091
    source "$root/install/setup.bash" >&2
    # shellcheck source=scripts/env/comms.sh
    source "$root/scripts/env/comms.sh" >&2
    set -u
    /usr/bin/python3 -c "$(cat scripts/internal/catalogue-client.py)" "$domain" "${forwarded[@]}"
    return
  fi
  fm_supervisor_exec /usr/bin/python3 -c "$(cat scripts/internal/catalogue-client.py)" "$domain" "${forwarded[@]}"
}

main "$@"
