#!/usr/bin/env bash
# install-processor-service.sh — install (or remove) the systemd unit that auto-starts
# the dataset-processing supervisor on boot, turning the Linux processing host into a
# headless appliance: boot -> process_supervisor up on the capture session's ROS graph,
# and an operator kicks off runs from the desktop app's Process surface (/process/run).
#
# The processing sibling of install-recorder-service.sh: the recorder checkout moves to
# a Jetson later while this role stays on the strong Linux host, each in its own
# workspace. The unit runs scripts/service/processor-boot.sh (the boot-time source chain +
# launch) as the installing user, so output lands in that user's ~/processed.
#
# Linux + systemd only, best-effort (warns + returns 0 elsewhere), idempotent. Invoked
# by setup-processor.sh when install.sh got --service; runnable standalone.
#
# Usage:
#   ./scripts/install/install-processor-service.sh            # install + enable + start
#   ./scripts/install/install-processor-service.sh uninstall  # stop + disable + remove
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # item()
# shellcheck disable=SC1091
. "$ROOT/scripts/env/bridge.sh"
# shellcheck disable=SC1091
. "$ROOT/scripts/internal/lib-processor.sh"
cd "$ROOT"

UNIT=/etc/systemd/system/fm-processor.service
ENVFILE=/etc/fm-processor.env
AWS_ENVFILE=/etc/fm-processor-aws.env
BRIDGE_ENV="${FM_BRIDGE_ENV_FILE:-/etc/fm-bridge.env}"
WRAPPER="$ROOT/scripts/service/processor-boot.sh"
IDENTITY_INSTALLER="$ROOT/scripts/install/install-processor-identity.sh"
IDENTITY_PROFILE="${FM_AWS_IDENTITY_ETC_DIR:-/etc/fm-aws-identity}/aws-config"
IDENTITY_ENV="${FM_AWS_IDENTITY_CONFIG_FILE:-${FM_AWS_IDENTITY_ETC_DIR:-/etc/fm-aws-identity}/identity.env}"

# Offline CI can exercise the complete install transaction without writing /etc
# or invoking a real systemd host.  This seam is intentionally opt-in and
# requires an explicit temporary root; normal installs always use the paths
# above.  The test still runs the real installer and only stubs sudo/systemctl.
if [ "${FM_PROCESSOR_SERVICE_TEST_MODE:-0}" = 1 ]; then
  : "${FM_PROCESSOR_SERVICE_TEST_ROOT:?FM_PROCESSOR_SERVICE_TEST_ROOT is required in test mode}"
  UNIT="$FM_PROCESSOR_SERVICE_TEST_ROOT/systemd/fm-processor.service"
  ENVFILE="$FM_PROCESSOR_SERVICE_TEST_ROOT/etc/fm-processor.env"
  AWS_ENVFILE="$FM_PROCESSOR_SERVICE_TEST_ROOT/etc/fm-processor-aws.env"
  BRIDGE_ENV="$FM_PROCESSOR_SERVICE_TEST_ROOT/etc/fm-bridge.env"
  IDENTITY_PROFILE="$FM_PROCESSOR_SERVICE_TEST_ROOT/identity/aws-config"
  IDENTITY_ENV="$FM_PROCESSOR_SERVICE_TEST_ROOT/identity/identity.env"
  IDENTITY_INSTALLER="$FM_PROCESSOR_SERVICE_TEST_ROOT/identity/install-identity.sh"
fi

# The identity installer writes this public selector file (never private key
# material). Read only the three values needed by the optional inference route;
# do not source an /etc file during installation.
_identity_config_value() {
  local name="$1"
  [ -r "$IDENTITY_ENV" ] || return 0
  sed -n "s/^${name}=//p" "$IDENTITY_ENV" | head -1
}
IDENTITY_REGION_CONFIG="$(_identity_config_value FM_AWS_IDENTITY_REGION)"
IDENTITY_PROFILE_CONFIG="$(_identity_config_value FM_AWS_IDENTITY_PROFILE)"
IDENTITY_BUCKET_CONFIG="$(_identity_config_value FM_AWS_IDENTITY_BUCKET)"

# Run the service as the human who installed it, not root — so ~/recordings and
# ~/processed resolve to their account. SUDO_USER covers a `sudo ./install.sh`.
SERVICE_USER="${SUDO_USER:-$USER}"
# `getent` is Linux-only; keep --help and the platform guard usable on macOS.
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"

usage() {
  cat <<'EOF'
install-processor-service.sh — install/remove the fm-processor boot service (Linux)

  (no args)    write the unit, enable it for boot, start it now
  uninstall    stop + disable + remove the unit and its managed env files
  -h, --help   show this help

The service runs scripts/service/processor-boot.sh as the installing user: it sources
ROS + the workspace overlay + comms.sh, then launches process_session.launch.py
(the process_supervisor node). Manifests land in ~/processed. Tune it via
/etc/fm-processor.env (FM_PROCESSOR_RECORDINGS_DIR, FM_PROCESSOR_OUTPUT_DIR,
FM_PROCESSOR_LEROBOT_IMPORTS_DIR, ...). The LeRobot imports root must match the
archive service's FM_ARCHIVE_LEROBOT_STAGE_DIR when either is customized.
The shared Foxglove/Avahi endpoint is persisted separately in /etc/fm-bridge.env.

When the processor identity has been installed, its systemd drop-in supplies the
Ohio-only Roles Anywhere profile and runs the certificate monitor before launch.
The standalone installer refuses to restart a processor whose identity profile
exists but does not pass the read-only identity check.

Set FM_AWS_INFERENCE_SERVICE_MODE=1 with the reviewed identity bucket before
installing to persist the Ohio service selectors in /etc/fm-processor-aws.env.
The installed, readable identity profile must pass its read-only check first.
The file is managed atomically and conflicts are refused; worker readiness still
comes only from the profile-bound receipts in FM_AWS_INFERENCE_READINESS_DIR.
EOF
}

AWS_INFERENCE_SCRIPT_DEFAULT="src/fm_data/fm_data_annotate/scripts/run_qwen_aws_service.sh"
AWS_INFERENCE_REGION_EFFECTIVE=""
AWS_INFERENCE_PROFILE_EFFECTIVE=""
AWS_INFERENCE_BUCKET_EFFECTIVE=""
AWS_INFERENCE_READINESS_EFFECTIVE=""
AWS_INFERENCE_SCRIPT_EFFECTIVE=""
AWS_INFERENCE_TIMEOUT_EFFECTIVE=""

_safe_env_value() { # name value
  local name="$1" value="$2"
  [[ "$value" =~ ^[A-Za-z0-9._/~:+,@%-]+$ ]] || {
    echo "ERROR: $name contains characters that are unsafe in an EnvironmentFile" >&2
    return 1
  }
}

_validate_aws_inference_config() {
  local mode="${FM_AWS_INFERENCE_SERVICE_MODE:-0}"
  local region profile bucket readiness script timeout
  case "$mode" in
    ""|0) return 0 ;;
    1) ;;
    *) echo "ERROR: FM_AWS_INFERENCE_SERVICE_MODE must be 1 when enabled" >&2; return 1 ;;
  esac

  region="${FM_AWS_INFERENCE_REGION:-${FM_AWS_IDENTITY_REGION:-${IDENTITY_REGION_CONFIG:-us-east-2}}}"
  profile="${FM_AWS_PROFILE:-${FM_AWS_IDENTITY_PROFILE:-$IDENTITY_PROFILE_CONFIG}}"
  bucket="${FM_AWS_INFERENCE_BUCKET:-${FM_AWS_IDENTITY_BUCKET:-$IDENTITY_BUCKET_CONFIG}}"
  readiness="${FM_AWS_INFERENCE_READINESS_DIR:-$(fm_data_root "$ROOT" "$SERVICE_HOME")/annotations/runs/aws-readiness}"
  script="${FM_PROCESSOR_AWS_INFERENCE_SCRIPT:-$AWS_INFERENCE_SCRIPT_DEFAULT}"
  timeout="${FM_AWS_SERVICE_TIMEOUT_SECONDS:-7200}"

  [ -n "$IDENTITY_REGION_CONFIG" ] && [ -n "$IDENTITY_PROFILE_CONFIG" ] &&
    [ -n "$IDENTITY_BUCKET_CONFIG" ] || {
    echo "ERROR: installed processor identity selectors are incomplete" >&2
    return 1
  }
  if [ "$region" != "$IDENTITY_REGION_CONFIG" ] ||
     [ "$profile" != "$IDENTITY_PROFILE_CONFIG" ] ||
     [ "$bucket" != "$IDENTITY_BUCKET_CONFIG" ]; then
    echo "ERROR: Ohio service selectors must match the installed processor identity" >&2
    return 1
  fi

  AWS_INFERENCE_REGION_EFFECTIVE="$region"
  AWS_INFERENCE_PROFILE_EFFECTIVE="$profile"
  AWS_INFERENCE_BUCKET_EFFECTIVE="$bucket"
  AWS_INFERENCE_READINESS_EFFECTIVE="$readiness"
  AWS_INFERENCE_SCRIPT_EFFECTIVE="$script"
  AWS_INFERENCE_TIMEOUT_EFFECTIVE="$timeout"

  [ "$region" = us-east-2 ] || {
    echo "ERROR: FM_AWS_INFERENCE_REGION must be us-east-2 (Ohio)" >&2
    return 1
  }
  [ -n "$bucket" ] || {
    echo "ERROR: FM_AWS_INFERENCE_BUCKET is required when the Ohio service is enabled" >&2
    echo "       Supply the reviewed bucket; the installer never guesses one." >&2
    return 1
  }
  [ -n "$profile" ] || {
    echo "ERROR: FM_AWS_PROFILE is required when the Ohio service is enabled" >&2
    echo "       Use the profile from the installed processor identity." >&2
    return 1
  }
  [[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "ERROR: FM_AWS_PROFILE contains unsafe characters" >&2
    return 1
  }
  [[ "$bucket" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
    echo "ERROR: FM_AWS_INFERENCE_BUCKET must be a plain bucket name" >&2
    return 1
  }
  # Keep the value canonical and bounded before using a numeric comparison:
  # leading zeroes are rejected, and the length check prevents an oversized
  # value from reaching shell arithmetic.
  if ! [[ "$timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: FM_AWS_SERVICE_TIMEOUT_SECONDS must be an integer from 1 through 7200" >&2
    return 1
  fi
  if [ "${#timeout}" -gt 4 ] || [ "$timeout" -gt 7200 ]; then
    echo "ERROR: FM_AWS_SERVICE_TIMEOUT_SECONDS must be an integer from 1 through 7200" >&2
    return 1
  fi
  _safe_env_value FM_AWS_INFERENCE_READINESS_DIR "$readiness" || return 1
  _safe_env_value FM_PROCESSOR_AWS_INFERENCE_SCRIPT "$script" || return 1
}

_envfile_value() { # file name
  local file="$1" name="$2"
  [ -f "$file" ] || return 0
  sudo awk -F= -v name="$name" '$1 == name { value=substr($0, index($0, "=") + 1) } END { if (value != "") print value }' "$file"
}

_check_aws_env_conflicts() {
  local name expected existing
  for name in \
    FM_AWS_INFERENCE_SERVICE_MODE FM_AWS_INFERENCE_REGION FM_AWS_PROFILE \
    FM_AWS_INFERENCE_BUCKET FM_AWS_INFERENCE_READINESS_DIR \
    FM_AWS_SERVICE_TIMEOUT_SECONDS FM_PROCESSOR_AWS_INFERENCE_SCRIPT; do
    case "$name" in
      FM_AWS_INFERENCE_SERVICE_MODE) expected=1 ;;
      FM_AWS_INFERENCE_REGION) expected="$AWS_INFERENCE_REGION_EFFECTIVE" ;;
      FM_AWS_PROFILE) expected="$AWS_INFERENCE_PROFILE_EFFECTIVE" ;;
      FM_AWS_INFERENCE_BUCKET) expected="$AWS_INFERENCE_BUCKET_EFFECTIVE" ;;
      FM_AWS_INFERENCE_READINESS_DIR) expected="$AWS_INFERENCE_READINESS_EFFECTIVE" ;;
      FM_AWS_SERVICE_TIMEOUT_SECONDS) expected="$AWS_INFERENCE_TIMEOUT_EFFECTIVE" ;;
      FM_PROCESSOR_AWS_INFERENCE_SCRIPT) expected="$AWS_INFERENCE_SCRIPT_EFFECTIVE" ;;
    esac
    existing="$(_envfile_value "$ENVFILE" "$name")"
    if [ -n "$existing" ] && [ "$existing" != "$expected" ]; then
      echo "ERROR: $ENVFILE already sets $name=$existing; refusing conflicting Ohio service config" >&2
      echo "       Remove or update that setting before enabling the managed route." >&2
      return 1
    fi
  done
}

_render_aws_service_env() {
  cat <<EOF
# Managed by install-processor-service.sh; Ohio inference selectors only.
# Readiness receipts are supplied by the read-only AWS preflight; configuration alone is not Ready.
FM_AWS_INFERENCE_SERVICE_MODE=1
FM_AWS_INFERENCE_REGION=$AWS_INFERENCE_REGION_EFFECTIVE
FM_AWS_PROFILE=$AWS_INFERENCE_PROFILE_EFFECTIVE
FM_AWS_INFERENCE_BUCKET=$AWS_INFERENCE_BUCKET_EFFECTIVE
FM_AWS_INFERENCE_READINESS_DIR=$AWS_INFERENCE_READINESS_EFFECTIVE
FM_AWS_SERVICE_TIMEOUT_SECONDS=$AWS_INFERENCE_TIMEOUT_EFFECTIVE
FM_PROCESSOR_AWS_INFERENCE_SCRIPT=$AWS_INFERENCE_SCRIPT_EFFECTIVE
EOF
}

_check_managed_aws_env() {
  [ "${FM_AWS_INFERENCE_SERVICE_MODE:-0}" = 1 ] || return 0
  local expected existing
  expected="$(_render_aws_service_env)"
  if [ -f "$AWS_ENVFILE" ]; then
    existing="$(sudo cat "$AWS_ENVFILE")"
    [ "$existing" = "$expected" ] || {
      echo "ERROR: managed Ohio service config already exists at $AWS_ENVFILE with different values" >&2
      echo "       Refusing to overwrite it; review or remove that file explicitly." >&2
      return 1
    }
  fi
  return 0
}

_preflight_aws_service_env() {
  [ "${FM_AWS_INFERENCE_SERVICE_MODE:-0}" = 1 ] || return 0
  _check_aws_env_conflicts || return 1
  _check_managed_aws_env || return 1
}

_write_aws_service_env() {
  [ "${FM_AWS_INFERENCE_SERVICE_MODE:-0}" = 1 ] || return 0
  _preflight_aws_service_env || return 1

  local expected staging
  expected="$(_render_aws_service_env)"
  [ -f "$AWS_ENVFILE" ] && return 0
  staging="$(mktemp "${TMPDIR:-/tmp}/fm-processor-aws.XXXXXX")"
  printf '%s\n' "$expected" > "$staging"
  sudo install -d -m 0755 "$(dirname "$AWS_ENVFILE")"
  sudo install -m 0644 -o root -g root "$staging" "${AWS_ENVFILE}.staging.$$"
  sudo mv -f "${AWS_ENVFILE}.staging.$$" "$AWS_ENVFILE"
  rm -f "$staging"
}

# Guard: the boot service needs Linux + systemd. Off that, warn and let the caller
# carry on (a plain processor build still works; only the appliance step is skipped).
_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: the processor boot service is Linux-only — skipping." >&2
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: systemctl not found (no systemd) — skipping the boot service." >&2
    return 1
  fi
  return 0
}

# The directory names that moved when the data root landed, old suffix first.
# Matched as suffixes so one table converges a container-side value (/data/…) and
# a native one (/opt/fm/…) alike, without this script needing to know which shape
# a given host wrote.
FM_PROCESSOR_ENV_MOVES=(
  "/fm-data-runs/annotation-attempts=/annotations/runs/attempts"
  "/fm-data-runs/annotation-reviews=/annotations/runs/reviews"
  "/fm-data-runs/annotation-corrections=/annotations/runs/corrections"
  "/fm-data-runs/annotation-learning-snapshots=/annotations/runs/learning-snapshots"
  "/fm-data-runs/annotation-learning=/annotations/runs/learning"
  "/fm-data-runs/annotation-adjudications=/annotations/runs/adjudications"
  "/fm-data-runs/annotation-revocations=/annotations/runs/revocations"
  "/fm-data-runs/annotation-improvement-runs=/annotations/runs/improvement-runs"
  "/fm-data-runs/archive-cache=/staged/episodes"
  "/fm-data-runs/huggingface=/hf"
  "/lerobot-staged=/staged/lerobot"
  "/dataset-releases=/releases"
)

# Move an existing env file's directory knobs onto the current tree.
#
# Idempotent: the new names contain none of the old ones, so a second run finds
# nothing to rewrite. Reports what it changed, because a path moving under a
# running service is exactly the kind of silent edit an operator should see in
# the install log.
_migrate_processor_env() {
  [ -f "$ENVFILE" ] || return 0
  local move old new changed=0
  for move in "${FM_PROCESSOR_ENV_MOVES[@]}"; do
    old="${move%%=*}"
    new="${move#*=}"
    # Anchored to a value, so a comment mentioning the old tree is left as prose.
    if sudo grep -q "=[^=]*${old}" "$ENVFILE" 2>/dev/null; then
      sudo sed -i.bak "s#\(=[^=]*\)${old}#\1${new}#g" "$ENVFILE" || return 1
      sudo rm -f "${ENVFILE}.bak"
      item "moved ${old} -> ${new} in $ENVFILE"
      changed=1
    fi
  done
  [ "$changed" -eq 1 ] && item "restart the service to apply the moved paths"
  return 0
}

# Copy immutable attempt receipts from the retired tree into the configured
# root. The old copy stays in place as recovery evidence. A different receipt
# at the same episode/attempt identity stops the install instead of choosing
# one history silently.
_migrate_processor_attempt_evidence() {
  [ -f "$ENVFILE" ] || return 0
  local new_root old_root source relative episode attempt destination copied=0
  new_root="$(_envfile_value "$ENVFILE" FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR)"
  case "$new_root" in
    */annotations/runs/attempts) ;;
    *) return 0 ;;
  esac
  old_root="${new_root%/annotations/runs/attempts}/fm-data-runs/annotation-attempts"
  [ -d "$old_root" ] || return 0

  while IFS= read -r -d '' source; do
    relative="${source#"$old_root"/}"
    case "$relative" in
      */*/ATTEMPT.json) ;;
      *) echo "ERROR: unexpected legacy attempt path: $source" >&2; return 1 ;;
    esac
    episode="${relative%%/*}"
    attempt="${relative#*/}"
    attempt="${attempt%%/*}"
    destination="$new_root/$episode/$attempt/ATTEMPT.json"

    if [ -e "$destination" ]; then
      if ! sudo cmp -s "$source" "$destination"; then
        echo "ERROR: legacy attempt conflicts with $destination" >&2
        return 1
      fi
      continue
    fi

    sudo mkdir -p "$new_root/$episode"
    sudo cp -a "${source%/ATTEMPT.json}" "$new_root/$episode/"
    sudo cmp -s "$source" "$destination" || {
      echo "ERROR: copied attempt did not verify: $destination" >&2
      return 1
    }
    copied=$((copied + 1))
  done < <(sudo find "$old_root" -mindepth 3 -maxdepth 3 -type f -name ATTEMPT.json -print0)

  [ "$copied" -gt 0 ] && item "copied and verified $copied legacy annotation attempt receipt(s)"
  return 0
}

do_install() {
  _require_linux_systemd || return 0
  if [ ! -f "$WRAPPER" ]; then
    echo "ERROR: $WRAPPER missing — cannot install the service." >&2
    return 1
  fi
  _validate_aws_inference_config || return 1

  # setup-processor.sh installs the identity before this service.  If a durable
  # profile is already present, verify it before writing/restarting the unit; a
  # partially copied certificate must never result in a service that appears
  # healthy while its credential_process is unusable.
  if [ "${FM_AWS_INFERENCE_SERVICE_MODE:-0}" = 1 ]; then
    [ -f "$IDENTITY_PROFILE" ] && [ -r "$IDENTITY_PROFILE" ] || {
      echo "ERROR: Ohio inference service requires an installed processor identity profile: $IDENTITY_PROFILE" >&2
      echo "       Complete scripts/install/install-processor-identity.sh before enabling service mode." >&2
      return 1
    }
  fi
  if [ -f "$IDENTITY_PROFILE" ]; then
    [ -f "$IDENTITY_INSTALLER" ] || { echo "ERROR: processor identity installer is missing." >&2; return 1; }
    bash "$IDENTITY_INSTALLER" check || {
      echo "ERROR: processor identity check failed; service was not restarted." >&2
      return 1
    }
  fi
  _preflight_aws_service_env || return 1

  # Resolve the runtime and validate every read-only identity mount before the
  # bridge, unit, or env files are touched. A container service with a missing
  # AWS CLI tree must fail as an install, not restart into a broken route.
  local runtime exec_start exec_stop="" requires=""
  runtime="$(fm_processor_runtime)" || return 1
  if [ "$runtime" = container ] && [ -f "$IDENTITY_PROFILE" ]; then
    fm_processor_prepare_identity_mounts || return 1
  fi

  # Processor discovery adverts use the same durable endpoint file as the
  # recorder and standalone bridge. Preserve an existing tower override.
  FM_BRIDGE_ENV_FILE="$BRIDGE_ENV" ./scripts/install/install-bridge-config.sh
  # shellcheck disable=SC1091
  . "$ROOT/scripts/env/bridge.sh"

  # In the container runtime the unit execs the same wrapper through compose;
  # the image, not the host, holds ROS (#127). See scripts/service/container-exec.sh.
  if [ "$runtime" = container ]; then
    exec_start="/bin/bash $ROOT/scripts/service/container-exec.sh scripts/service/processor-boot.sh"
    # Stop the WRAPPER, not the launch. `docker compose exec` does not forward
    # SIGTERM, so a stop has to reach in by name; signalling the launch directly
    # left the wrapper watching a launch that exits 0 on SIGTERM, which is the
    # very thing it now reports as a failure — a deliberate stop ended in
    # `failed (exit-code)`. The wrapper's own trap forwards the signal and exits
    # clean. No backslash in either pattern: systemd parses the Exec lines itself
    # and warned "Ignoring unknown escape sequences" on an escaped dot (#134).
    exec_stop="ExecStop=/bin/bash $ROOT/scripts/service/container-exec.sh stop 'processor-boot.sh'
ExecStop=/bin/bash $ROOT/scripts/service/container-exec.sh stop 'process_session.launch'"
    requires="Requires=docker.service"
  else
    exec_start="/bin/bash $WRAPPER"
  fi

  item "writing $UNIT (User=$SERVICE_USER, HOME=$SERVICE_HOME, workspace=$ROOT, runtime=$runtime) ..."
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive dataset processor (process_supervisor for the app's Process surface)
After=network-online.target docker.service
Wants=network-online.target
$requires
# Never permanently give up: an appliance that boots before the network (or the
# recorder session) is up should keep retrying rather than land in a failed state.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
EnvironmentFile=-$ENVFILE
EnvironmentFile=-$AWS_ENVFILE
EnvironmentFile=-$BRIDGE_ENV
WorkingDirectory=$ROOT
ExecStart=$exec_start
$exec_stop
# A deliberate stop first ends the wrapper inside the container, then systemd
# sends SIGTERM to this unit's compose exec, which exits 143. Without this the
# journal records every clean stop as a failure, so a real one stops standing out.
SuccessExitStatus=143
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # A host provisioned before the data root moved keeps its own env file, and the
  # template below is written only when one is absent — so without this its knobs
  # would still name the retired fm-data-runs tree, which nothing mounts any
  # more. Only the exact old shapes are rewritten, by suffix rather than by whole
  # path, so a native root and a container root both converge and a directory an
  # operator chose is left alone.
  _migrate_processor_env

  # Config knobs — write a template only when absent, so a re-install never clobbers a
  # host's tuned values (custom dirs, a pinned LAN IP, ...).
  if [ ! -f "$ENVFILE" ]; then
    # The template below is written with the container's view of the data root.
    # A host whose root sits elsewhere has every value retargeted after the write.
    local processor_data_root
    processor_data_root="$(fm_data_root "$ROOT" "$SERVICE_HOME")"
    item "writing $ENVFILE (config knobs — edit, then restart the service to apply) ..."
    sudo tee "$ENVFILE" >/dev/null <<'EOF'
# fm-processor.service knobs — edit, then: sudo systemctl restart fm-processor
#
# Pin the DDS LAN interface if auto-detection picks the wrong IP at boot:
#FM_LAN_IP=192.168.1.42
#ROS_DOMAIN_ID=0
# Where the recorder's sessions.jsonl + episode bags live (same host today):
FM_PROCESSOR_RECORDINGS_DIR=/data/recordings
# Per-episode processing output root (<id>/manifest.json is the processed marker):
FM_PROCESSOR_OUTPUT_DIR=/data/processed
# Processing profile JSON for dataset_process --config (empty = engine default):
FM_PROCESSOR_CONFIG=
# Interpreter for the dataset_process subprocess. Empty auto-uses the workspace's
# .engine-venv (created by setup-processor.sh) so the engine's numpy pin never
# fights another tenant of the host's user site-packages:
#FM_PROCESSOR_ENGINE_PYTHON=
# Per-episode annotation bundle root:
FM_PROCESSOR_ANNOTATIONS_DIR=/data/annotations
# Processor-owned receipt-bound LeRobot imports. Keep this equal to
# FM_ARCHIVE_LEROBOT_STAGE_DIR in /etc/fm-archive.env when a custom root is used.
FM_PROCESSOR_LEROBOT_IMPORTS_DIR=/data/staged/lerobot
# Durable queued/running/generated/failed/blocked annotation attempt evidence:
FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=/data/annotations/runs/attempts
# Durable immutable review, correction, learning, governance, and run lineage:
FM_PROCESSOR_ANNOTATION_REVIEWS_DIR=/data/annotations/runs/reviews
FM_PROCESSOR_ANNOTATION_CORRECTIONS_DIR=/data/annotations/runs/corrections
FM_PROCESSOR_ANNOTATION_LEARNING_DIR=/data/annotations/runs/learning
FM_PROCESSOR_ANNOTATION_ADJUDICATIONS_DIR=/data/annotations/runs/adjudications
FM_PROCESSOR_ANNOTATION_REVOCATIONS_DIR=/data/annotations/runs/revocations
FM_PROCESSOR_ANNOTATION_LEARNING_SNAPSHOTS_DIR=/data/annotations/runs/learning-snapshots
FM_PROCESSOR_ANNOTATION_IMPROVEMENT_RUNS_DIR=/data/annotations/runs/improvement-runs
# Release export, Pack verification, LeRobot conversion, and the hf CLI use the
# isolated .release-venv installed by setup-processor.sh. The boot wrapper finds
# those paths automatically. Set only the approved private Hub destination here;
# authentication remains an operator action.
FM_PROCESSOR_RELEASE_ROOT=/data/releases
# Optional immutable container image digest used by release provenance:
#FM_PROCESSOR_RELEASE_RUNTIME_IMAGE_DIGEST=sha256:...
#FM_PROCESSOR_RELEASE_HUGGINGFACE_REPOSITORY=first-motive/private-dataset
# Optional selected operator evidence receipts for the desktop status surface:
#FM_PROCESSOR_OPERATOR_EVIDENCE_DIR=
# The boot wrapper resolves the nested data package HEAD and passes this exact source
# identity to the supervisor. Set only for an installed source tree with a
# separately reviewed commit; a short hash or all-zero sentinel is rejected.
#FM_PROCESSOR_ANNOTATE_GIT_COMMIT=
# Ohio persistent inference is opt-in. Uncomment all seven settings below after
# the Roles Anywhere identity has passed its check. Configuration alone never
# reports a worker ready: the readiness directory must contain fresh,
# profile-bound qwen2.5.json and qwen3.5.json receipts from the read-only AWS
# preflight. The bucket is intentionally blank; the installer never guesses it.
#FM_PROCESSOR_AWS_INFERENCE_SCRIPT=src/fm_data/fm_data_annotate/scripts/run_qwen_aws_service.sh
#FM_AWS_INFERENCE_SERVICE_MODE=1
#FM_AWS_INFERENCE_REGION=us-east-2
# The checked installed identity profile supplies FM_AWS_PROFILE; leave this
# unset unless the reviewed identity contract explicitly requires an override.
#FM_AWS_PROFILE=
#FM_AWS_INFERENCE_BUCKET=
#FM_AWS_INFERENCE_READINESS_DIR=/data/annotations/runs/aws-readiness
#FM_AWS_SERVICE_TIMEOUT_SECONDS=7200
EOF
    if [ "$processor_data_root" != /data ]; then
      sudo sed -i.bak "s#=/data/#=$processor_data_root/#g" "$ENVFILE"
      sudo rm -f "${ENVFILE}.bak"
    fi
  fi
  _migrate_processor_attempt_evidence || return 1
  _write_aws_service_env || return 1

  item "enabling + starting fm-processor.service ..."
  sudo systemctl daemon-reload
  sudo systemctl enable fm-processor.service
  sudo systemctl restart fm-processor.service

  cat <<EOF

fm-processor.service installed and started — it now comes up on every boot.

  status:  systemctl status fm-processor
  logs:    journalctl -u fm-processor -f
  stop:    sudo systemctl stop fm-processor
  config:  sudo nano $ENVFILE   (then: sudo systemctl restart fm-processor)

Kick off processing from the desktop app's Process window (it rides the capture
session's foxglove bridge). Manifests land under ~/processed/<episode_id>/.
EOF
}

do_uninstall() {
  _require_linux_systemd || return 0
  item "stopping + disabling fm-processor.service (if present) ..."
  sudo systemctl disable --now fm-processor.service 2>/dev/null || true
  sudo rm -f "$UNIT" "$ENVFILE" "$AWS_ENVFILE"
  sudo systemctl daemon-reload 2>/dev/null || true
  item "fm-processor.service removed."
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    uninstall) do_uninstall ;;
    ""|install) do_install ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
  esac
}

main "$@"
