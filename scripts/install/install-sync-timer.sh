#!/usr/bin/env bash
# install-sync-timer.sh — install (or remove) the recordings-sync timer on a
# processor host: fm-sync.timer runs scripts/run/recordings-sync.sh every ~5
# minutes, pulling finalized episodes from the recorder host's recordings dir
# into this host's (index-driven, busy-gated; see recordings-sync.sh).
#
# Single-box setups keep the timer harmlessly idle: the env template ships with
# FM_SYNC_SOURCE empty and every tick is a quiet no-op until the recorder moves
# to its own device — then activating the split is one env-file edit.
#
# Linux + systemd only, best-effort (warns + returns 0 elsewhere), idempotent.
# Invoked by setup-processor.sh when install.sh got --service; runnable standalone.
#
# Usage:
#   ./scripts/install/install-sync-timer.sh            # write + enable the timer
#   ./scripts/install/install-sync-timer.sh uninstall  # stop + disable + remove
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # item()
cd "$ROOT"

UNIT=/etc/systemd/system/fm-sync.service
TIMER=/etc/systemd/system/fm-sync.timer
ENVFILE=/etc/fm-sync.env
WRAPPER="$ROOT/scripts/run/recordings-sync.sh"

SERVICE_USER="${SUDO_USER:-$USER}"
# `|| true`: getent is Linux-only and this must not kill --help on other hosts.
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

usage() {
  cat <<'EOF'
install-sync-timer.sh — install/remove the recordings-sync timer (Linux)

  (no args)    write fm-sync.service + fm-sync.timer, enable, start
  uninstall    stop + disable + remove the units and env file
  -h, --help   show this help

The timer pulls finalized recordings from the recorder host configured in
/etc/fm-sync.env (FM_SYNC_SOURCE=user@host:path). Left empty — the single-box
setup — every tick is a quiet no-op. Pause: sudo systemctl stop fm-sync.timer
EOF
}

_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: the sync timer is Linux-only — skipping." >&2
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: systemctl not found (no systemd) — skipping the sync timer." >&2
    return 1
  fi
  return 0
}

do_install() {
  _require_linux_systemd || return 0
  if [ ! -f "$WRAPPER" ]; then
    echo "ERROR: $WRAPPER missing — cannot install the sync timer." >&2
    return 1
  fi

  item "writing $UNIT + $TIMER (User=$SERVICE_USER, workspace=$ROOT) ..."
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive recordings sync (recorder -> processor)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
EnvironmentFile=-$ENVFILE
WorkingDirectory=$ROOT
ExecStart=/bin/bash $WRAPPER
EOF

  sudo tee "$TIMER" >/dev/null <<EOF
[Unit]
Description=Run fm-sync every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF

  # Config knobs — written only when absent so a re-install never clobbers a
  # host's configured source.
  if [ ! -f "$ENVFILE" ]; then
    item "writing $ENVFILE (config knobs — edit, then the next tick applies) ..."
    sudo tee "$ENVFILE" >/dev/null <<'EOF'
# fm-sync.env — recordings transfer, recorder host -> this processor host.
#
# EMPTY source = single-box setup (recorder and processor share ~/recordings):
# every tick is a quiet no-op. When the recorder moves to its own device, set
# its recordings dir here (needs key-auth ssh to that host) and the split is
# live on the next tick:
#FM_SYNC_SOURCE=nish@<recorder-ip>:~/recordings
FM_SYNC_SOURCE=
# Where episodes land on this host (the processor reads the same dir):
FM_SYNC_DEST=~/recordings
EOF
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable --now fm-sync.timer

  cat <<EOF

fm-sync.timer enabled — idle no-op until FM_SYNC_SOURCE is set (single box).

  configure:  sudo nano $ENVFILE
  next runs:  systemctl list-timers fm-sync.timer
  last run:   journalctl -u fm-sync -n 20
  run now:    sudo systemctl start fm-sync.service
  pause:      sudo systemctl stop fm-sync.timer
EOF
}

do_uninstall() {
  _require_linux_systemd || return 0
  item "stopping + removing fm-sync.timer (if present) ..."
  sudo systemctl disable --now fm-sync.timer 2>/dev/null || true
  sudo rm -f "$UNIT" "$TIMER" "$ENVFILE"
  sudo systemctl daemon-reload 2>/dev/null || true
  item "fm-sync removed."
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
