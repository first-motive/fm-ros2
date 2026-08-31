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
# Offline CI exercises the real transaction against an explicit temporary
# root. Keep this seam opt-in; normal callers cannot redirect a sudo install
# through an arbitrary inherited path.
if [ "${FM_ARCHIVE_SERVICE_TEST_MODE:-0}" = 1 ]; then
  : "${FM_ARCHIVE_SERVICE_TEST_ROOT:?FM_ARCHIVE_SERVICE_TEST_ROOT is required in test mode}"
  UNIT="$FM_ARCHIVE_SERVICE_TEST_ROOT/systemd/fm-archive.service"
  ENVFILE="$FM_ARCHIVE_SERVICE_TEST_ROOT/etc/fm-archive.env"
fi
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

usage() {
  cat <<'EOF'
install-archive-service.sh — install/remove the processor archive browser (Linux)

  (no args)    write the unit, enable it for boot, start it now
  uninstall    stop + disable + remove the unit (preserve the env and cache)
  --dry-run    print the managed paths and actions without changing the host
  -h, --help   show this help

The browser reads only the read-scoped Backblaze credential in
/etc/fm-archive.env. It never reads the uploader credential or accepts a
delete request. In the container runtime the service requires an already
running processor container and cannot create, recreate, or stop it.
EOF
}

do_install() {
  local dry_run="${1:-false}"
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

  if [ "$dry_run" = true ]; then
    item "would write $UNIT (User=$SERVICE_USER, workspace=$ROOT, runtime=$runtime)"
    item "would preserve or create mode-600 $ENVFILE"
    item "would enable + restart fm-archive.service"
    return 0
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
# Keep the existing-only lifecycle guard after the env file so an operator
# cannot accidentally override it with a stale setting in /etc/fm-archive.env.
Environment=FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1
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
# Enable only after the read-only processor-archive B2 application key is
# installed here. This key is separate from the uploader key and is scoped to
# the episodes/ prefix; it cannot write or delete objects.
FM_ARCHIVE_ENABLED=false
BACKBLAZE_B2_PROCARCH_KEY_ID=
BACKBLAZE_B2_PROCARCH_APPLICATION_KEY=

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
  ""|install) do_install false ;;
  --dry-run) do_install true ;;
  uninstall) do_uninstall ;;
  -h|--help) usage ;;
  *) echo "usage: install-archive-service.sh [install|uninstall|--dry-run]" >&2; exit 2 ;;
esac
