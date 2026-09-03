#!/usr/bin/env bash
# The release verb: what the release supervisor holds — candidates, packs, the
# job queue — and a read-only verify of one pack, from a shell.
#
#   ./scripts/run/release.sh status              # queue, current, last outcome
#   ./scripts/run/release.sh list                # candidates and packs
#   ./scripts/run/release.sh show <id>           # one candidate's or pack's evidence
#   ./scripts/run/release.sh verify <pack> --strict
#
# Same /release/* topics Desktop's Release surface uses, served by fm_data's
# release_supervisor. Approve, publish, and deliver stay in Desktop: each needs
# an approval or confirmation identity a shell has no honest way to supply.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/internal/lib-supervisor.sh
source scripts/internal/lib-supervisor.sh

usage() {
  cat <<'USAGE'
release.sh — inspect the release supervisor and verify a pack
Usage: ./scripts/run/release.sh <status|list|show|verify> [options]
  status          queue, current job, last outcome, capabilities
  list            release candidates and built packs
  show <id>       bounded evidence for one candidate or pack
  verify <pack>   queue a read-only verification of that pack
  --strict        (verify) run every included format validator
  --json          print the raw payload instead of a summary
  --timeout S     seconds to wait on the processor (default 20)
  -h, --help      show this help
USAGE
}

# Formatters run under the processor's own python (3.10 in the Humble image),
# so no quotes inside f-string expressions: %-formatting with plain names.
FMT_STATUS='
import json, sys
s = json.load(sys.stdin)
print("state: %s  queued: %d" % (s.get("state"), len(s.get("queue") or [])))
for key in ("current", "last"):
    job = s.get(key)
    if job:
        print("%s: %s" % (key, " ".join("%s=%s" % (k, v) for k, v in job.items() if isinstance(v, (bool, int, str)))))
caps = s.get("capabilities") or {}
print("capabilities: " + ", ".join(k for k, v in sorted(caps.items()) if v))
if s.get("issue_code"):
    print("issue: %s - %s" % (s["issue_code"], s.get("message", "")))
'

FMT_LIST='
import json, sys
p = json.load(sys.stdin)
cands = p.get("candidates") or []
packs = p.get("packs") or []
for c in cands:
    print("candidate %s  %s %s %s" % (c.get("candidate_id"), c.get("mode", ""), c.get("inventory_state", ""), c.get("approval_state", "")))
for k in packs:
    flags = " ".join("%s=%s" % (a, b) for a, b in k.items() if a != "pack_id" and isinstance(b, (bool, int, str)))
    print("pack %s  %s" % (k.get("pack_id"), flags))
if not cands and not packs:
    print("no candidates or packs under the release root")
'

request() { # operation target_id options-json
  printf '{"contract_version": 1, "operation": "%s", "options": %s, "request_id": "%s", "target_id": "%s"}' \
    "$1" "$3" "$(fm_supervisor_request_id)" "$2"
}

# The detail topic is latched: it still carries the last target somebody
# selected. Read until it names the one we asked for, or give up.
show_target() {
  local target="$1" json="$2" detail
  fm_supervisor_publish /release/select "$(request select "$target" '{}')"
  local _
  for _ in 1 2 3 4 5; do
    detail=$(fm_supervisor_read /release/detail) || return 1
    if [[ "$detail" == *"\"$target\""* ]]; then
      if [[ "$json" == true ]]; then
        printf '%s\n' "$detail"
      else
        printf '%s\n' "$detail" | fm_supervisor_format 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2))'
      fi
      return 0
    fi
    sleep 1
  done
  echo "error: /release/detail never named $target — is it a candidate or pack? (release list)" >&2
  return 1
}

print_status() {
  if [[ "$1" == true ]]; then
    fm_supervisor_read /release/status
  else
    fm_supervisor_read /release/status | fm_supervisor_format "$FMT_STATUS"
  fi
}

main() {
  local action="" strict=false json=false target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help) usage; return 0 ;;
      status | list | show | verify) action="$1"; shift ;;
      --strict) strict=true; shift ;;
      --json) json=true; shift ;;
      --timeout) FM_SUPERVISOR_TIMEOUT="$2"; shift 2 ;;
      --timeout=*) FM_SUPERVISOR_TIMEOUT="${1#--timeout=}"; shift ;;
      -*) echo "error: unknown argument '$1'" >&2; return 2 ;;
      *)
        [[ -z "$target" ]] || { echo "error: only one id is accepted" >&2; return 2; }
        target="$1"
        shift
        ;;
    esac
  done
  if [[ -z "$action" ]]; then
    usage >&2
    echo "error: expected one of status, list, show, verify" >&2
    return 2
  fi
  case "$action" in
    show | verify) [[ -n "$target" ]] || { echo "error: $action needs a candidate or pack id" >&2; return 2; } ;;
    *) [[ -z "$target" ]] || { echo "error: $action takes no id" >&2; return 2; } ;;
  esac
  # Same rule the supervisor applies to target_id, applied before the id can
  # reach a JSON or YAML literal.
  if [[ -n "$target" && ! "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "error: '$target' is not a contract-safe identifier" >&2
    return 2
  fi

  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: release $action resolved (target=${target:-none}, strict=$strict, json=$json)"
    return 0
  fi
  fm_supervisor_require

  case "$action" in
    status)
      print_status "$json"
      ;;
    list)
      if [[ "$json" == true ]]; then
        fm_supervisor_read /release/index
      else
        fm_supervisor_read /release/index | fm_supervisor_format "$FMT_LIST"
      fi
      ;;
    show)
      show_target "$target" "$json"
      ;;
    verify)
      echo ">> requesting verify of pack $target (strict=$strict)"
      fm_supervisor_publish /release/verify "$(request verify "$target" "{\"strict\": $strict}")"
      # ponytail: same uncorrelated status read as process.sh; the request id
      # is in the payload so `release status --json` can be matched by hand.
      sleep 1
      print_status "$json"
      ;;
  esac
}

main "$@"
