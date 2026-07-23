#!/usr/bin/env bash
# install-processor-service.sh — install (or remove) the systemd unit that auto-starts
# the dataset-processing supervisor on boot, turning the Linux processing host into a
# headless appliance: boot -> process_supervisor up on the capture session's ROS graph,
# and an operator kicks off runs from the desktop app's Process surface (/process/run).
#
# The processing sibling of install-recorder-service.sh: the recorder checkout moves to
# a Jetson later while this role stays on the strong Linux host, each in its own
# workspace. The unit runs scripts/run/processor-boot.sh (the boot-time source chain +
# launch) as the installing user, so output lands in that user's ~/processed.
#
# Linux + systemd only, best-effort (warns + returns 0 elsewhere), idempotent. Invoked
# by setup-processor.sh when install.sh got --service; runnable standalone.
#
# Usage:
#   ./scripts/install/install-processor-service.sh            # install + enable + start
#   ./scripts/install/install-processor-service.sh uninstall  # stop + disable + remove
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # item()
cd "$ROOT"

UNIT=/etc/systemd/system/fm-processor.service
ENVFILE=/etc/fm-processor.env
WRAPPER="$ROOT/scripts/run/processor-boot.sh"

# Run the service as the human who installed it, not root — so ~/recordings and
# ~/processed resolve to their account. SUDO_USER covers a `sudo ./install.sh`.
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

usage() {
  cat <<'EOF'
install-processor-service.sh — install/remove the fm-processor boot service (Linux)

  (no args)    write the unit, enable it for boot, start it now
  uninstall    stop + disable + remove the unit and its env file
  -h, --help   show this help

The service runs scripts/run/processor-boot.sh as the installing user: it sources
ROS + the workspace overlay + dds-lan.sh, then launches process_session.launch.py
(the process_supervisor node). Manifests land in ~/processed. Tune it via
/etc/fm-processor.env (FM_PROCESSOR_RECORDINGS_DIR, FM_PROCESSOR_OUTPUT_DIR, ...).
EOF
}

# Guard: the boot service needs Linux + systemd. Off that, warn and let the caller
# carry on (a plain processor build still works; only the appliance step is skipped).
_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: the processor boot service is Linux-only — skipping." >&2
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
Description=First Motive dataset processor (process_supervisor for the app's Process surface)
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
# Never permanently give up: an appliance that boots before the network (or the
# recorder session) is up should keep retrying rather than land in a failed state.
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF

  # Config knobs — write a template only when absent, so a re-install never clobbers a
  # host's tuned values (custom dirs, a pinned LAN IP, ...).
  if [ ! -f "$ENVFILE" ]; then
    item "writing $ENVFILE (config knobs — edit, then restart the service to apply) ..."
    sudo tee "$ENVFILE" >/dev/null <<'EOF'
# fm-processor.service knobs — edit, then: sudo systemctl restart fm-processor
#
# Pin the DDS LAN interface if auto-detection picks the wrong IP at boot:
#FM_LAN_IP=192.168.1.42
#ROS_DOMAIN_ID=0
# Where the recorder's sessions.jsonl + episode bags live (same host today):
FM_PROCESSOR_RECORDINGS_DIR=~/recordings
# Per-episode processing output root (<id>/manifest.json is the processed marker):
FM_PROCESSOR_OUTPUT_DIR=~/processed
# Processing profile JSON for dataset_process --config (empty = engine default):
FM_PROCESSOR_CONFIG=
# Interpreter for the dataset_process subprocess. Empty auto-uses the workspace's
# .engine-venv (created by setup-processor.sh) so the engine's numpy pin never
# fights another tenant of the host's user site-packages:
#FM_PROCESSOR_ENGINE_PYTHON=
EOF
  fi

  item "enabling + starting fm-processor.service ..."
  sudo systemctl daemon-reload
  sudo systemctl enable fm-processor.service
  sudo systemctl restart fm-processor.service

  cat <<EOF

fm-processor.service installed and started — it now comes up on every boot.

  status:  systemctl status fm-processor
  logs:    journalctl -u fm-processor -f
  stop:    sudo systemctl stop fm-processor
  config:  sudo nano $ENVFILE   (then: sudo systemctl restart fm-processor)

Kick off processing from the desktop app's Process window (it rides the capture
session's foxglove bridge). Manifests land under ~/processed/<episode_id>/.
EOF
}

do_uninstall() {
  _require_linux_systemd || return 0
  item "stopping + disabling fm-processor.service (if present) ..."
  sudo systemctl disable --now fm-processor.service 2>/dev/null || true
  sudo rm -f "$UNIT" "$ENVFILE"
  sudo systemctl daemon-reload 2>/dev/null || true
  item "fm-processor.service removed."
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
