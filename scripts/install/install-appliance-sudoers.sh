#!/usr/bin/env bash
# install-appliance-sudoers.sh — grant the appliance user passwordless sudo.
#
# The appliance auto-update timer (fm-update-<role>.timer) re-runs the role
# installer unattended: apt installs, systemd unit writes, udev reloads — all
# sudo, all without a terminal to type a password into. A fresh host (a
# just-flashed Jetson) ships sudo-with-password, so without this drop-in every
# update tick dies at its first sudo. The role setups install this when
# install.sh got --service; FM_NO_SUDOERS=1 opts out (updates then need a
# manual, interactive re-run of the role installer).
#
# The grant is deliberately NOPASSWD:ALL for the installing user: the role
# installers touch apt, systemd, udev, avahi, and /etc files, and a command
# allowlist would drift out of date silently, leaving the fleet half-updated.
# An appliance box is single-purpose by definition; a shared workstation
# should opt out and update by hand.
#
# The candidate file is validated with `visudo -c` BEFORE it lands in
# /etc/sudoers.d — a syntax error there locks sudo for the whole host.
#
# Linux + systemd only, best-effort (warns + returns 0 elsewhere), idempotent.
# Invoked by setup-recorder.sh / setup-processor.sh when install.sh got
# --service; runnable standalone.
#
# Usage:
#   ./scripts/install/install-appliance-sudoers.sh            # install the drop-in
#   ./scripts/install/install-appliance-sudoers.sh uninstall  # remove it
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # item()

DROPIN=/etc/sudoers.d/010-fm-appliance

# Grant to the human who installed the role, not root — the same resolution the
# service installers use for User=.
SERVICE_USER="${SUDO_USER:-$USER}"

usage() {
  cat <<'EOF'
install-appliance-sudoers.sh — passwordless sudo for the appliance user (Linux)

  (no args)    write /etc/sudoers.d/010-fm-appliance (validated with visudo -c)
  uninstall    remove the drop-in
  -h, --help   show this help

Environment:
  FM_NO_SUDOERS=1   skip the install (auto-updates then need a manual re-run)

Needed by the appliance auto-update timer: it re-runs the role installer
unattended, and the installer's apt/systemd/udev steps are all sudo.
EOF
}

_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: the appliance sudoers drop-in is Linux-only — skipping." >&2
    return 1
  fi
  if ! command -v visudo >/dev/null 2>&1; then
    echo "WARNING: visudo not found — skipping the sudoers drop-in." >&2
    return 1
  fi
  return 0
}

do_install() {
  _require_linux_systemd || return 0
  if [ "${FM_NO_SUDOERS:-0}" = 1 ]; then
    item "FM_NO_SUDOERS=1 — skipping passwordless sudo (auto-updates will need a manual re-run)"
    return 0
  fi
  if [ "$SERVICE_USER" = root ]; then
    item "running as root — no sudoers drop-in needed"
    return 0
  fi

  item "granting passwordless sudo to $SERVICE_USER ($DROPIN) — needed by the unattended auto-update"
  local tmp
  tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SERVICE_USER" > "$tmp"
  # Validate BEFORE installing: a bad file in /etc/sudoers.d breaks sudo host-wide.
  if ! visudo -c -f "$tmp" >/dev/null; then
    rm -f "$tmp"
    echo "ERROR: generated sudoers drop-in failed visudo validation — not installed." >&2
    return 1
  fi
  sudo install -o root -g root -m 0440 "$tmp" "$DROPIN"
  rm -f "$tmp"
  item "installed — remove anytime with: ./scripts/install/install-appliance-sudoers.sh uninstall"
}

do_uninstall() {
  _require_linux_systemd || return 0
  if [ -f "$DROPIN" ]; then
    item "removing $DROPIN ..."
    sudo rm -f "$DROPIN"
  fi
  item "appliance sudoers drop-in removed (auto-updates now need a manual re-run)."
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    uninstall) do_uninstall ;;
    ""|install) do_install ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
  esac
}

main "$@"
