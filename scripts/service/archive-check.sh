#!/usr/bin/env bash
# archive-check.sh — is the B2 archive browser actually working end to end?
#
#   bash scripts/service/archive-check.sh
#
# Written for an engineer bringing this up with nobody to ask. Every check below
# is a failure that has really happened on this appliance, and each is silent in
# the obvious places:
#
#   * the package missing from the build set, so `ros2 run` cannot resolve it
#   * the service "active" while publishing into a discovery scope nobody shares
#   * a B2 key that is unset, wrong, or scoped to the wrong prefix
#   * a cache that synced zero episodes and looks identical to an empty archive
#
# `systemctl is-active` answers none of those. This does, and prints the next
# action rather than a status code to interpret.
#
# Exit 0 when Desktop will see the archive; 1 otherwise.
set -uo pipefail

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}"
FAIL=0
ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=1; }
note() { printf "        %s\n" "$1"; }

echo "fm archive browser check"
echo

# 1. Built. A launch or `ros2 run` naming an unbuilt package fails in a way the
#    journal reports as a traceback rather than as the one fact that matters.
if [ -d "$ROOT/install/fm_data_archive" ]; then
	ok "fm_data_archive built"
else
	bad "fm_data_archive NOT built in $ROOT/install"
	note "fix: cd $ROOT && ./scripts/install/setup-processor.sh"
fi

# 2. boto3. The node cannot reach B2 without it and it is an OPTIONAL dependency,
#    so a workspace can build cleanly and still be unable to sync.
if python3 -c "import boto3" >/dev/null 2>&1; then
	ok "boto3 present"
else
	bad "boto3 missing — the node cannot reach B2"
	note "fix: python3 -m pip install -r src/fm_data/fm_data_archive/requirements-archive.txt"
fi

# 3. Installed, running, and enabled. Not enabled is the failure that looks like
#    "it worked yesterday".
if ! systemctl cat fm-archive.service >/dev/null 2>&1; then
	bad "fm-archive.service not installed"
	note "fix: cd $ROOT && ./scripts/install/install-archive-service.sh"
else
	if [ "$(systemctl is-active fm-archive.service)" = active ]; then
		ok "fm-archive.service running"
	else
		bad "fm-archive.service is $(systemctl is-active fm-archive.service)"
		note "why: journalctl -u fm-archive -n 40 --no-pager"
	fi
	if [ "$(systemctl is-enabled fm-archive.service 2>/dev/null)" = enabled ]; then
		ok "fm-archive.service starts at boot"
	else
		bad "fm-archive.service NOT enabled — will not survive a reboot"
		note "fix: sudo systemctl enable fm-archive.service"
	fi
fi

# 4. The credential. Checked for PRESENCE only — this script never prints a key,
#    and a wrong one shows up as an empty index in check 5 rather than here.
if sudo grep -qE '^B2_KEY_ID=.+' /etc/fm-archive.env 2>/dev/null &&
   sudo grep -qE '^B2_APP_KEY=.+' /etc/fm-archive.env 2>/dev/null; then
	ok "a B2 key is set in /etc/fm-archive.env"
else
	bad "B2_KEY_ID / B2_APP_KEY are empty in /etc/fm-archive.env"
	note "create one in the B2 console: Add a New Application Key"
	note "  -> bucket fm-recordings -> Read Only -> file name prefix episodes/"
	note "then: sudo systemctl restart fm-archive"
fi

# 5. The only check that proves Desktop will see anything: does the node actually
#    publish a NON-EMPTY index? A service can be active, credentialed, and still
#    publishing zero episodes — a wrong prefix scope looks exactly like an empty
#    archive from the outside, which is why the count is what gets asserted.
if command -v ros2 >/dev/null 2>&1; then
	OUT="$(timeout 30 ros2 topic echo /archive/index --once 2>/dev/null)"
	COUNT="$(printf '%s' "$OUT" | grep -o '"episode_id"' | wc -l | tr -d ' ')"
	if [ -z "$OUT" ]; then
		bad "/archive/index published nothing within 30s"
		note "the service can be active and still sit in a separate DDS scope."
		note "most likely: it resolved a different FM_LAN_IP than the processor."
		note "  systemctl cat fm-archive | grep EnvironmentFile"
		note "then: sudo systemctl restart fm-archive"
	elif [ "$COUNT" -eq 0 ]; then
		bad "/archive/index is published but EMPTY (0 episodes)"
		note "the node is healthy and the archive looks empty to it. Most likely"
		note "the key is scoped to the wrong bucket or prefix — it needs read on"
		note "the episodes/ prefix of fm-recordings."
		note "watch a sweep: journalctl -u fm-archive -f | grep 'archive sync'"
	else
		ok "/archive/index carries $COUNT episodes"
	fi
else
	note "ros2 not on PATH — skipping the index check"
	note "  source /opt/ros/humble/setup.bash && source $ROOT/install/setup.bash"
fi

echo
if [ "$FAIL" -eq 0 ]; then
	echo "PASS — Desktop's archive source will list these episodes."
else
	echo "FAIL — fix the items above, then re-run this script."
fi
exit "$FAIL"
