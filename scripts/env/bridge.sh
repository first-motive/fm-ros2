#!/usr/bin/env bash
# bridge.sh — the First Motive Foxglove bridge endpoint contract.
#
# The default keeps existing desktop and local-container callers compatible:
# ws://<host>:8765. Linux appliances persist an override in /etc/fm-bridge.env;
# every service, installer, updater, and advert reads that same file. An explicit
# FM_BRIDGE_PORT in the environment is useful when creating the file for the first
# time, but a present config file remains authoritative after that.

FM_BRIDGE_DEFAULT_PORT=8765
FM_BRIDGE_ENV_FILE="${FM_BRIDGE_ENV_FILE:-/etc/fm-bridge.env}"

fm_bridge_validate_port() {  # port
  local port="${1:-}"
  case "$port" in
    ''|*[!0-9]*)
      echo "error: FM_BRIDGE_PORT must be a TCP port number (1-65535), got '$port'" >&2
      return 1
      ;;
  esac
  # 10# keeps values such as 08765 from being parsed as invalid octal by bash.
  local number=$((10#$port))
  if (( number < 1 || number > 65535 )); then
    echo "error: FM_BRIDGE_PORT must be between 1 and 65535, got '$port'" >&2
    return 1
  fi
}

fm_bridge_load() {
  local env_file="${FM_BRIDGE_ENV_FILE:-/etc/fm-bridge.env}"
  local requested_port="${FM_BRIDGE_PORT:-}"
  local requested_owner="${FM_BRIDGE_OWNER:-}"

  # The file is deliberately a simple EnvironmentFile (KEY=value lines), so it
  # can be read by systemd and by shell entry points without a second format.
  if [ -r "$env_file" ]; then
    # shellcheck disable=SC1090
    . "$env_file"
  fi

  # A caller may provide a first-run value, or an explicit owner for a one-shot
  # installer. Once the durable file exists, its values win on normal starts.
  if [ ! -r "$env_file" ] && [ -n "$requested_port" ]; then
    FM_BRIDGE_PORT="$requested_port"
  fi
  if [ ! -r "$env_file" ] && [ -n "$requested_owner" ]; then
    FM_BRIDGE_OWNER="$requested_owner"
  fi

  FM_BRIDGE_PORT="${FM_BRIDGE_PORT:-$FM_BRIDGE_DEFAULT_PORT}"
  FM_BRIDGE_OWNER="${FM_BRIDGE_OWNER:-embedded}"
  fm_bridge_validate_port "$FM_BRIDGE_PORT"
  case "$FM_BRIDGE_OWNER" in
    embedded|standalone) ;;
    *)
      echo "error: FM_BRIDGE_OWNER must be embedded or standalone, got '$FM_BRIDGE_OWNER'" >&2
      return 1
      ;;
  esac

  export FM_BRIDGE_ENV_FILE FM_BRIDGE_PORT FM_BRIDGE_OWNER
}

fm_bridge_port_in_use() {  # [port]
  local port="${1:-$FM_BRIDGE_PORT}"
  fm_bridge_validate_port "$port" >/dev/null || return 2

  if command -v ss >/dev/null 2>&1; then
    # ss is present on the Linux appliances. Match either IPv4 or IPv6 local
    # address without requiring root (the process name is only diagnostic).
    ss -Hln 2>/dev/null \
      | awk -v suffix=":${port}" '$4 ~ suffix "$" || $5 ~ suffix "$" { found=1 }
        END { exit found ? 0 : 1 }'
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  # Bash's TCP pseudo-device is the least informative fallback, but it works on
  # small images that omit both ss and lsof.
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

fm_bridge_require_free() {  # [port]
  local port="${1:-$FM_BRIDGE_PORT}"
  if fm_bridge_port_in_use "$port"; then
    echo "error: FM_BRIDGE_PORT=$port is already listening; refusing to start a second Foxglove bridge." >&2
    echo "       Inspect the owner with: sudo ss -ltnp 'sport = :$port'" >&2
    echo "       Stop the competing bridge (often Axol inference-server) or change /etc/fm-bridge.env." >&2
    return 1
  fi
}

fm_bridge_load
