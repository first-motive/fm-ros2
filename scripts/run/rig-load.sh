#!/usr/bin/env bash
# rig-load.sh — what is using the recorder rig's CPU right now, per ROS node.
#
# One read-only snapshot: total CPU, load average, the hottest SoC thermal zone,
# memory, and the busiest nodes with their CPU (percent of one core) and RSS. The
# numbers come from fm-data's hoststats.py — the same sampler that feeds the
# recorder status Desktop shows — so the CLI and the app agree.
#
#   scripts/run/rig-load.sh                    # on the rig
#   scripts/run/rig-load.sh --host fmrec       # from any machine, over ssh
#   scripts/run/rig-load.sh --host fmrec --json --seconds 5
#
# --host pipes this checkout's hoststats.py to the rig's python3 (stdlib only), so
# it works against a rig whose fm-data is older than the machine asking.
# Exit 0 with a snapshot, 2 usage, 3 when no snapshot could be taken.
set -uo pipefail

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

HOST="" JSON=false SECONDS_ARG=2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [[ "${2:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { echo "error: --host needs one SSH host or alias" >&2; exit 2; }
      HOST="$2"; shift 2 ;;
    --seconds)
      [[ "${2:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "error: --seconds needs a number" >&2; exit 2; }
      SECONDS_ARG="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAMPLER="$ROOT/src/fm_data/fm_data_record/fm_data_record/core/hoststats.py"
[ -f "$SAMPLER" ] || { echo "error: $SAMPLER is missing; import the fm-data source first" >&2; exit 3; }
grep -q "^def main" "$SAMPLER" || { echo "error: this fm-data predates the rig-load sampler; run fm update" >&2; exit 3; }

args=(--seconds "$SECONDS_ARG"); $JSON && args+=(--json)
if [ -n "$HOST" ]; then
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$HOST" python3 - "${args[@]}" < "$SAMPLER")"
else
  [ "$(uname -s)" = Linux ] || { echo "rig-load reads /proc on the rig — use --host <rig> from here" >&2; exit 2; }
  out="$(python3 "$SAMPLER" "${args[@]}")"
fi
[ -n "$out" ] || { echo "error: no snapshot from ${HOST:-this host}" >&2; exit 3; }

if $JSON; then
  printf '{"schema_version":1,"verb":"rig-load","ok":true,"data":%s}\n' "$out"
else
  printf '%s\n' "$out"
fi
