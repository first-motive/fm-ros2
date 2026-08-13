#!/usr/bin/env bash
# monitors-check.sh — is rig health monitoring actually working end to end?
#
#   bash scripts/service/monitors-check.sh
#
# Written for an engineer bringing up a rig with nobody to ask. Every check below
# failed for real on fmtower during bring-up, each one looking like a different
# problem, and each is silent in the obvious places:
#
#   * services "active" while publishing into a discovery scope nobody shares
#   * packages missing from the appliance build set, so a launch exits 1
#   * FM_LAN_IP unset or wrong — nodes run and are visible to no one
#   * a bridge that never advertises the topics the desktop app subscribes to
#
# "systemctl is-active" answers none of those. This does, and prints the next
# action rather than a status code to interpret.
#
# Exit 0 when the desktop app will show live health; 1 otherwise.
set -uo pipefail

# Resolve the workspace from this script's own location (scripts/service/../..),
# so it works from any cwd. FM_ROOT overrides for a copy run outside the tree.
ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}"
if [ ! -d "${ROOT:-/nonexistent}/install" ] && [ ! -d "${ROOT:-/nonexistent}/src" ]; then
	echo "error: $ROOT is not an fm_ros2 workspace." >&2
	echo "       run this from the checkout, or set FM_ROOT=/path/to/fm_ros2" >&2
	exit 2
fi
FAIL=0
ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=1; }
note() { printf "        %s\n" "$1"; }

echo "fm rig monitoring check"
echo

# 1. Built. A launch naming an unbuilt package exits 1 and systemd restart-loops
#    it; the journal shows a stack trace rather than the one fact that matters.
for pkg in fm_data_watchdog fm_data_episode_qa; do
	if [ -d "$ROOT/install/$pkg" ]; then
		ok "$pkg built"
	else
		bad "$pkg NOT built in $ROOT/install"
		note "fix: cd $ROOT && ./scripts/install/setup-recorder.sh"
	fi
done

# 2. Installed and running as services, not as somebody's terminal.
for unit in fm-watchdog fm-episode-qa; do
	if ! systemctl list-unit-files "$unit.service" >/dev/null 2>&1 \
		|| ! systemctl cat "$unit.service" >/dev/null 2>&1; then
		bad "$unit.service not installed"
		note "fix: cd $ROOT && ./scripts/install/install-monitors-service.sh"
	elif [ "$(systemctl is-active "$unit.service")" = active ]; then
		ok "$unit.service running"
	else
		bad "$unit.service is $(systemctl is-active "$unit.service")"
		note "why: journalctl -u $unit -n 30 --no-pager"
	fi
done

# 3. Enabled, or it all disappears at the next reboot — the failure that looks
#    like "it worked yesterday".
for unit in fm-watchdog fm-episode-qa; do
	if [ "$(systemctl is-enabled "$unit.service" 2>/dev/null)" = enabled ]; then
		ok "$unit.service starts at boot"
	else
		bad "$unit.service NOT enabled — will not survive a reboot"
		note "fix: sudo systemctl enable $unit.service"
	fi
done

# 4. The DDS interface. Wrong or unset FM_LAN_IP is the nastiest failure here:
#    everything reports healthy and nothing is visible, because this appliance
#    pins FastDDS to one interface (scripts/env/dds-lan.sh).
LAN_IP="$(grep -sE '^FM_LAN_IP=' /etc/fm-recorder.env | cut -d= -f2)"
if [ -z "$LAN_IP" ]; then
	note "FM_LAN_IP unset in /etc/fm-recorder.env — DDS auto-detects the interface"
	note "  pin it if this host has several: Docker bridges and VPNs break discovery"
elif hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$LAN_IP"; then
	ok "FM_LAN_IP=$LAN_IP is a real interface on this host"
else
	bad "FM_LAN_IP=$LAN_IP is NOT an address on this host"
	note "this host has: $(hostname -I)"
	note "fix: correct /etc/fm-recorder.env, then sudo systemctl restart fm-recorder"
fi

# 5. The only check that proves the desktop app will see anything: are the topics
#    on the graph? Everything above can pass while this fails.
set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash 2>/dev/null
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash" 2>/dev/null
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh" 2>/dev/null
set -u
TOPICS="$(timeout 25 ros2 topic list --no-daemon 2>/dev/null)"
for t in /watchdog/active /episode_qa/session; do
	if printf '%s\n' "$TOPICS" | grep -qx "$t"; then
		ok "$t is on the ROS graph"
	else
		bad "$t is NOT on the graph — the desktop app will show nothing"
		note "the services can be running and still land in a separate DDS scope."
		note "fix: sudo systemctl restart fm-recorder fm-watchdog fm-episode-qa"
		note "if that does not clear it, reboot — stale DDS participants survive"
		note "a service restart but never a boot."
	fi
done

echo
if [ "$FAIL" -eq 0 ]; then
	echo "PASS — open the desktop app; the Record screen shows live rig health."
	echo "       An empty strip then means nothing is wrong, which is the point."
else
	echo "FAIL — fix the items above, then re-run this script."
fi
exit "$FAIL"
