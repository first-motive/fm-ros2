#!/usr/bin/env bash
# test-data-root.sh — which directory the roles read and write.
#
#   ./scripts/ci/test-data-root.sh
#
# One machine has one data root, and every process on it has to agree on which.
# The card is what they agree through: fm-setup writes it, and everything else
# reads it. Deriving the root from a checkout's own location looked equivalent
# and was not — on fm-ws-01 the card says /opt/fm while the checkout sits at
# /home/fm/fm, so the derivation answered /home/fm/fm/data, found nothing, and
# fell back to HOME. Recordings written to the wrong one of two plausible paths
# are the one loss on a rig nobody can undo.
#
# The container is the case that keeps the derivation: there the checkout is
# mounted at /ws and the root at /data, so the parent of the checkout is the
# root, and no card need be mounted for it to resolve.
#
# Runs against temp directories; reads no real card and creates nothing outside.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../../lib.sh disable=SC1091
. ./lib.sh

echo "== the card decides, wherever the checkout sits =="
# fm-ws-01's shape: a card naming one workspace, a checkout under another.
mkdir -p "$WORK/opt/fm/data" "$WORK/home/fm/fm/fm_ros2"
cat > "$WORK/machine.json" <<JSON
{"schema_version": 1, "name": "fm-ws-01", "role": "workstation", "workspace": "$WORK/opt/fm"}
JSON

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed, so the card cannot be read here"
else
  got="$(FM_MACHINE_FILE="$WORK/machine.json" fm_data_root "$WORK/home/fm/fm/fm_ros2" "$WORK/home/fm")"
  if [ "$got" = "$WORK/opt/fm/data" ]; then
    pass "a checkout outside the card's workspace still resolves the card's root"
  else
    fail "resolved $got, not the card's $WORK/opt/fm/data — the split this prevents"
  fi
fi

echo "== the container resolves without a card =="
# The checkout at /ws, the root at /data: the parent of the checkout is the root.
mkdir -p "$WORK/ws" "$WORK/data"
got="$(FM_MACHINE_FILE="$WORK/absent.json" fm_data_root "$WORK/ws" "$WORK/home/fm")"
if [ "$got" = "$WORK/data" ]; then
  pass "with no card, the directory beside the checkout is the root"
else
  fail "resolved $got, not the mounted $WORK/data"
fi

echo "== a card naming an unusable root does not strand the role =="
cat > "$WORK/absent-root.json" <<JSON
{"schema_version": 1, "workspace": "$WORK/nowhere"}
JSON
if command -v jq >/dev/null 2>&1; then
  got="$(FM_MACHINE_FILE="$WORK/absent-root.json" fm_data_root "$WORK/ws" "$WORK/home/fm")"
  if [ "$got" = "$WORK/data" ]; then
    pass "a card whose root is missing falls through to the checkout's neighbour"
  else
    fail "resolved $got rather than falling through"
  fi
fi

echo "== an empty fallback is refused, never returned =="
# HOME is unset in a systemd unit that does not set it, and an empty root would
# put the role's directories at the filesystem root instead of failing visibly.
if (FM_MACHINE_FILE="$WORK/absent.json" HOME='' fm_data_root "$WORK/nowhere" "" >/dev/null 2>&1); then
  fail "an empty fallback was returned as a root"
else
  pass "an empty fallback is refused"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "data root: all checks passed"
