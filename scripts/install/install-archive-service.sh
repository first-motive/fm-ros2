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
PROCESSOR_ENVFILE=/etc/fm-processor.env
# Offline CI exercises the real transaction against an explicit temporary
# root. Keep this seam opt-in; normal callers cannot redirect a sudo install
# through an arbitrary inherited path.
if [ "${FM_ARCHIVE_SERVICE_TEST_MODE:-0}" = 1 ]; then
  : "${FM_ARCHIVE_SERVICE_TEST_ROOT:?FM_ARCHIVE_SERVICE_TEST_ROOT is required in test mode}"
  UNIT="$FM_ARCHIVE_SERVICE_TEST_ROOT/systemd/fm-archive.service"
  ENVFILE="$FM_ARCHIVE_SERVICE_TEST_ROOT/etc/fm-archive.env"
  PROCESSOR_ENVFILE="$FM_ARCHIVE_SERVICE_TEST_ROOT/etc/fm-processor.env"
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
  local processor_recordings existing_recordings
  runtime="$(fm_processor_runtime)" || return 1
  # The recording root is resolved here, on the host, and baked into the env
  # file the way the uploader installer does. The boot wrapper runs inside the
  # processor container in the container runtime, where /etc/fm-processor.env
  # is not mounted, so a read there is always empty and falls back to
  # /data/recordings — the wrong root on a rig with a custom one.
  processor_recordings="$(FM_PROCESSOR_ENV_FILE="$PROCESSOR_ENVFILE" \
    fm_processor_env FM_PROCESSOR_RECORDINGS_DIR)"
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
# A deliberate stop first ends the wrapper inside the container, then systemd
# sends SIGTERM to this unit's compose exec, which exits 143. Without this the
# journal records every clean stop as a failure, so a real one stops standing out.
SuccessExitStatus=143
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  if [ ! -f "$ENVFILE" ]; then
    local archive_data_root=/data
    if [ ! -d "$archive_data_root" ] || [ ! -w "$archive_data_root" ]; then
      archive_data_root="$SERVICE_HOME"
    fi
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
FM_ARCHIVE_LEROBOT_STAGE_DIR=/data/lerobot-staged
FM_ARCHIVE_LEROBOT_STAGE_ENABLED=false

# Where a staged episode is published so the processor can reach it. Filled
# from the processor's own configured root at install; a wrong value publishes
# where Process cannot find the bag, so it fails closed rather than guessing.
FM_ARCHIVE_RECORDINGS_DIR=
FM_ARCHIVE_MAX_OBJECTS=16
FM_ARCHIVE_MAX_TOTAL_BYTES=2147483648
FM_ARCHIVE_MAX_EPISODES=32
FM_ARCHIVE_RETENTION_DAYS=30
FM_ARCHIVE_MAX_ATTEMPTS=3
EOF
    if [ "$archive_data_root" != /data ]; then
      sudo sed -i.bak "s#=/data/#=$archive_data_root/#g" "$ENVFILE"
      sudo rm -f "${ENVFILE}.bak"
    fi
  fi
  # The env file is root-owned and mode 0600. Read only the one path field
  # through the same privilege boundary the writes use.
  existing_recordings="$(sudo sed -n 's/^FM_ARCHIVE_RECORDINGS_DIR=//p' "$ENVFILE" | tail -1)"
  if [ -n "$processor_recordings" ] && [ -z "$existing_recordings" ]; then
    # A file written before the root was baked here, or by this install just
    # now: fill the processor's root so the browser publishes where it reads.
    sudo sed -i.bak "s#^FM_ARCHIVE_RECORDINGS_DIR=\$#FM_ARCHIVE_RECORDINGS_DIR=$processor_recordings#" "$ENVFILE"
    sudo rm -f "${ENVFILE}.bak"
  elif [ -n "$processor_recordings" ] && [ "$processor_recordings" != "$existing_recordings" ]; then
    echo "ERROR: archive recordings root differs from the processor root." >&2
    echo "       archive:   $existing_recordings" >&2
    echo "       processor: $processor_recordings" >&2
    return 1
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
