#!/usr/bin/env bash
# The processor verb: what the process supervisor is doing, what it has done to
# each recorded episode, and queue more work — from a shell, with no Desktop.
#
#   ./scripts/run/process.sh status                 # worker state, queue, last outcome
#   ./scripts/run/process.sh list                   # processed/annotated state per episode
#   ./scripts/run/process.sh show <episode>         # that episode's manifest
#   ./scripts/run/process.sh run <episode>... --emit
#   ./scripts/run/process.sh annotate <episode>...
#   ./scripts/run/process.sh real-annotate <episode>... --approved-by github:matthew ...
#   ./scripts/run/process.sh review --request review.json
#   ./scripts/run/process.sh wait <request-id>
#   ./scripts/run/process.sh cloud-start --lane qwen2.5 --profile-digest <sha256>
#   ./scripts/run/process.sh cloud-cancel --lane qwen2.5 --profile-digest <sha256> --request-id <uuid>
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
Usage: ./scripts/run/process.sh <status|list|show|inspect|run|annotate|real-annotate|retry|review|wait|cloud-start|cloud-cancel> [options]
  status                worker state, queue, current job, last outcome, refusals
  list                  processed/annotated state of every recorded episode
  show <episode>        the selected episode's full manifest and annotation detail
  inspect <episode>     alias for show
  run <episode>...      queue dataset processing for those episodes
  annotate <episode>... queue fake-adapter annotation for those episodes
  provision start --model MODEL  prepare pinned weights on the processor (returns accepted/running, not completion)
  provision status               inspect model preparation on the selected processor
  provision result --request-id ID  inspect the same request without resubmission
  real-annotate <episode>... queue an approved real-model attempt
  retry <episode>...    queue a real-model retry with a new request identity
  review                 submit one bundle-bound review JSON (from --request or stdin)
  wait <request-id>      observe one submitted request until terminal status
  cloud-start            request one scoped cloud lane start through S3 lifecycle
  cloud-cancel           request cancellation for one exact cloud lane request
  profiles ACTION        use this processor's task-profile authority (profiles --help)
  --emit                (run) emit clean RLDS as well as the manifest
  --reprocess           (run) re-run an episode whose manifest already exists
  --target T            (run) force one installed processing target
  --approved-by ID       (real-annotate/retry) accountable human approver
  --model MODEL         (real-annotate/retry) pinned model (default qwen2.5-vl-7b)
  --runtime RUNTIME      (real-annotate/retry) processor_gpu or aws_qwen_inference
  --approval-policy ID   (real-annotate/retry) approval policy identity
  --profile-id ID        (real-annotate/retry) approved task-profile identity
  --profile-version ID  (real-annotate/retry) approved task-profile version
  --profile-sha256 SHA   (real-annotate/retry) profile content digest
  --profile-approval-sha256 SHA (real-annotate/retry) approval digest
  --request-id ID        request identity; retry always mints a new one
  --request FILE         (review) read the complete request from FILE or stdin with -
  --host HOST            run the same command on an explicit processor SSH host
  --lane LANE            (cloud-start/cloud-cancel) qwen2.5 or qwen3.5
  --profile-digest SHA   (cloud-start/cloud-cancel) exact lane profile digest
  --run-minutes N        (cloud-start) bounded lease length
  --json                print the raw payload instead of a summary
  --timeout S           seconds to wait on the processor (default 20)
  -h, --help            show this help
USAGE
}

# Formatters run under the processor's own python (3.10 in the Humble image),
# so no quotes inside f-string expressions: %-formatting with plain names.
FMT_STATUS='
import json, sys
s = json.load(sys.stdin)
queue = s.get("queue") or []
print("state: %s  queued: %d" % (s.get("state"), len(queue)))
cur = s.get("current")
if cur:
    print("current: %s (%s)%s" % (cur.get("episode_id"), cur.get("kind", "process"), " request=%s" % cur.get("request_id") if cur.get("request_id") else ""))
last = s.get("last")
if last:
    ok = "ok" if last.get("ok") else "failed exit=%s" % last.get("exit_code")
    err = last.get("error")
    print("last: %s %s%s%s" % (last.get("episode_id"), ok, " request=%s" % last.get("request_id") if last.get("request_id") else "", " - %s" % err if err else ""))
for item in queue:
    print("queued: %s (%s)%s" % (item.get("episode_id"), item.get("kind", "process"), " request=%s" % item.get("request_id") if item.get("request_id") else ""))
for item in s.get("refused") or []:
    print("refused: %s - %s%s" % (item.get("episode_id"), item.get("reason"), " request=%s" % s.get("request_id") if s.get("request_id") else ""))
if s.get("request_error"):
    print("request_error: %s%s" % (s["request_error"], " request=%s" % s.get("request_id") if s.get("request_id") else ""))
for lane in s.get("cloud_lifecycle") or []:
    rid = lane.get("request_id")
    state = lane.get("state", lane.get("reason"))
    print("cloud %s: %s%s" % (lane.get("lane"), state, " request=%s" % rid if rid else ""))
'

FMT_LIST='
import json, sys
p = json.load(sys.stdin)
entries = p if isinstance(p, list) else (p.get("episodes") or p.get("entries") or [])
if not entries:
    print("no recorded episodes in the index")
for e in entries:
    flags = " ".join("%s=%s" % (k, v) for k, v in e.items()
                     if k != "episode_id" and isinstance(v, (bool, int, str)))
    print("%s  %s" % (e.get("episode_id"), flags))
'

FMT_RESULT='
import json, sys
p = json.load(sys.stdin)
print("request: %s  %s" % (p.get("request_id"), "ok" if p.get("ok") else "refused"))
if p.get("annotation_review_sha256"):
    print("review: %s" % p["annotation_review_sha256"])
if p.get("reason_code"):
    print("reason: %s - %s" % (p["reason_code"], p.get("message", "")))
if p.get("reused"):
    print("review: existing receipt reused")
'

# The detail topic is latched: it still carries the last episode somebody
# selected. Read until it names the one we asked for, or give up.
show_episode() {
  local episode="$1" json="$2" detail
  fm_supervisor_publish /process/select "$episode"
  local _
  for _ in 1 2 3 4 5; do
    detail=$(fm_supervisor_read /process/detail) || return 1
    if printf '%s\n' "$detail" | fm_supervisor_exec python3 -c \
      'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if value.get("episode_id") == sys.argv[1] else 1)' \
      "$episode" >/dev/null 2>&1; then
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

_safe_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

_safe_sha256() {
  [[ "$1" =~ ^[a-f0-9]{64}$ ]]
}

_safe_uuid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

_new_uuid() {
  local value
  value=$(uuidgen | tr '[:upper:]' '[:lower:]') || return 1
  _safe_uuid "$value" || return 1
  printf '%s\n' "$value"
}

_print_outcome() {
  local outcome="$1" json="$2"
  if [[ "$json" == true ]]; then
    printf '%s\n' "$outcome"
  else
    printf '%s\n' "$outcome" | fm_supervisor_format "$FMT_STATUS"
  fi
}

main() {
  if [[ "${1:-}" == provision ]]; then
    shift
    exec bash scripts/internal/catalogue.sh provision "$@"
  fi
  if [[ "${1:-}" == profiles ]]; then
    shift
    exec bash scripts/internal/catalogue.sh profile "$@"
  fi
  local host="" argument remote_command="exec fm process" quoted replacement="'\\''"
  local -a forwarded=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --host ]]; then
      if [[ $# -lt 2 || -n "$host" || ! "$2" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]]; then
        echo "error: --host needs one SSH host or alias" >&2
        return 2
      fi
      host="$2"
      shift 2
    else
      forwarded+=("$1")
      shift
    fi
  done
  set -- "${forwarded[@]}"
  if [[ -n "$host" ]]; then
    for argument in "$@"; do
      quoted="${argument//\'/$replacement}"
      remote_command+=" '$quoted'"
    done
    exec ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$host" "$remote_command"
  fi
  local action="" emit=false reprocess=false target="" json=false
  local approved_by="" model="qwen2.5-vl-7b" runtime="processor_gpu"
  local approval_policy="desktop-real-annotation-v1"
  local profile_id="" profile_version="" profile_sha256="" profile_approval_sha256=""
  local request_id="" request_id_explicit=false request_file="-"
  local lane="" profile_digest="" run_minutes=""
  local -a episodes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help) usage; return 0 ;;
      status | list | show | inspect | run | annotate | real-annotate | annotate-real | retry | review | wait | cloud-start | cloud-cancel | cancel)
        action="$1"; shift ;;
      --emit) emit=true; shift ;;
      --reprocess) reprocess=true; shift ;;
      --target) [[ $# -ge 2 ]] || { echo "error: --target needs a value" >&2; return 2; }; target="$2"; shift 2 ;;
      --target=*) target="${1#--target=}"; shift ;;
      --approved-by | --approver) [[ $# -ge 2 ]] || { echo "error: --approved-by needs a value" >&2; return 2; }; approved_by="$2"; shift 2 ;;
      --approved-by=* | --approver=*) approved_by="${1#*=}"; shift ;;
      --model) [[ $# -ge 2 ]] || { echo "error: --model needs a value" >&2; return 2; }; model="$2"; shift 2 ;;
      --model=*) model="${1#--model=}"; shift ;;
      --runtime) [[ $# -ge 2 ]] || { echo "error: --runtime needs a value" >&2; return 2; }; runtime="$2"; shift 2 ;;
      --runtime=*) runtime="${1#--runtime=}"; shift ;;
      --approval-policy) [[ $# -ge 2 ]] || { echo "error: --approval-policy needs a value" >&2; return 2; }; approval_policy="$2"; shift 2 ;;
      --approval-policy=*) approval_policy="${1#--approval-policy=}"; shift ;;
      --profile-id) [[ $# -ge 2 ]] || { echo "error: --profile-id needs a value" >&2; return 2; }; profile_id="$2"; shift 2 ;;
      --profile-id=*) profile_id="${1#--profile-id=}"; shift ;;
      --profile-version) [[ $# -ge 2 ]] || { echo "error: --profile-version needs a value" >&2; return 2; }; profile_version="$2"; shift 2 ;;
      --profile-version=*) profile_version="${1#--profile-version=}"; shift ;;
      --profile-sha256 | --profile-sha) [[ $# -ge 2 ]] || { echo "error: --profile-sha256 needs a value" >&2; return 2; }; profile_sha256="$2"; shift 2 ;;
      --profile-sha256=* | --profile-sha=*) profile_sha256="${1#*=}"; shift ;;
      --profile-approval-sha256 | --profile-approval-sha) [[ $# -ge 2 ]] || { echo "error: --profile-approval-sha256 needs a value" >&2; return 2; }; profile_approval_sha256="$2"; shift 2 ;;
      --profile-approval-sha256=* | --profile-approval-sha=*) profile_approval_sha256="${1#*=}"; shift ;;
      --request-id) [[ $# -ge 2 ]] || { echo "error: --request-id needs a value" >&2; return 2; }; request_id="$2"; request_id_explicit=true; shift 2 ;;
      --request-id=*) request_id="${1#--request-id=}"; request_id_explicit=true; shift ;;
      --request) [[ $# -ge 2 ]] || { echo "error: --request needs a file or -" >&2; return 2; }; request_file="$2"; shift 2 ;;
      --request=*) request_file="${1#--request=}"; shift ;;
      --lane) [[ $# -ge 2 ]] || { echo "error: --lane needs a value" >&2; return 2; }; lane="$2"; shift 2 ;;
      --lane=*) lane="${1#--lane=}"; shift ;;
      --profile-digest) [[ $# -ge 2 ]] || { echo "error: --profile-digest needs a value" >&2; return 2; }; profile_digest="$2"; shift 2 ;;
      --profile-digest=*) profile_digest="${1#--profile-digest=}"; shift ;;
      --run-minutes) [[ $# -ge 2 ]] || { echo "error: --run-minutes needs a value" >&2; return 2; }; run_minutes="$2"; shift 2 ;;
      --run-minutes=*) run_minutes="${1#--run-minutes=}"; shift ;;
      --new-attempt) shift ;;
      --json) json=true; shift ;;
      --timeout) [[ $# -ge 2 ]] || { echo "error: --timeout needs a value" >&2; return 2; }; FM_SUPERVISOR_TIMEOUT="$2"; shift 2 ;;
      --timeout=*) FM_SUPERVISOR_TIMEOUT="${1#--timeout=}"; shift ;;
      -*) echo "error: unknown argument '$1'" >&2; return 2 ;;
      *) episodes+=("$1"); shift ;;
    esac
  done
  if [[ -z "$action" ]]; then
    usage >&2
    echo "error: expected a process action" >&2
    return 2
  fi
  [[ "$action" == inspect ]] && action=show
  [[ "$action" == annotate-real ]] && action=real-annotate
  [[ "$action" == cancel ]] && action=cloud-cancel
  # bash 3.2 (macOS) trips `set -u` on an empty array's length; count it safely.
  local count="${episodes[*]+${#episodes[@]}}"
  count="${count:-0}"
  case "$action" in
    show) [[ "$count" -eq 1 ]] || { echo "error: show takes exactly one episode id" >&2; return 2; } ;;
    run | annotate | real-annotate | retry) [[ "$count" -ge 1 ]] || { echo "error: $action needs at least one episode id" >&2; return 2; } ;;
    wait)
      if [[ -z "$request_id" && "$count" -eq 1 ]]; then request_id="${episodes[0]}"; episodes=(); count=0; fi
      [[ "$count" -eq 0 ]] || { echo "error: wait takes one request id" >&2; return 2; }
      [[ -n "$request_id" ]] || { echo "error: wait needs a request id" >&2; return 2; } ;;
    review | status | list | cloud-start | cloud-cancel) [[ "$count" -eq 0 ]] || { echo "error: $action takes no episode ids" >&2; return 2; } ;;
  esac
  local e
  for e in ${episodes[@]+"${episodes[@]}"}; do
    _safe_id "$e" || { echo "error: '$e' is not an episode id" >&2; return 2; }
  done
  if [[ -n "$target" ]]; then
    _safe_id "$target" || { echo "error: '$target' is not a target id" >&2; return 2; }
  fi
  case "$action" in
    run | annotate)
      if [[ -n "$request_id" ]]; then
        _safe_id "$request_id" || { echo "error: --request-id is not contract-safe" >&2; return 2; }
      fi
      ;;
    real-annotate | retry)
      [[ -n "$approved_by" && "$approved_by" =~ ^[A-Za-z0-9][A-Za-z0-9:._@-]{0,127}$ ]] || { echo "error: real annotation needs a contract-safe --approved-by identity" >&2; return 2; }
      _safe_id "$approval_policy" || { echo "error: --approval-policy is not a contract-safe identifier" >&2; return 2; }
      [[ "$runtime" == processor_gpu || "$runtime" == aws_qwen_inference ]] || { echo "error: --runtime must be processor_gpu or aws_qwen_inference" >&2; return 2; }
      [[ "$model" == qwen2.5-vl-7b || "$model" == qwen3.5-9b ]] || { echo "error: unsupported --model '$model'" >&2; return 2; }
      _safe_id "$profile_id" || { echo "error: --profile-id is required and must be contract-safe" >&2; return 2; }
      _safe_id "$profile_version" || { echo "error: --profile-version is required and must be contract-safe" >&2; return 2; }
      _safe_sha256 "$profile_sha256" || { echo "error: --profile-sha256 is required and must be lowercase SHA-256" >&2; return 2; }
      _safe_sha256 "$profile_approval_sha256" || { echo "error: --profile-approval-sha256 is required and must be lowercase SHA-256" >&2; return 2; }
      if [[ -n "$request_id" ]]; then
        _safe_id "$request_id" || { echo "error: --request-id is not contract-safe" >&2; return 2; }
      fi
      if [[ "$action" == retry && "$request_id_explicit" == true ]]; then
        echo "error: retry always mints a new request id" >&2
        return 2
      fi
      ;;
    review)
      if [[ "$request_file" != - && ! -r "$request_file" ]]; then
        echo "error: review request is not readable: $request_file" >&2
        return 2
      fi
      ;;
    wait)
      _safe_id "$request_id" || { echo "error: request id is not contract-safe" >&2; return 2; }
      ;;
    cloud-start)
      [[ "$lane" == qwen2.5 || "$lane" == qwen3.5 ]] || { echo "error: cloud-start needs --lane qwen2.5 or qwen3.5" >&2; return 2; }
      _safe_sha256 "$profile_digest" || { echo "error: cloud-start needs a lowercase --profile-digest" >&2; return 2; }
      [[ -z "$request_id" ]] || { _safe_uuid "$request_id" || { echo "error: cloud-start --request-id must be a canonical UUID" >&2; return 2; }; }
      if [[ -n "$run_minutes" && ! "$run_minutes" =~ ^[1-9][0-9]{0,3}$ ]]; then
        echo "error: --run-minutes must be a positive whole number" >&2
        return 2
      fi
      ;;
    cloud-cancel)
      [[ "$lane" == qwen2.5 || "$lane" == qwen3.5 ]] || { echo "error: cloud-cancel needs --lane qwen2.5 or qwen3.5" >&2; return 2; }
      _safe_sha256 "$profile_digest" || { echo "error: cloud-cancel needs a lowercase --profile-digest" >&2; return 2; }
      _safe_uuid "$request_id" || { echo "error: cloud-cancel needs the exact active --request-id UUID" >&2; return 2; }
      ;;
  esac

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
    wait)
      local outcome rc=0
      outcome=$(fm_supervisor_wait_exact /process/status "$request_id") || rc=$?
      [[ -n "$outcome" ]] || return "$rc"
      _print_outcome "$outcome" "$json"
      return "$rc"
      ;;
    review)
      local outcome rc=0
      echo ">> requesting annotation review" >&2
      if [[ "$request_file" == - ]]; then
        outcome=$(fm_supervisor_request_stdin_exact /process/annotation_review /process/annotation_review_result) || rc=$?
      else
        outcome=$(fm_supervisor_request_stdin_exact /process/annotation_review /process/annotation_review_result < "$request_file") || rc=$?
      fi
      [[ -n "$outcome" ]] || return "$rc"
      if [[ "$json" == true ]]; then printf '%s\n' "$outcome"; else printf '%s\n' "$outcome" | fm_supervisor_format "$FMT_RESULT"; fi
      return "$rc"
      ;;
    run | annotate)
      local ids request request_id_outcome rc=0
      request_id="${request_id:-$(fm_supervisor_request_id)}"
      ids=$(printf '"%s",' "${episodes[@]}")
      request="{\"episodes\": [${ids%,}], \"request_id\": \"$request_id\""
      if [[ "$action" == run ]]; then
        request+=", \"emit\": $emit, \"reprocess\": $reprocess"
        [[ -n "$target" ]] && request+=", \"target\": \"$target\""
      fi
      request+="}"
      echo ">> requesting $action for $count episode(s) (request $request_id)" >&2
      request_id_outcome=$(fm_supervisor_request_exact "/process/$action" "$request" /process/status "$request_id") || rc=$?
      [[ -n "$request_id_outcome" ]] || return "$rc"
      _print_outcome "$request_id_outcome" "$json"
      return "$rc"
      ;;
    real-annotate | retry)
      local ids request outcome rc=0
      request_id="${request_id:-$(fm_supervisor_request_id)}"
      ids=$(printf '"%s",' "${episodes[@]}")
      request="{\"episodes\": [${ids%,}], \"approved_by\": \"$approved_by\", \"approval_policy\": \"$approval_policy\", \"mode\": \"new_attempt\", \"model\": \"$model\", \"runtime\": \"$runtime\", \"request_id\": \"$request_id\", \"task_profile\": {\"profile_id\": \"$profile_id\", \"profile_version\": \"$profile_version\", \"profile_sha256\": \"$profile_sha256\", \"approval_sha256\": \"$profile_approval_sha256\"}}"
      echo ">> requesting $action for $count episode(s) (request $request_id)" >&2
      outcome=$(fm_supervisor_request_exact /process/annotate_real "$request" /process/status "$request_id") || rc=$?
      [[ -n "$outcome" ]] || return "$rc"
      _print_outcome "$outcome" "$json"
      return "$rc"
      ;;
    cloud-start | cloud-cancel)
      local request outcome rc=0
      request_id="${request_id:-$(_new_uuid)}"
      request="{\"request_id\": \"$request_id\", \"lane\": \"$lane\", \"profile_digest\": \"$profile_digest\""
      [[ "$action" == cloud-start && -n "$run_minutes" ]] && request+=", \"run_minutes\": $run_minutes"
      request+="}"
      echo ">> requesting $action for lane $lane (request $request_id)" >&2
      outcome=$(fm_supervisor_request_exact "/process/${action//cloud-/cloud_}" "$request" /process/status "$request_id") || rc=$?
      [[ -n "$outcome" ]] || return "$rc"
      _print_outcome "$outcome" "$json"
      return "$rc"
      ;;
  esac
}

main "$@"
