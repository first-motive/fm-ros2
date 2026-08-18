#!/usr/bin/env bash
# install-archive-service.sh — install the B2 archive browser as its own systemd unit.
#
#   ./scripts/install/install-archive-service.sh            # install + enable + start
#   ./scripts/install/install-archive-service.sh --uninstall
#
# fm-archive.service wraps scripts/service/archive-boot.sh, serving the episode
# archive on /archive/index, /archive/detail and /archive/status so Desktop can
# list every episode ever recorded — not only the ones still on this host's disk.
#
# WHY ITS OWN UNIT rather than an entry in the processor launch: on 2026-08-11 a
# node composed into a launch file named a package the appliance had not built,
# `ros2 launch` exited 1, and systemd restart-looped the whole service. A browser
# must never be able to stop processing. With its own unit it fails alone,
# restarts alone, and can be masked without touching anything else.
#
# Deliberately independent of fm-processor.service: no Requires=, no BindsTo=.
# The archive is readable whether or not processing is up, and a browser must not
# be able to drag the processor into a restart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/lib.sh" ] && . "$ROOT/lib.sh" || item() { echo "$1"; }

UNIT=/etc/systemd/system/fm-archive.service
WRAPPER="$ROOT/scripts/service/archive-boot.sh"
ENVFILE=/etc/fm-archive.env

# sudo drops the invoking user; the service runs as the human whose HOME holds
# the cache, not root (the recorder/processor pattern).
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

_require_linux_systemd() {
	if [ "$(uname -s)" != Linux ]; then
		echo "WARNING: not Linux — skipping the archive service." >&2
		return 1
	fi
	if ! command -v systemctl >/dev/null 2>&1; then
		echo "WARNING: systemctl not found — skipping the archive service." >&2
		return 1
	fi
	return 0
}

do_install() {
	_require_linux_systemd || return 0
	if [ ! -f "$WRAPPER" ]; then
		echo "ERROR: $WRAPPER missing — cannot install the archive service." >&2
		return 1
	fi

	item "writing $UNIT (User=$SERVICE_USER, workspace=$ROOT) ..."
	sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive B2 episode archive browser
After=network-online.target
Wants=network-online.target
# ORDER after the processor, but do not DEPEND on it. After= only sequences
# startup; Requires=/BindsTo= would couple fate, and the archive is readable
# whether or not processing is up. The ordering exists because this appliance
# pins FastDDS to one interface, and a participant joining while the processor's
# own participants are still coming up can land in a separate discovery scope —
# running, publishing, and visible to nobody.
After=fm-processor.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
WorkingDirectory=$ROOT
# The PROCESSOR's env file first, the archive's own second. Order matters:
# FM_LAN_IP pins FastDDS to one interface, and a node that does not read it lets
# auto-detection pick a DIFFERENT address on a multi-homed host — two DDS scopes
# on one machine, every service healthy, and nothing visible to the operator.
# That cost two days on fmtower. Later entries win, so the archive's own file
# stays authoritative for its own knobs while inheriting the shared DDS setting.
EnvironmentFile=-/etc/fm-processor.env
EnvironmentFile=-$ENVFILE
ExecStart=/bin/bash $WRAPPER
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

	# Written only when absent, so a re-install never clobbers a host's real key.
	if [ ! -f "$ENVFILE" ]; then
		item "writing $ENVFILE (EDIT IT: the B2 key goes here) ..."
		sudo tee "$ENVFILE" >/dev/null <<'EOF'
# fm-archive.service knobs — edit, then: sudo systemctl restart fm-archive
#
# The Backblaze B2 application key. It MUST be read-only and scoped to the
# episodes/ prefix of the fm-recordings bucket. That restriction is defence in
# depth BEHIND the node's own request allowlist, not a substitute for it: the
# allowlist stops Desktop naming an object, and the key stops this host reaching
# one even if the allowlist is ever bypassed.
#
# Create it in the B2 console: Add a New Application Key -> bucket fm-recordings
# -> Read Only -> file name prefix episodes/
B2_KEY_ID=
B2_APP_KEY=
#
# Turn the browser off without uninstalling it. The wrapper exits 0 when
# disabled, so systemd reads it as "asked not to run" rather than restart-looping.
FM_ARCHIVE_ENABLED=true
#
# Where synced sidecars and the manifest live. Small: ~2.7 KB per episode, so
# 10,000 episodes is under 30 MB.
#FM_ARCHIVE_CACHE_DIR=~/.cache/fm-archive
#
# Seconds between automatic sweeps. Sidecars are immutable and nothing is ever
# deleted, so a sweep only ever discovers NEW episodes — it never revalidates.
#FM_ARCHIVE_SYNC_INTERVAL_S=900
EOF
		sudo chmod 600 "$ENVFILE"
	fi

	sudo systemctl daemon-reload
	sudo systemctl enable fm-archive.service
	sudo systemctl restart fm-archive.service
	item "archive service installed."
	item "  NEXT: put the B2 key in $ENVFILE, then: sudo systemctl restart fm-archive"
	item "  status:  systemctl status fm-archive"
	item "  logs:    journalctl -u fm-archive -f"
	item "  verify:  ros2 topic echo /archive/index --once"
}

do_uninstall() {
	_require_linux_systemd || return 0
	sudo systemctl disable --now fm-archive.service 2>/dev/null || true
	sudo rm -f "$UNIT"
	sudo systemctl daemon-reload
	item "archive service removed (left $ENVFILE in place)."
}

case "${1:-}" in
	--uninstall|uninstall) do_uninstall ;;
	"") do_install ;;
	*) echo "usage: install-archive-service.sh [--uninstall]" >&2; exit 2 ;;
esac
