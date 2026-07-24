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

SERVICE_TYPE="_fm-rig._tcp"
BRIDGE_PORT="${FM_BRIDGE_PORT:-8765}"

usage() {
  cat <<'EOF'
install-avahi-advert.sh — mDNS advert for a rig role (Linux + avahi)

  recorder | processor    write /etc/avahi/services/fm-<role>.service
  uninstall [role]        remove the advert(s); no role removes both
  -h, --help              show this help

The desktop app browses _fm-rig._tcp and offers discovered rigs in Settings.
Override the advertised bridge port with FM_BRIDGE_PORT (default 8765).
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
