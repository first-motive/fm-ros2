#!/usr/bin/env bash
# Check that the locally hosted archive and uploader boundaries are visible to
# Desktop. This script is read-only; it never enables a unit or changes a queue.
set -uo pipefail

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FAIL=0
ok() { printf 'OK: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; FAIL=1; }

read_env() {
  local file="$1" key="$2" line
  [ -r "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 0
  printf '%s\n' "${line#*=}"
}

ARCHIVE_ENV="${FM_ARCHIVE_ENVFILE:-/etc/fm-archive.env}"
UPLOADER_ENV="${FM_ARCHIVE_UPLOADER_ENVFILE:-/etc/fm-archive-uploader.env}"
reader_enabled="$(read_env "$ARCHIVE_ENV" FM_ARCHIVE_ENABLED)"
uploader_enabled="$(read_env "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_ENABLED)"

if [ -d "$ROOT/install/fm_data_archive" ]; then
  ok "fm_data_archive is built"
else
  bad "fm_data_archive is not built; run setup-processor.sh"
fi

PROBE="$ROOT/scripts/service/bridge-probe.py"

if ! command -v systemctl >/dev/null 2>&1; then
  ok "service state deferred (systemd is unavailable)"
else
  for unit in fm-archive.service fm-archive-uploader.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      ok "$unit is installed"
    elif [ "$unit" = fm-archive.service ] && [ "${reader_enabled:-false}" = false ]; then
      ok "$unit is not installed (reader default-off)"
    elif [ "$unit" = fm-archive-uploader.service ] && [ "${uploader_enabled:-false}" = false ]; then
      ok "$unit is not installed (uploader default-off)"
    else
      bad "$unit is not installed"
    fi
  done
  if [ "${reader_enabled:-false}" = false ]; then
    ok "archive reader is default-off"
  elif [ "$(systemctl is-active fm-archive.service 2>/dev/null)" = active ]; then
    ok "archive reader is running"
  else
    bad "archive reader is enabled but not active; check $ARCHIVE_ENV and the journal"
  fi
  if [ "${uploader_enabled:-false}" = false ]; then
    ok "archive uploader is default-off"
  elif [ "$(systemctl is-active fm-archive-uploader.service 2>/dev/null)" = active ]; then
    ok "archive uploader is running"
  else
    bad "archive uploader is enabled but not active; check $UPLOADER_ENV and the journal"
  fi
fi

if [ -f "$PROBE" ] && command -v python3 >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 &&
   { [ "${reader_enabled:-false}" = true ] || [ "${uploader_enabled:-false}" = true ]; }; then
  topics=()
  if [ "${reader_enabled:-false}" = true ]; then
    # The archive browser's original catalogue/stage contract remains stable;
    # the uploader adds a separate storage-state contract beside it.
    topics+=(/archive/index /archive/status /archive/stage)
  fi
  if [ "${uploader_enabled:-false}" = true ]; then
    # Retry, verify, and delete are closed command channels; delete is a local
    # confirmation request only, never a remote B2 delete API.
    topics+=(/archive/storage/index /archive/storage/status /archive/upload/retry /archive/retention/verify /archive/retention/delete)
  fi
  if timeout 40 python3 "$PROBE" "${topics[@]}" >/dev/null 2>&1; then
    ok "the Desktop bridge advertises the archive topics"
  else
    bad "the Desktop bridge does not advertise the archive topics"
  fi
else
  ok "bridge probe deferred (archive services are disabled or unavailable)"
fi

exit "$FAIL"
