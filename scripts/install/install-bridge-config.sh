#!/usr/bin/env bash
# install-bridge-config.sh — create or update the one durable bridge endpoint
# file shared by the recorder, standalone Foxglove service, Avahi, and updater.
#
# The default is intentionally 8765. Use --port 8766 on a tower where Axol owns
# 8765 and the First Motive bridge is the standalone owner on 8766. Existing
# values are preserved unless an explicit option changes them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/scripts/env/bridge.sh"

CONFIG_FILE="${FM_BRIDGE_ENV_FILE:-/etc/fm-bridge.env}"
PORT_ARG=""
OWNER_ARG=""

usage() {
  cat <<'EOF'
install-bridge-config.sh — persist the First Motive bridge endpoint

  --port PORT       persist FM_BRIDGE_PORT (default 8765 when new)
  --owner OWNER     embedded (default when new) or standalone
  -h, --help        show this help

The shared file is /etc/fm-bridge.env. It is never replaced wholesale, so
comments and unrelated environment keys survive role re-installs and updates.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      [ "$#" -ge 2 ] || { echo "error: --port needs a value" >&2; exit 2; }
      PORT_ARG="$2"; shift 2 ;;
    --owner)
      [ "$#" -ge 2 ] || { echo "error: --owner needs a value" >&2; exit 2; }
      OWNER_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -n "$PORT_ARG" ]; then
  fm_bridge_validate_port "$PORT_ARG"
  FM_BRIDGE_PORT="$PORT_ARG"
fi
if [ -n "$OWNER_ARG" ]; then
  case "$OWNER_ARG" in embedded|standalone) ;; *)
    echo "error: --owner must be embedded or standalone" >&2; exit 2 ;;
  esac
  FM_BRIDGE_OWNER="$OWNER_ARG"
fi

# The test hook avoids sudo for a temp-file fixture. Production callers leave it
# unset and therefore write the root-owned /etc file.
run_priv() {
  if [ "${FM_BRIDGE_NO_SUDO:-0}" = 1 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_priv mkdir -p "$(dirname "$CONFIG_FILE")"
if ! run_priv test -f "$CONFIG_FILE"; then
  {
    echo "# First Motive Foxglove bridge endpoint — edit FM_BRIDGE_PORT, then restart the owning service."
    echo "FM_BRIDGE_PORT=$FM_BRIDGE_PORT"
    echo "FM_BRIDGE_OWNER=${FM_BRIDGE_OWNER:-embedded}"
  } | run_priv tee "$CONFIG_FILE" >/dev/null
else
  # Add missing keys without disturbing tuned values or comments. Explicit
  # options replace only their own key.
  if ! run_priv grep -q '^FM_BRIDGE_PORT=' "$CONFIG_FILE"; then
    printf 'FM_BRIDGE_PORT=%s\n' "$FM_BRIDGE_PORT" | run_priv tee -a "$CONFIG_FILE" >/dev/null
  elif [ -n "$PORT_ARG" ]; then
    run_priv sed -i -E "s#^FM_BRIDGE_PORT=.*#FM_BRIDGE_PORT=$FM_BRIDGE_PORT#" "$CONFIG_FILE"
  fi
  if ! run_priv grep -q '^FM_BRIDGE_OWNER=' "$CONFIG_FILE"; then
    printf 'FM_BRIDGE_OWNER=%s\n' "${FM_BRIDGE_OWNER:-embedded}" | run_priv tee -a "$CONFIG_FILE" >/dev/null
  elif [ -n "$OWNER_ARG" ]; then
    run_priv sed -i -E "s#^FM_BRIDGE_OWNER=.*#FM_BRIDGE_OWNER=$FM_BRIDGE_OWNER#" "$CONFIG_FILE"
  fi
fi

run_priv chmod 0644 "$CONFIG_FILE"
echo "bridge config: $CONFIG_FILE (FM_BRIDGE_PORT=$FM_BRIDGE_PORT, FM_BRIDGE_OWNER=${FM_BRIDGE_OWNER:-embedded})"
