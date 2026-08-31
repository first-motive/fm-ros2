#!/usr/bin/env bash
# The archive appliance workflow: inspect, preflight, reconcile, or install the
# processor-owned read and upload services.
#
# This is intentionally a person-run front door. The uploader itself discovers
# committed recordings and reconciles its durable queue on startup; `reconcile`
# only restarts the two independent services so that recovery is explicit and
# repeatable. It never accepts a bucket, prefix, credential, or filesystem path
# from Desktop.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHIVE_UNIT="fm-archive.service"
UPLOADER_UNIT="fm-archive-uploader.service"
ARCHIVE_ENV="${FM_ARCHIVE_ENVFILE:-/etc/fm-archive.env}"
UPLOADER_ENV="${FM_ARCHIVE_UPLOADER_ENVFILE:-/etc/fm-archive-uploader.env}"

usage() {
  cat <<'EOF'
archive.sh — inspect and operate the processor archive services

Usage: ./scripts/run/archive.sh <status|preflight|reconcile|install> [options]

  status       report service and queue-facing state (read-only)
  preflight    check local service, env, policy, and package prerequisites
  reconcile    restart installed services so the uploader replays its queue
  install      install both default-off services (idempotent)

  --json       emit one machine-readable JSON object
  --dry-run    print changes for reconcile/install without applying them
  -h, --help   show this help

Provider Object Lock, retention, and storage-cap evidence is never inferred
from an env file. The uploader's provider preflight owns that live check; this
front door reports whether the local service is configured to perform it.
EOF
}

env_value() { # file key
  local file="$1" key="$2" line
  [ -r "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 0
  printf '%s\n' "${line#*=}"
}

service_state() { # unit active|enabled|loaded
  local unit="$1" query="$2"
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'unavailable\n'
    return 0
  fi
  systemctl "$query" "$unit" 2>/dev/null || printf 'unknown\n'
}

file_mode() { # path; prints a numeric mode or missing
  local path="$1" mode
  [ -e "$path" ] || { printf 'missing\n'; return 0; }
  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  [ -n "$mode" ] || mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
  printf '%s\n' "${mode:-unknown}"
}

json_bool() {
  case "$1" in
    true|1|yes) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

status_json() {
  local reader_enabled uploader_enabled reader_active uploader_active delete_enabled bandwidth
  local reader_enabled_state uploader_enabled_state
  reader_enabled="$(env_value "$ARCHIVE_ENV" FM_ARCHIVE_ENABLED)"
  uploader_enabled="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_ENABLED)"
  reader_active="$(service_state "$ARCHIVE_UNIT" is-active)"
  uploader_active="$(service_state "$UPLOADER_UNIT" is-active)"
  reader_enabled_state="$(service_state "$ARCHIVE_UNIT" is-enabled)"
  uploader_enabled_state="$(service_state "$UPLOADER_UNIT" is-enabled)"
  delete_enabled="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_DELETE_ENABLED)"
  bandwidth="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S)"
  if ! [[ "${bandwidth:-0}" =~ ^[0-9]+$ ]]; then
    printf '{"contract_version":1,"error_code":"invalid_policy","error":"upload bandwidth is not a non-negative integer"}\n'
    return 1
  fi
  printf '{"contract_version":1,"reader":{"enabled":%s,"active":"%s","unit_enabled":"%s","env_mode":"%s"},"uploader":{"enabled":%s,"active":"%s","unit_enabled":"%s","env_mode":"%s","delete_enabled":%s,"max_concurrent_uploads":1,"max_bandwidth_bytes_s":%s,"min_retention_days":30,"eligibility_window_minutes":15}}\n' \
    "$(json_bool "$reader_enabled")" "$reader_active" "$reader_enabled_state" "$(file_mode "$ARCHIVE_ENV")" \
    "$(json_bool "$uploader_enabled")" "$uploader_active" "$uploader_enabled_state" "$(file_mode "$UPLOADER_ENV")" \
    "$(json_bool "$delete_enabled")" "${bandwidth:-0}"
}

status_human() {
  local reader_enabled uploader_enabled
  reader_enabled="$(env_value "$ARCHIVE_ENV" FM_ARCHIVE_ENABLED)"
  uploader_enabled="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_ENABLED)"
  printf 'archive reader: enabled=%s active=%s unit=%s env_mode=%s\n' \
    "${reader_enabled:-false}" "$(service_state "$ARCHIVE_UNIT" is-active)" \
    "$(service_state "$ARCHIVE_UNIT" is-enabled)" "$(file_mode "$ARCHIVE_ENV")"
  printf 'archive uploader: enabled=%s active=%s unit=%s env_mode=%s\n' \
    "${uploader_enabled:-false}" "$(service_state "$UPLOADER_UNIT" is-active)" \
    "$(service_state "$UPLOADER_UNIT" is-enabled)" "$(file_mode "$UPLOADER_ENV")"
  printf 'policy: delete_enabled=%s min_retention_days=30 eligibility_window_minutes=15 max_concurrent_uploads=1 max_bandwidth_bytes_s=%s\n' \
    "$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_DELETE_ENABLED)" \
    "$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S)"
  printf 'topics: /archive/storage/index /archive/storage/status /archive/upload/retry /archive/retention/verify /archive/retention/delete\n'
}

preflight() {
  local json="$1" failures=0 warnings=0
  local reader_enabled uploader_enabled delete_enabled min_retention eligibility_window max_concurrent bandwidth
  local reader_key reader_secret uploader_key uploader_secret
  local checks=()
  reader_enabled="$(env_value "$ARCHIVE_ENV" FM_ARCHIVE_ENABLED)"
  uploader_enabled="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_ENABLED)"
  delete_enabled="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_DELETE_ENABLED)"
  min_retention="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS)"
  eligibility_window="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES)"
  max_concurrent="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS)"
  bandwidth="$(env_value "$UPLOADER_ENV" FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S)"
  reader_key="$(env_value "$ARCHIVE_ENV" BACKBLAZE_B2_PROCARCH_KEY_ID)"
  reader_secret="$(env_value "$ARCHIVE_ENV" BACKBLAZE_B2_PROCARCH_APPLICATION_KEY)"
  uploader_key="$(env_value "$UPLOADER_ENV" BACKBLAZE_B2_FMREC_KEY_ID)"
  uploader_secret="$(env_value "$UPLOADER_ENV" BACKBLAZE_B2_FMREC_APPLICATION_KEY)"

  check() { # label command...
    local label="$1"
    shift
    if "$@"; then
      checks+=("$label:pass")
    else
      checks+=("$label:fail")
      failures=$((failures + 1))
    fi
  }

  path_is_executable() { [ -x "$1" ]; }
  mode_is_private() { [ "$(file_mode "$1")" = 600 ]; }
  gate_is_valid() { [ "${1:-false}" = false ] || [ "${1:-false}" = true ]; }
  credential_is_ready() { [ -n "$1" ] || [ "${2:-false}" = false ]; }
  floor_is_valid() {
    [ -z "$1" ] || { [[ "$1" =~ ^[1-9][0-9]*$ ]] && [ "$1" -ge "$2" ]; }
  }
  concurrency_is_valid() {
    [ -z "$1" ] || [ "$1" = 1 ]
  }
  enabled_value_is_present() { [ "${2:-false}" = false ] || [ -n "$1" ]; }
  no_delete_api() {
    ! grep -R -E -q 'delete_object|delete_objects|DeleteObject|DeleteObjects' \
      "$ROOT/scripts/service" "$ROOT/scripts/install"
  }

  check archive_wrapper path_is_executable "$ROOT/scripts/service/archive-boot.sh"
  check uploader_wrapper path_is_executable "$ROOT/scripts/service/archive-uploader-boot.sh"
  check archive_installer path_is_executable "$ROOT/scripts/install/install-archive-service.sh"
  check uploader_installer path_is_executable "$ROOT/scripts/install/install-archive-uploader-service.sh"
  check reader_env_mode_private mode_is_private "$ARCHIVE_ENV"
  check uploader_env_mode_private mode_is_private "$UPLOADER_ENV"
  check reader_gate_valid gate_is_valid "${reader_enabled:-false}"
  check uploader_gate_valid gate_is_valid "${uploader_enabled:-false}"
  check reader_credential_name credential_is_ready "$reader_key" "${reader_enabled:-false}"
  check reader_application_key credential_is_ready "$reader_secret" "${reader_enabled:-false}"
  check uploader_credential_name credential_is_ready "$uploader_key" "${uploader_enabled:-false}"
  check uploader_application_key credential_is_ready "$uploader_secret" "${uploader_enabled:-false}"
  check delete_gate_valid gate_is_valid "${delete_enabled:-false}"
  check minimum_retention floor_is_valid "$min_retention" 30
  check eligibility_window floor_is_valid "$eligibility_window" 15
  check single_concurrent concurrency_is_valid "$max_concurrent"
  check bandwidth_ceiling floor_is_valid "$bandwidth" 1
  check storage_cap_evidence enabled_value_is_present \
    "$(env_value "$UPLOADER_ENV" FM_ARCHIVE_STORAGE_CAP_BYTES)" "${uploader_enabled:-false}"
  check required_storage_cap enabled_value_is_present \
    "$(env_value "$UPLOADER_ENV" FM_ARCHIVE_REQUIRED_STORAGE_CAP_BYTES)" "${uploader_enabled:-false}"
  check storage_cap_verified_at enabled_value_is_present \
    "$(env_value "$UPLOADER_ENV" FM_ARCHIVE_STORAGE_CAP_VERIFIED_AT)" "${uploader_enabled:-false}"
  check no_remote_delete_api no_delete_api

  if command -v ros2 >/dev/null 2>&1; then
    if ros2 pkg prefix fm_data_archive >/dev/null 2>&1; then
      checks+=("fm_data_archive built:pass")
    else
      checks+=("fm_data_archive built:fail")
      failures=$((failures + 1))
    fi
  else
    checks+=("fm_data_archive built:deferred")
    warnings=$((warnings + 1))
  fi

  if [ "$json" = true ]; then
    local first=true check_item label result
    printf '{"contract_version":1,"failures":%d,"warnings":%d,"checks":{' "$failures" "$warnings"
    for check_item in "${checks[@]}"; do
      label="${check_item%:*}"; result="${check_item##*:}"
      [ "$first" = true ] || printf ','
      first=false
      printf '"%s":"%s"' "$label" "$result"
    done
    printf '},"provider_preflight":"delegated_to_archive_uploader"}\n'
  else
    printf 'archive preflight (reader_env=%s uploader_env=%s)\n' "$ARCHIVE_ENV" "$UPLOADER_ENV"
    printf '  %s\n' "${checks[@]}"
    printf '  provider preflight: delegated to archive_uploader (Object Lock, retention, cap)\n'
  fi
  [ "$failures" -eq 0 ]
}

run_install() {
  local dry_run="$1" json="$2" rc=0 result
  run_installer() {
    # Keep --json stdout to one object. Installer diagnostics still reach stderr
    # so a failed transaction remains actionable without corrupting the output.
    if [ "$json" = true ]; then
      "$@" >/dev/null
    else
      "$@"
    fi
  }
  if [ "$dry_run" = true ]; then
    run_installer "$ROOT/scripts/install/install-archive-service.sh" --dry-run || rc=$?
    run_installer "$ROOT/scripts/install/install-archive-uploader-service.sh" --dry-run || rc=$?
  else
    run_installer "$ROOT/scripts/install/install-archive-service.sh" install || rc=$?
    run_installer "$ROOT/scripts/install/install-archive-uploader-service.sh" install || rc=$?
  fi
  if [ "$json" = true ]; then
    if [ "$rc" -ne 0 ]; then
      result=failed
    elif [ "$dry_run" = true ]; then
      result=planned
    else
      result=installed
    fi
    printf '{"contract_version":1,"action":"install","dry_run":%s,"result":"%s"}\n' \
      "$(json_bool "$dry_run")" "$result"
  fi
  return "$rc"
}

run_reconcile() {
  local dry_run="$1" json="$2" rc=0
  if [ "$dry_run" = true ]; then
    if [ "$json" = true ]; then
      printf '{"contract_version":1,"action":"reconcile","dry_run":true,"result":"planned","units":["%s","%s"]}\n' "$ARCHIVE_UNIT" "$UPLOADER_UNIT"
    else
      printf 'would restart %s and %s; the uploader will replay its durable queue\n' "$ARCHIVE_UNIT" "$UPLOADER_UNIT"
    fi
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "archive reconcile: systemctl is unavailable" >&2
    return 1
  fi
  sudo systemctl try-restart "$ARCHIVE_UNIT" || rc=$?
  sudo systemctl try-restart "$UPLOADER_UNIT" || rc=$?
  if [ "$json" = true ]; then
    printf '{"contract_version":1,"action":"reconcile","dry_run":false,"result":"%s"}\n' \
      "$([ "$rc" -eq 0 ] && printf restarted || printf failed)"
  fi
  return "$rc"
}

main() {
  local action="" json=false dry_run=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      status|preflight|reconcile|install) action="$1"; shift ;;
      --json) json=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "error: unknown argument '$1'" >&2; usage >&2; return 2 ;;
    esac
  done
  [ -n "$action" ] || { usage >&2; return 2; }

  if [ -n "${FM_SELFTEST:-}" ]; then
    printf 'selftest ok: archive %s resolved (json=%s dry_run=%s)\n' "$action" "$json" "$dry_run"
    return 0
  fi

  case "$action" in
    status)
      if [ "$json" = true ]; then status_json; else status_human; fi
      ;;
    preflight) preflight "$json" ;;
    install)
      if [ "$dry_run" = false ] && [ "$json" = false ]; then
        run_install false false
      else
        run_install "$dry_run" "$json"
      fi
      ;;
    reconcile)
      if [ "$dry_run" = false ] && [ "$json" = false ]; then
        run_reconcile false false
      else
        run_reconcile "$dry_run" "$json"
      fi
      ;;
  esac
}

main "$@"
