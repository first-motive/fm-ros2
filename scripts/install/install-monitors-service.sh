#!/usr/bin/env bash
# install-monitors-service.sh — install the rig monitors as their own systemd units.
#
#   ./scripts/install/install-monitors-service.sh            # install + enable + start
#   ./scripts/install/install-monitors-service.sh --uninstall
#
# Two units, one per monitor, both wrapping scripts/service/monitors-boot.sh:
#
#   fm-watchdog.service     rig health — stream liveness, write path, disk, host
#   fm-episode-qa.service   per-take capture QA + the rolling session window
#
# WHY THEIR OWN UNITS rather than entries in the recorder launch:
# on 2026-08-11 a monitor was composed into egocentric_record.launch.py naming a
# package the appliance did not build. `ros2 launch` exited 1 and systemd
# restart-looped fm-recorder.service — capture went down in order to add health
# monitoring. A monitor must never share the fate of the thing it watches. With its
# own unit it fails alone, restarts alone, and can be stopped or masked without
# touching capture.
#
# Both units are deliberately independent of fm-recorder.service: no Requires=, no
# BindsTo=. The monitors are useful whether or not the recorder is up (an absent
# recorder is itself something the watchdog reports), and a monitor must not be able
# to drag the recorder into a restart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/lib.sh" ] && . "$ROOT/lib.sh" || item() { echo "$1"; }

WRAPPER="$ROOT/scripts/service/monitors-boot.sh"
ENVFILE=/etc/fm-monitors.env

# sudo drops the invoking user; the service must run as the human whose HOME holds
# ~/recordings and ~/.ros, not root (recorder-service pattern).
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

_require_linux_systemd() {
	if [ "$(uname -s)" != Linux ]; then
		echo "WARNING: not Linux — skipping the monitor services." >&2
		return 1
	fi
	if ! command -v systemctl >/dev/null 2>&1; then
		echo "WARNING: systemctl not found (no systemd) — skipping the monitor services." >&2
		return 1
	fi
	return 0
}

_write_unit() {
	local role="$1" unit="$2" description="$3"
	item "writing $unit (User=$SERVICE_USER, workspace=$ROOT) ..."
	sudo tee "$unit" >/dev/null <<EOF
[Unit]
Description=$description
After=network-online.target
Wants=network-online.target
# Deliberately NOT Requires=/BindsTo= fm-recorder.service: a monitor must be able to
# run, fail, and restart without touching capture. An absent recorder is itself a
# finding the watchdog reports.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
EnvironmentFile=-$ENVFILE
WorkingDirectory=$ROOT
ExecStart=/bin/bash $WRAPPER $role
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

do_install() {
	_require_linux_systemd || return 0
	if [ ! -f "$WRAPPER" ]; then
		echo "ERROR: $WRAPPER missing — cannot install the monitor services." >&2
		return 1
	fi

	_write_unit watchdog /etc/systemd/system/fm-watchdog.service \
		"First Motive rig health watchdog"
	_write_unit episode_qa /etc/systemd/system/fm-episode-qa.service \
		"First Motive per-episode capture QA"

	# Config knobs — written only when absent, so a re-install never clobbers a host's
	# tuned values (the same rule install-recorder-service.sh follows for its env file).
	if [ ! -f "$ENVFILE" ]; then
		item "writing $ENVFILE (config knobs — edit, then restart the services) ..."
		sudo tee "$ENVFILE" >/dev/null <<'EOF'
# fm-watchdog.service / fm-episode-qa.service knobs — edit, then:
#   sudo systemctl restart fm-watchdog fm-episode-qa
#
# Turn a monitor off without uninstalling it. The wrapper exits 0 when disabled, so
# systemd reads it as "asked not to run" rather than restart-looping it.
FM_MONITORS_WATCHDOG=true
FM_MONITORS_EPISODE_QA=true
#
# Pin the DDS LAN interface if auto-detection picks the wrong IP at boot. This MUST
# match fm-recorder.service's value, or the monitors join a different discovery
# scope and publish where nothing is listening:
#FM_LAN_IP=192.168.1.28
EOF
	fi

	sudo systemctl daemon-reload
	sudo systemctl enable fm-watchdog.service fm-episode-qa.service
	sudo systemctl restart fm-watchdog.service fm-episode-qa.service
	item "monitor services installed and started."
	item "  status:  systemctl status fm-watchdog fm-episode-qa"
	item "  logs:    journalctl -u fm-watchdog -f"
	item "  disable: edit $ENVFILE, then systemctl restart fm-watchdog fm-episode-qa"
}

do_uninstall() {
	_require_linux_systemd || return 0
	sudo systemctl disable --now fm-watchdog.service fm-episode-qa.service 2>/dev/null || true
	sudo rm -f /etc/systemd/system/fm-watchdog.service /etc/systemd/system/fm-episode-qa.service
	sudo systemctl daemon-reload
	item "monitor services removed (left $ENVFILE in place)."
}

case "${1:-}" in
	--uninstall) do_uninstall ;;
	"") do_install ;;
	*) echo "usage: install-monitors-service.sh [--uninstall]" >&2; exit 2 ;;
esac
