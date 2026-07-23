#!/usr/bin/env bash
# install-update-timer.sh — install (or remove) the appliance auto-update timer
# for one role: fm-update-<role>.timer fires fm-update-<role>.service every
# ~15 minutes, which runs scripts/run/appliance-update.sh — fetch, and only when
# a repo is behind, fast-forward + re-run the role installer (rebuild + service
# restart). A merged PR lands on the box within one tick; an up-to-date box
# does nothing but a fetch.
#
# Units are per-role because one host can carry both roles in separate
# workspaces (the current shared box does): each timer converges its own
# checkout. The installer never touches the update SERVICE instance — only the
# timer — so an auto-update that re-runs this installer cannot kill itself.
#
# Linux + systemd only, best-effort (warns + returns 0 elsewhere), idempotent.
# Invoked by the role setups when install.sh got --service; runnable standalone.
#
# Usage:
#   ./scripts/install/install-update-timer.sh recorder|processor
#   ./scripts/install/install-update-timer.sh uninstall recorder|processor
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # item()
cd "$ROOT"

WRAPPER="$ROOT/scripts/run/appliance-update.sh"

SERVICE_USER="${SUDO_USER:-$USER}"
# `|| true`: getent is Linux-only and this must not kill --help on other hosts.
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

usage() {
  cat <<'EOF'
install-update-timer.sh — install/remove the appliance auto-update timer (Linux)

  recorder|processor              write + enable fm-update-<role>.timer (15 min)
  uninstall recorder|processor    stop + disable + remove the role's timer
  -h, --help                      show this help

The timer runs scripts/run/appliance-update.sh <role>: fetch the workspace and
role repos, fast-forward when behind, re-run the role installer. Busy takes and
in-flight processing runs are never interrupted (the script's busy gate skips
the tick). Pause anytime: sudo systemctl stop fm-update-<role>.timer
EOF
}

_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: the auto-update timer is Linux-only — skipping." >&2
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: systemctl not found (no systemd) — skipping the update timer." >&2
    return 1
  fi
  return 0
}

do_install() {  # role
  local role="$1"
  _require_linux_systemd || return 0
  if [ ! -f "$WRAPPER" ]; then
    echo "ERROR: $WRAPPER missing — cannot install the update timer." >&2
    return 1
  fi
  local unit="/etc/systemd/system/fm-update-$role.service"
  local timer="/etc/systemd/system/fm-update-$role.timer"

  item "writing $unit + $timer (User=$SERVICE_USER, workspace=$ROOT) ..."
  sudo tee "$unit" >/dev/null <<EOF
[Unit]
Description=First Motive appliance auto-update ($role @ $ROOT)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
WorkingDirectory=$ROOT
ExecStart=/bin/bash $WRAPPER $role
EOF

  sudo tee "$timer" >/dev/null <<EOF
[Unit]
Description=Run fm-update-$role every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF

  # Enable the TIMER only. Never restart the service unit here: when an
  # auto-update re-runs this installer, that service instance IS the caller.
  sudo systemctl daemon-reload
  sudo systemctl enable --now "fm-update-$role.timer"

  cat <<EOF

fm-update-$role.timer enabled — merged updates land within ~15 minutes.

  next runs:  systemctl list-timers fm-update-$role.timer
  last run:   journalctl -u fm-update-$role -n 20
  run now:    sudo systemctl start fm-update-$role.service
  pause:      sudo systemctl stop fm-update-$role.timer
EOF
}

do_uninstall() {  # role
  local role="$1"
  _require_linux_systemd || return 0
  item "stopping + removing fm-update-$role.timer (if present) ..."
  sudo systemctl disable --now "fm-update-$role.timer" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/fm-update-$role.service" \
             "/etc/systemd/system/fm-update-$role.timer"
  sudo systemctl daemon-reload 2>/dev/null || true
  item "fm-update-$role removed."
}

main() {
  case "${1:-}" in
    -h|--help|"") usage; [ -n "${1:-}" ] && return 0 || return 1 ;;
    uninstall)
      case "${2:-}" in
        recorder|processor) do_uninstall "$2" ;;
        *) echo "error: uninstall needs a role (recorder|processor)" >&2; return 1 ;;
      esac
      ;;
    recorder|processor) do_install "$1" ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
  esac
}

main "$@"
