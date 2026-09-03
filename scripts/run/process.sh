#!/usr/bin/env bash
# The processor verb: what the process supervisor is doing, what it has done to
# each recorded episode, and queue more work — from a shell, with no Desktop.
#
#   ./scripts/run/process.sh status                 # worker state, queue, last outcome
#   ./scripts/run/process.sh list                   # processed/annotated state per episode
#   ./scripts/run/process.sh show <episode>         # that episode's manifest
#   ./scripts/run/process.sh run <episode>... --emit
#   ./scripts/run/process.sh annotate <episode>...
#
# Everything here is a request Desktop already sends, or a latched answer it
# already reads, on the /process/* topics fm_data's process_supervisor serves.
# `fm dataset process` drives the engine directly and bypasses that supervisor;
# this verb goes through it, so a run lands in the same job index, evidence,
# and processed-once guard the Desktop Process surface shows.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/internal/lib-supervisor.sh
source scripts/internal/lib-supervisor.sh

usage() {
  cat <<'USAGE'
process.sh — drive and inspect the processor's supervisor
Usage: ./scripts/run/process.sh <status|list|show|run|annotate> [options]
  status                worker state, queue, current job, last outcome, refusals
  list                  processed/annotated state of every recorded episode
  show <episode>        the selected episode's full manifest
  run <episode>...      queue dataset processing for those episodes
  annotate <episode>... queue fake-adapter annotation for those episodes
  --emit                (run) emit clean RLDS as well as the manifest
  --reprocess           (run) re-run an episode whose manifest already exists
  --target T            (run) force one installed processing target
  --json                print the raw payload instead of a summary
  --timeout S           seconds to wait on the processor (default 20)
  -h, --help            show this help
USAGE
}

FMT_STATUS='
import json, sys
s = json.load(sys.stdin)
print(f"state: {s.get(\"state\")}  queued: {len(s.get(\"queue\", []))}")
cur = s.get("current")
if cur:
    print(f"current: {cur.get(\"episode_id\")} ({cur.get(\"kind\", \"process\")})")
last = s.get("last")
if last:
    ok = "ok" if last.get("ok") else f"failed exit={last.get(\"exit_code\")}"
    print(f"last: {last.get(\"episode_id\")} {ok}" + (f" — {last[\"error\"]}" if last.get("error") else ""))
for item in s.get("queue", []):
    print(f"queued: {item.get(\"episode_id\")} ({item.get(\"kind\", \"process\")})")
for item in s.get("refused", []):
    print(f"refused: {item.get(\"episode_id\")} — {item.get(\"reason\")}")
if s.get("request_error"):
    print(f"request_error: {s[\"request_error\"]}")
for lane in s.get("cloud_lifecycle", []):
    print(f"cloud {lane.get(\"lane\")}: {lane.get(\"state\", lane.get(\"reason\"))}"
          + (f" request={lane[\"request_id\"]}" if lane.get("request_id") else ""))
'

FMT_LIST='
import json, sys
p = json.load(sys.stdin)
entries = p.get("episodes", p.get("entries", p if isinstance(p, list) else []))
if not entries:
    print("no recorded episodes in the index")
for e in entries:
    flags = " ".join(f"{k}={v}" for k, v in e.items()
                     if k != "episode_id" and isinstance(v, (bool, int, str)))
    print(f"{e.get(\"episode_id\")}  {flags}")
'

# The detail topic is latched: it still carries the last episode somebody
# selected. Read until it names the one we asked for, or give up.
show_episode() {
  local episode="$1" json="$2" detail
  fm_supervisor_publish /process/select "$episode"
  local _
  for _ in 1 2 3 4 5; do
    detail=$(fm_supervisor_read /process/detail) || return 1
    if [[ "$detail" == *"\"$episode\""* ]]; then
      if [[ "$json" == true ]]; then
        printf '%s\n' "$detail"
      else
        printf '%s\n' "$detail" | fm_supervisor_format 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2))'
      fi
      return 0
    fi
    sleep 1
  done
  echo "error: /process/detail never named $episode — is it in the index? (process list)" >&2
  return 1
}

print_status() {
  if [[ "$1" == true ]]; then
    fm_supervisor_read /process/status
  else
    fm_supervisor_read /process/status | fm_supervisor_format "$FMT_STATUS"
  fi
}

main() {
  local action="" emit=false reprocess=false target="" json=false
  local -a episodes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help) usage; return 0 ;;
      status | list | show | run | annotate) action="$1"; shift ;;
      --emit) emit=true; shift ;;
      --reprocess) reprocess=true; shift ;;
      --target) target="$2"; shift 2 ;;
      --target=*) target="${1#--target=}"; shift ;;
      --json) json=true; shift ;;
      --timeout) FM_SUPERVISOR_TIMEOUT="$2"; shift 2 ;;
      --timeout=*) FM_SUPERVISOR_TIMEOUT="${1#--timeout=}"; shift ;;
      -*) echo "error: unknown argument '$1'" >&2; return 2 ;;
      *) episodes+=("$1"); shift ;;
    esac
  done
  if [[ -z "$action" ]]; then
    usage >&2
    echo "error: expected one of status, list, show, run, annotate" >&2
    return 2
  fi
  # bash 3.2 (macOS) trips `set -u` on an empty array's length; count it safely.
  local count="${episodes[*]+${#episodes[@]}}"
  count="${count:-0}"
  case "$action" in
    show) [[ "$count" -eq 1 ]] || { echo "error: show takes exactly one episode id" >&2; return 2; } ;;
    run | annotate) [[ "$count" -ge 1 ]] || { echo "error: $action needs at least one episode id" >&2; return 2; } ;;
    *) [[ "$count" -eq 0 ]] || { echo "error: $action takes no episode ids" >&2; return 2; } ;;
  esac
  local e
  for e in ${episodes[@]+"${episodes[@]}"} ${target:+"$target"}; do
    # The supervisor refuses anything that is not one path component; refuse
    # earlier so the id never reaches a YAML literal.
    [[ "$e" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "error: '$e' is not an episode or target id" >&2; return 2; }
  done

  if [[ -n "${FM_SELFTEST:-}" ]]; then
    echo "selftest ok: process $action resolved (episodes=$count, emit=$emit, reprocess=$reprocess, json=$json)"
    return 0
  fi
  fm_supervisor_require

  case "$action" in
    status)
      print_status "$json"
      ;;
    list)
      if [[ "$json" == true ]]; then
        fm_supervisor_read /process/index
      else
        fm_supervisor_read /process/index | fm_supervisor_format "$FMT_LIST"
      fi
      ;;
    show)
      show_episode "${episodes[0]}" "$json"
      ;;
    run | annotate)
      local ids request
      ids=$(printf '"%s",' "${episodes[@]}")
      request="{\"episodes\": [${ids%,}]"
      if [[ "$action" == run ]]; then
        request+=", \"emit\": $emit, \"reprocess\": $reprocess"
        [[ -n "$target" ]] && request+=", \"target\": \"$target\""
      fi
      request+="}"
      echo ">> requesting $action for ${#episodes[@]} episode(s)"
      fm_supervisor_publish "/process/$action" "$request"
      # ponytail: the status republish after a request is not correlated to it;
      # one second is enough on the appliance, and the summary says what it saw.
      sleep 1
      print_status "$json"
      ;;
  esac
}

main "$@"
