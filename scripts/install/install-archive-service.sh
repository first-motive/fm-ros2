#!/usr/bin/env bash
# Install the local archive browser as a processor-side systemd service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"
# shellcheck disable=SC1091
. "$ROOT/scripts/internal/lib-processor.sh"

UNIT=/etc/systemd/system/fm-archive.service
ENVFILE=/etc/fm-archive.env
WRAPPER="$ROOT/scripts/service/archive-boot.sh"
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ] || ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: the archive service needs Linux and systemd — skipping." >&2
    return 1
  fi
}

do_install() {
  _require_linux_systemd || return 0
  [ -f "$WRAPPER" ] || { echo "ERROR: $WRAPPER is missing." >&2; return 1; }

  # Same runtime split as fm-processor.service (#127): in the container runtime
  # the wrapper runs through compose, since ROS lives in the image.
  local runtime exec_start exec_stop="" requires=""
  runtime="$(fm_processor_runtime)" || return 1
  if [ "$runtime" = container ]; then
    exec_start="/bin/bash $ROOT/scripts/service/container-exec.sh scripts/service/archive-boot.sh"
    exec_stop="ExecStop=/bin/bash $ROOT/scripts/service/container-exec.sh stop archive_browser"
    requires="Requires=docker.service"
  else
    exec_start="/bin/bash $WRAPPER"
  fi

  item "writing $UNIT (User=$SERVICE_USER, workspace=$ROOT, runtime=$runtime) ..."
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive local recording archive browser
After=network-online.target fm-processor.service docker.service
Wants=network-online.target
$requires
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
EnvironmentFile=-$ENVFILE
WorkingDirectory=$ROOT
ExecStart=$exec_start
$exec_stop
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  if [ ! -f "$ENVFILE" ]; then
    item "writing disabled archive configuration at $ENVFILE ..."
    sudo tee "$ENVFILE" >/dev/null <<'EOF'
# Enable only after a read-only B2 application key is installed here.
FM_ARCHIVE_ENABLED=false
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=

# Local staging is a separate opt-in. Desktop never receives these values.
FM_ARCHIVE_STAGE_ENABLED=false
FM_ARCHIVE_CACHE_DIR=
FM_ARCHIVE_STAGE_DIR=

# The LeRobot catalogue is a processor-owned closed JSON file. Empty keeps the
# source unpublished; Desktop cannot provide a bucket prefix or catalogue path.
FM_ARCHIVE_LEROBOT_CATALOGUE_FILE=
FM_ARCHIVE_LEROBOT_STAGE_DIR=~/.cache/fm-archive/lerobot-staged
FM_ARCHIVE_LEROBOT_STAGE_ENABLED=false
FM_ARCHIVE_MAX_OBJECTS=16
FM_ARCHIVE_MAX_TOTAL_BYTES=2147483648
FM_ARCHIVE_MAX_EPISODES=32
FM_ARCHIVE_RETENTION_DAYS=30
FM_ARCHIVE_MAX_ATTEMPTS=3
EOF
  fi
  # Re-apply the private mode on every install. A prior manual edit or restore
  # must not leave the read-only application key world-readable.
  sudo chmod 600 "$ENVFILE"

  sudo systemctl daemon-reload
  sudo systemctl enable fm-archive.service
  sudo systemctl restart fm-archive.service
  item "archive service installed; enable it in $ENVFILE after adding the read-only key."
}

do_uninstall() {
  _require_linux_systemd || return 0
  sudo systemctl disable --now fm-archive.service 2>/dev/null || true
  sudo rm -f "$UNIT"
  sudo systemctl daemon-reload 2>/dev/null || true
  item "archive service removed; $ENVFILE and local staged data were preserved."
}

case "${1:-}" in
  ""|install) do_install ;;
  uninstall) do_uninstall ;;
  *) echo "usage: install-archive-service.sh [install|uninstall]" >&2; exit 2 ;;
esac
