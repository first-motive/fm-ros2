#!/usr/bin/env bash
# archive-boot.sh — non-interactive bring-up of the B2 archive browser, for the
# fm-archive.service systemd unit (installed by install-archive-service.sh).
#
#   bash scripts/service/archive-boot.sh
#
# Serves the episode archive that lives in Backblaze B2 on /archive/index,
# /archive/detail and /archive/status, so Desktop can list every episode ever
# recorded rather than only the ones still on this host's disk. That distinction
# is the whole point: after a workspace wipe the rig's own /capture/index goes
# empty while the archive does not.
#
# A systemd unit reads NONE of ~/.bashrc, so this sources ROS + the colcon overlay
# + comms.sh explicitly before exec'ing the node. The DDS profile is not optional:
# this appliance pins FastDDS to one LAN interface, and a node started without it
# joins a different discovery scope — it runs, publishes, and is visible to
# nobody. That exact mistake cost two days on fmtower on 2026-08-11.
#
# WHY ITS OWN UNIT, not an entry in the processor launch: on 2026-08-11 a node
# composed into a launch file named a package the appliance had not built, and
# `ros2 launch` exiting 1 restart-looped the whole service. A browser must never
# be able to stop processing. Its own unit fails alone and can be masked without
# touching anything else.
#
# Knobs (set in /etc/fm-archive.env, or inherited from /etc/fm-processor.env):
#   FM_ARCHIVE_ENABLED=true|false   run at all (false exits 0, not a failure)
#   FM_ARCHIVE_CACHE_DIR=<dir>      synced sidecars + manifest
#   FM_ARCHIVE_SYNC_INTERVAL_S=<s>  seconds between automatic sweeps
#   B2_KEY_ID / B2_APP_KEY          the read-only key, scoped to episodes/
#
# No `set -e`: this is a bring-up wrapper ending in `exec`, so the node's exit is
# the service's exit and systemd applies its own Restart= policy.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# A disabled browser exits 0 rather than failing: systemd should read "asked not
# to run" as success, not restart-loop it. Turning it off is an env edit plus a
# restart, with no unit surgery.
if [ "${FM_ARCHIVE_ENABLED:-true}" != true ]; then
	echo "archive-boot: disabled via FM_ARCHIVE_ENABLED — exiting cleanly"
	exit 0
fi

# The credential check happens HERE rather than inside the node, so a missing key
# is one legible line in the journal instead of a repeating boto3 stack trace
# behind a restart loop. The node is read-only and scoped by the key itself; it
# cannot fall back to anything useful without one.
if [ -z "${B2_KEY_ID:-}" ] || [ -z "${B2_APP_KEY:-}" ]; then
	echo "archive-boot: B2_KEY_ID / B2_APP_KEY are unset." >&2
	echo "  Add them to /etc/fm-archive.env (chmod 600), then:" >&2
	echo "    sudo systemctl restart fm-archive" >&2
	echo "  The key must be READ-ONLY and scoped to the episodes/ prefix of" >&2
	echo "  fm-recordings — that restriction is defence in depth behind the" >&2
	echo "  node's own request allowlist, not a substitute for it." >&2
	exit 1
fi

# boto3 reads the standard AWS names; B2's S3-compatible endpoint is otherwise
# identical. Mapped here so the env file names the service it belongs to rather
# than borrowing another cloud's vocabulary.
export AWS_ACCESS_KEY_ID="$B2_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$B2_APP_KEY"

# ROS setup.bash references unset AMENT_*/COLCON_* vars, which `set -u` treats as
# an error — drop nounset just around the sources, then restore it.
set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
# shellcheck disable=SC1091
source "$ROOT/install/setup.bash"
# shellcheck disable=SC1091
source "$ROOT/scripts/env/comms.sh"
set -u

# Fail loudly and immediately if the package is not built, rather than letting
# systemd restart-loop an unresolvable exec. The journal should carry one line
# naming the fix, not a repeating traceback.
if ! ros2 pkg prefix fm_data_archive >/dev/null 2>&1; then
	echo "archive-boot: fm_data_archive is not built in $ROOT/install — run" >&2
	echo "  ./scripts/install/setup-processor.sh" >&2
	exit 1
fi

# boto3 is an optional dependency of the package (requirements-archive.txt); the
# node cannot reach B2 without it, and a missing import is worth naming.
if ! python3 -c "import boto3" >/dev/null 2>&1; then
	echo "archive-boot: boto3 is missing — run" >&2
	echo "  python3 -m pip install -r src/fm_data/fm_data_archive/requirements-archive.txt" >&2
	exit 1
fi

ARGS=()
[ -n "${FM_ARCHIVE_CACHE_DIR:-}" ] && ARGS+=(-p "cache_dir:=$FM_ARCHIVE_CACHE_DIR")
[ -n "${FM_ARCHIVE_SYNC_INTERVAL_S:-}" ] && ARGS+=(-p "sync_interval_s:=$FM_ARCHIVE_SYNC_INTERVAL_S")

echo "archive-boot: starting fm_data_archive/archive_browser"
if [ ${#ARGS[@]} -gt 0 ]; then
	exec ros2 run fm_data_archive archive_browser --ros-args "${ARGS[@]}"
fi
exec ros2 run fm_data_archive archive_browser
