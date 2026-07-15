#!/usr/bin/env bash
# install-recorder-service.sh — install (or remove) the systemd unit that auto-starts
# the egocentric recorder on boot, turning a Linux camera host into a headless
# appliance: boot -> camera + tracker + recorder (armed, idle) + foxglove bridge up,
# and an operator drives REC/STOP from a Mac (fm_viewer / Foxglove -> /capture/record).
#
# This is the recorder role's Jetson-forward shape: a screenless companion computer
# starts the stack itself; nothing is launched by hand. The unit runs
# scripts/run/recorder-boot.sh (the boot-time source chain + launch) as the installing
# user, so bags land in that user's ~/recordings.
#
# Linux + systemd only, best-effort (warns + returns 0 elsewhere), idempotent. Invoked
# by setup-recorder.sh when install.sh got --service; runnable standalone.
#
# Usage:
#   ./scripts/install/install-recorder-service.sh            # install + enable + start
#   ./scripts/install/install-recorder-service.sh uninstall  # stop + disable + remove
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # item()
cd "$ROOT"

UNIT=/etc/systemd/system/fm-recorder.service
ENVFILE=/etc/fm-recorder.env
WRAPPER="$ROOT/scripts/run/recorder-boot.sh"

# Run the service as the human who installed it, not root — so ~/recordings and the
# RealSense udev access resolve to their account. SUDO_USER covers a `sudo ./install.sh`.
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

usage() {
  cat <<'EOF'
install-recorder-service.sh — install/remove the fm-recorder boot service (Linux)

  (no args)    write the unit, enable it for boot, start it now
  uninstall    stop + disable + remove the unit and its env file
  -h, --help   show this help

The service runs scripts/run/recorder-boot.sh as the installing user: it sources
ROS + the workspace overlay + dds-lan.sh, then launches egocentric_record.launch.py
(camera + tracker + recorder + foxglove bridge). Bags land in ~/recordings. Tune it
via /etc/fm-recorder.env (FM_RECORDER_TRACKER, FM_LAN_IP, ...).
EOF
}

# Guard: the boot service needs Linux + systemd. Off that, warn and let the caller
# carry on (a plain recorder build still works; only the appliance step is skipped).
_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: the recorder boot service is Linux-only — skipping." >&2
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: systemctl not found (no systemd) — skipping the boot service." >&2
    return 1
  fi
  return 0
}

do_install() {
  _require_linux_systemd || return 0
  if [ ! -f "$WRAPPER" ]; then
    echo "ERROR: $WRAPPER missing — cannot install the service." >&2
    return 1
  fi

  item "writing $UNIT (User=$SERVICE_USER, HOME=$SERVICE_HOME, workspace=$ROOT) ..."
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive egocentric recorder (camera + tracker + recorder + foxglove bridge)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
EnvironmentFile=-$ENVFILE
WorkingDirectory=$ROOT
ExecStart=/bin/bash $WRAPPER
Restart=on-failure
RestartSec=5
# Never permanently give up: an appliance that boots before the camera is plugged in
# should keep retrying rather than land in a failed state.
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF

  # Config knobs — write a template only when absent, so a re-install never clobbers a
  # host's tuned values (FM_LAN_IP, tracker off, ...).
  if [ ! -f "$ENVFILE" ]; then
    item "writing $ENVFILE (config knobs — edit, then restart the service to apply) ..."
    sudo tee "$ENVFILE" >/dev/null <<'EOF'
# fm-recorder.service knobs — edit, then: sudo systemctl restart fm-recorder
#
# Pin the DDS LAN interface if auto-detection picks the wrong IP at boot:
#FM_LAN_IP=192.168.1.42
#ROS_DOMAIN_ID=0
# Hand tracker — set off on a host where MediaPipe won't install (e.g. some Jetsons);
# the recorder still captures RGB-D + IMU headless without it:
FM_RECORDER_TRACKER=on
# Arm the recorder (true = armed + idle, waits for a REC command):
FM_RECORDER_RECORD=true
# Run the foxglove bridge here (:8765) for the Mac operator surface:
FM_RECORDER_FOXGLOVE=true
EOF
  fi

  item "enabling + starting fm-recorder.service ..."
  sudo systemctl daemon-reload
  sudo systemctl enable fm-recorder.service
  sudo systemctl restart fm-recorder.service

  cat <<EOF

fm-recorder.service installed and started — it now comes up on every boot.

  status:  systemctl status fm-recorder
  logs:    journalctl -u fm-recorder -f
  stop:    sudo systemctl stop fm-recorder
  config:  sudo nano $ENVFILE   (then: sudo systemctl restart fm-recorder)

From a Mac on the same network, drive REC/STOP against this host's foxglove bridge:
  open src/fm_app/fm_viewer/webgui/index.html?ws=ws://<this-host-ip>:8765
  (or point Foxglove Studio at ws://<this-host-ip>:8765). Bags land in ~/recordings.
EOF
}

do_uninstall() {
  _require_linux_systemd || return 0
  item "stopping + disabling fm-recorder.service (if present) ..."
  sudo systemctl disable --now fm-recorder.service 2>/dev/null || true
  sudo rm -f "$UNIT" "$ENVFILE"
  sudo systemctl daemon-reload 2>/dev/null || true
  item "fm-recorder.service removed."
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
