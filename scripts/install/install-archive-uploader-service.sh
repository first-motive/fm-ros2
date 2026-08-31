#!/usr/bin/env bash
# Install the processor-side Backblaze uploader as an independent systemd service.
#
# The service is intentionally separate from fm-archive.service. The browser has
# a read-only processor-archive key; this unit has the write-scoped fm-recordings
# key. Both units run as the appliance user and both leave the processor
# container lifecycle to fm-processor.service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"
# shellcheck disable=SC1091
. "$ROOT/scripts/internal/lib-processor.sh"

UNIT=/etc/systemd/system/fm-archive-uploader.service
ENVFILE=/etc/fm-archive-uploader.env
# Offline CI exercises the real transaction against an explicit temporary
# root. Keep this seam opt-in; normal callers cannot redirect a sudo install
# through an arbitrary inherited path.
if [ "${FM_ARCHIVE_UPLOADER_SERVICE_TEST_MODE:-0}" = 1 ]; then
  : "${FM_ARCHIVE_UPLOADER_SERVICE_TEST_ROOT:?FM_ARCHIVE_UPLOADER_SERVICE_TEST_ROOT is required in test mode}"
  UNIT="$FM_ARCHIVE_UPLOADER_SERVICE_TEST_ROOT/systemd/fm-archive-uploader.service"
  ENVFILE="$FM_ARCHIVE_UPLOADER_SERVICE_TEST_ROOT/etc/fm-archive-uploader.env"
fi
WRAPPER="$ROOT/scripts/service/archive-uploader-boot.sh"
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

usage() {
  cat <<'EOF'
install-archive-uploader-service.sh — install/remove the archive uploader (Linux)

  (no args)    write the unit, enable it for boot, start it now
  uninstall    stop + disable + remove the unit (preserve env and queue state)
  --dry-run    print the managed paths and actions without changing the host
  -h, --help   show this help

The uploader reads only the write-scoped Backblaze credential in
/etc/fm-archive-uploader.env. The key must not have remote-delete permission.
Local deletion is disabled by default, the minimum retention is 30 days, and
the eligibility window is 15 minutes by default.
EOF
}

_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ] || ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: the archive uploader needs Linux and systemd — skipping." >&2
    return 1
  fi
}

do_install() {
  local dry_run="${1:-false}"
  _require_linux_systemd || return 0
  [ -f "$WRAPPER" ] || { echo "ERROR: $WRAPPER is missing." >&2; return 1; }

  local runtime exec_start exec_stop="" requires=""
  runtime="$(fm_processor_runtime)" || return 1
  if [ "$runtime" = container ]; then
    exec_start="/bin/bash $ROOT/scripts/service/container-exec.sh scripts/service/archive-uploader-boot.sh"
    exec_stop="ExecStop=/bin/bash $ROOT/scripts/service/container-exec.sh stop archive_uploader"
    requires="Requires=docker.service"
  else
    exec_start="/bin/bash $WRAPPER"
  fi

  if [ "$dry_run" = true ]; then
    item "would write $UNIT (User=$SERVICE_USER, workspace=$ROOT, runtime=$runtime)"
    item "would preserve or create mode-600 $ENVFILE"
    item "would enable + restart fm-archive-uploader.service"
    return 0
  fi

  item "writing $UNIT (User=$SERVICE_USER, workspace=$ROOT, runtime=$runtime) ..."
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive Backblaze recording archive uploader
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
# cannot accidentally override it with a stale setting in the uploader file.
Environment=FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1
# In the container runtime, this unit may exec only into the processor container
# that fm-processor.service already prepared. It must never run compose up.
WorkingDirectory=$ROOT
ExecStart=$exec_start
$exec_stop
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

  if [ ! -f "$ENVFILE" ]; then
    item "writing disabled archive uploader configuration at $ENVFILE ..."
    sudo tee "$ENVFILE" >/dev/null <<'EOF'
# Enable only after the write-scoped `rig-uploader` B2 application key is
# provisioned. The key must cover the approved recording prefixes but MUST NOT
# have delete permission. This file is independent from /etc/fm-archive.env.
FM_ARCHIVE_UPLOADER_ENABLED=false
BACKBLAZE_B2_FMREC_KEY_ID=
BACKBLAZE_B2_FMREC_APPLICATION_KEY=

# Workspace-owned paths. Keep these under the existing processor bind mounts.
FM_ARCHIVE_UPLOADER_RECORDINGS_DIR=/data/recordings
FM_ARCHIVE_UPLOADER_STATE_DIR=~/fm-data-runs/archive-uploader

# Safe first-release policy. Do not lower the retention or eligibility floors.
FM_ARCHIVE_UPLOADER_DRY_RUN=false
FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS=30
FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES=15
FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS=1
FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S=8388608
FM_ARCHIVE_UPLOADER_DELETE_ENABLED=false

# Automatic upload stays blocked until a person verifies the Backblaze console
# cap and records fresh evidence here. Backblaze exposes Object Lock through
# its API, but account caps only through the console. Both byte values must be
# positive, the verified cap must meet the required cap, and the timestamp must
# be no more than 24 hours old when the service starts.
FM_ARCHIVE_STORAGE_CAP_BYTES=
FM_ARCHIVE_REQUIRED_STORAGE_CAP_BYTES=
FM_ARCHIVE_STORAGE_CAP_VERIFIED_AT=
EOF
  fi
  # Re-apply private mode on every install. The file contains a write authority.
  sudo chmod 600 "$ENVFILE"

  sudo systemctl daemon-reload
  sudo systemctl enable fm-archive-uploader.service
  sudo systemctl restart fm-archive-uploader.service
  item "archive uploader service installed; enable it in $ENVFILE after adding the write-scoped key."
}

do_uninstall() {
  _require_linux_systemd || return 0
  sudo systemctl disable --now fm-archive-uploader.service 2>/dev/null || true
  sudo rm -f "$UNIT"
  sudo systemctl daemon-reload 2>/dev/null || true
  item "archive uploader service removed; $ENVFILE and queue state were preserved."
}

case "${1:-}" in
  ""|install) do_install false ;;
  --dry-run) do_install true ;;
  uninstall) do_uninstall ;;
  -h|--help) usage ;;
  *) echo "usage: install-archive-uploader-service.sh [install|uninstall|--dry-run]" >&2; exit 2 ;;
esac
