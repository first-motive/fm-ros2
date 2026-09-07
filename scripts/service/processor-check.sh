#!/usr/bin/env bash
# processor-check.sh — can the processor still serve private datasets to Desktop?
#
#   bash scripts/service/processor-check.sh
#
# The Hugging Face login is the one part of the processor that no repo owns.
# Everything else here comes from a tag: the workspace, the venvs, the unit. The
# token is typed in by a person, lands in a directory the data-root layout calls
# an evictable cache, and expires on its own. Nothing announced its absence — a
# missing login reached the operator as an empty Datasets panel blaming the
# processor connection, days later.
#
# So this reports the chain the dataset viewer walks, and nothing else. It is
# read-only by contract: it never runs `hf` against a directory with no token,
# because `hf` would create that directory and make an unprovisioned host look
# provisioned on the next run.
set -uo pipefail

ROOT="${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FAIL=0
ok() { printf 'OK: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; FAIL=1; }

# The unit's EnvironmentFile, read the way archive-check.sh reads its own: by
# hand, because a person running this has none of systemd's environment.
read_env() {
  local file="$1" key="$2" line
  [ -r "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 0
  printf '%s\n' "${line#*=}"
}

ENVFILE="${FM_PROCESSOR_ENVFILE:-/etc/fm-processor.env}"

# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # fm_data_root

# Both resolutions mirror processor-boot.sh exactly. A check that computes a
# path its own way reports on a directory the service never opens.
DATA_ROOT="$(fm_data_root "$ROOT")"
HF_HOME="${FM_PROCESSOR_HUGGINGFACE_HOME:-$(read_env "$ENVFILE" FM_PROCESSOR_HUGGINGFACE_HOME)}"
HF_HOME="${HF_HOME:-$DATA_ROOT/hf}"

HF_CLI="${FM_PROCESSOR_RELEASE_HUGGINGFACE_CLI:-$(read_env "$ENVFILE" FM_PROCESSOR_RELEASE_HUGGINGFACE_CLI)}"
if [ -z "$HF_CLI" ] && [ -x "$ROOT/.release-venv/bin/hf" ]; then
  HF_CLI="$ROOT/.release-venv/bin/hf"
fi

if [ -n "$HF_CLI" ] && [ -x "$HF_CLI" ]; then
  ok "the dataset viewer has an hf CLI ($HF_CLI)"
else
  bad "no hf CLI; the viewer refuses every request as unconfigured — run scripts/install/setup-processor.sh"
fi

ok "the dataset viewer reads HF_HOME=$HF_HOME"

if [ -s "$HF_HOME/token" ]; then
  ok "a Hugging Face token is present"
  if [ -n "$HF_CLI" ] && [ -x "$HF_CLI" ]; then
    # A token file is not a login: an OAuth token expires where it lies, and
    # the file looks identical the day after it stops working.
    if HF_HOME="$HF_HOME" "$HF_CLI" auth whoami >/dev/null 2>&1; then
      ok "the Hugging Face token is valid"
    else
      bad "the Hugging Face token is present but rejected; re-run: sudo -u fm HF_HOME=$HF_HOME $HF_CLI auth login"
    fi
  fi
elif [ -n "$HF_CLI" ] && [ -x "$HF_CLI" ]; then
  bad "no Hugging Face login in $HF_HOME; private datasets stay empty in Desktop — run: sudo -u fm HF_HOME=$HF_HOME $HF_CLI auth login"
else
  bad "no Hugging Face login in $HF_HOME; private datasets stay empty in Desktop — install the release venv first, then log in"
fi


if command -v systemctl >/dev/null 2>&1; then
  if [ "$(systemctl is-active fm-processor.service 2>/dev/null)" = active ]; then
    ok "fm-processor.service is running"
  else
    bad "fm-processor.service is not active; check the journal"
  fi
else
  ok "service state deferred (systemd is unavailable)"
fi

exit "$FAIL"
