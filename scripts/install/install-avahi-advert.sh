#!/usr/bin/env bash
# install-avahi-advert.sh — advertise this host's rig role on the local network
# via mDNS (avahi), so the desktop app's Settings can discover it instead of the
# operator typing an IP. One advert per role: /etc/avahi/services/fm-<role>.service
# publishes _fm-rig._tcp on the bridge port with TXT records the app reads
# directly (no DNS-SD resolve step needed):
#
#   role=recorder|processor   which Settings field the rig fills
#   host=<hostname>.local     the address the app should dial
#   port=8765                 the foxglove bridge port
#
# host= is baked at install time; the appliance auto-updater re-runs the role
# setup (which re-runs this) after every pull, so a renamed host re-advertises
# itself without manual steps. Both roles on one box = two adverts pointing at
# the same host:port — exactly the single-box setup.
#
# Linux + avahi only, best-effort (warns + returns 0 elsewhere), idempotent.
# Invoked by setup-recorder.sh / setup-processor.sh when install.sh got
# --service; runnable standalone for a manually-run rig.
#
# Usage:
#   ./scripts/install/install-avahi-advert.sh recorder|processor   # write the advert
#   ./scripts/install/install-avahi-advert.sh uninstall [role]     # remove one/both
set -euo pipefail

# lib.sh fallback keeps the script runnable over `ssh 'bash -s'` (no file on
# disk, so no workspace root to resolve) — the recordings-sync.sh pattern.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/lib.sh" ] && . "$ROOT/lib.sh" || item() { echo "$1"; }
# shellcheck disable=SC1091
[ -f "$ROOT/scripts/env/bridge.sh" ] && . "$ROOT/scripts/env/bridge.sh"

SERVICE_TYPE="_fm-rig._tcp"
BRIDGE_ENV="${FM_BRIDGE_ENV_FILE:-/etc/fm-bridge.env}"
BRIDGE_PORT="${FM_BRIDGE_PORT:-8765}"
FM_BRIDGE_OWNER="${FM_BRIDGE_OWNER:-embedded}"

usage() {
  cat <<'EOF'
install-avahi-advert.sh — mDNS advert for a rig role (Linux + avahi)

  recorder | processor    write /etc/avahi/services/fm-<role>.service
  uninstall [role]        remove the advert(s); no role removes both
  -h, --help              show this help

The desktop app browses _fm-rig._tcp and offers discovered rigs in Settings.
The port comes from /etc/fm-bridge.env (FM_BRIDGE_PORT, default 8765), the
same durable file used by the service and updater. Use install-bridge-config.sh
to change it; a role re-install does not overwrite it.
EOF
}

_require_linux() {
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: mDNS adverts are Linux-only (avahi) — skipping." >&2
    return 1
  fi
  return 0
}

do_install() {  # role
  local role="$1"
  _require_linux || return 0

  # Persist a first-run/default value, while preserving a tower's existing
  # 8766 choice. This also makes a manually-run Avahi installer converge with
  # the same source of truth as the systemd units.
  if [ -x "$ROOT/scripts/install/install-bridge-config.sh" ]; then
    FM_BRIDGE_ENV_FILE="$BRIDGE_ENV" "$ROOT/scripts/install/install-bridge-config.sh"
    # shellcheck disable=SC1091
    . "$ROOT/scripts/env/bridge.sh"
  fi
  BRIDGE_PORT="$FM_BRIDGE_PORT"

  # avahi-daemon ships on desktop Ubuntu but not on every server image.
  if ! command -v avahi-daemon >/dev/null 2>&1; then
    item "installing avahi-daemon (mDNS responder) ..."
    sudo apt-get install -y avahi-daemon
  fi
  sudo systemctl enable --now avahi-daemon 2>/dev/null || true

  local advert="/etc/avahi/services/fm-${role}.service"
  local host_fqdn="$(hostname).local"
  item "writing $advert (${SERVICE_TYPE}, host=$host_fqdn, port=$BRIDGE_PORT) ..."
  # %h expands to the hostname in the visible instance name, keeping names
  # unique when many boxes advertise the same role on one network.
  sudo tee "$advert" >/dev/null <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h ${role}</name>
  <service>
    <type>${SERVICE_TYPE}</type>
    <port>${BRIDGE_PORT}</port>
    <txt-record>role=${role}</txt-record>
    <txt-record>host=${host_fqdn}</txt-record>
    <txt-record>port=${BRIDGE_PORT}</txt-record>
    <txt-record>bridge_owner=${FM_BRIDGE_OWNER}</txt-record>
  </service>
</service-group>
EOF
  # avahi watches /etc/avahi/services and reloads on its own; the restart just
  # makes a first install advertise immediately.
  sudo systemctl restart avahi-daemon 2>/dev/null || true
  item "advertising: $(hostname) ${role} -> ws://${host_fqdn}:${BRIDGE_PORT}"
}

do_uninstall() {  # [role]
  _require_linux || return 0
  local role
  for role in ${1:-recorder processor}; do
    local advert="/etc/avahi/services/fm-${role}.service"
    if [ -f "$advert" ]; then
      item "removing $advert ..."
      sudo rm -f "$advert"
    fi
  done
  # avahi picks up the removal itself; never uninstall avahi-daemon — other
  # tenants of the host may rely on it.
}

main() {
  case "${1:-}" in
    -h|--help|"") usage; [ -n "${1:-}" ] || { echo; echo "ERROR: a role is required." >&2; exit 2; } ;;
    recorder|processor) do_install "$1" ;;
    uninstall) do_uninstall "${2:-}" ;;
    *) usage; echo; echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
}

main "$@"
