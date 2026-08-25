#!/usr/bin/env bash
# Check that the locally hosted archive boundary is visible to Desktop.
set -uo pipefail

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FAIL=0
ok() { printf 'OK: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; FAIL=1; }

if [ -d "$ROOT/install/fm_data_archive" ]; then
  ok "fm_data_archive is built"
else
  bad "fm_data_archive is not built; run setup-processor.sh"
fi

if systemctl cat fm-archive.service >/dev/null 2>&1; then
  ok "fm-archive.service is installed"
else
  bad "fm-archive.service is not installed"
fi

if [ "$(systemctl is-active fm-archive.service 2>/dev/null)" = active ]; then
  ok "fm-archive.service is running"
else
  bad "fm-archive.service is not active; check /etc/fm-archive.env and the journal"
fi

PROBE="$ROOT/scripts/service/bridge-probe.py"
if [ -f "$PROBE" ] && command -v python3 >/dev/null 2>&1; then
  if timeout 40 python3 "$PROBE" /archive/index /archive/status >/dev/null 2>&1; then
    ok "the Desktop bridge advertises the archive topics"
  else
    bad "the Desktop bridge does not advertise the archive topics"
  fi
else
  bad "the bridge probe is unavailable"
fi

exit "$FAIL"
