#!/usr/bin/env bash
# install-processor-identity.sh — provision the processor's AWS Roles Anywhere
# identity without ever moving the private key off the tower.
#
# The installer is deliberately state based.  It creates (and then preserves) a
# P-384 key and CSR, pauses while an operator signs the CSR on the offline CA, and
# resumes when the public certificate and CA bundle are supplied.  Every durable
# file is written through a staging file and an atomic rename.  `check` never
# writes; `uninstall` removes only generated wiring and preserves identity
# material so a later install can resume.
#
# Required configuration is explicit.  Set these FM_AWS_IDENTITY_* values in the
# environment (or in the generated identity.env file):
#   ACCOUNT_ID, REGION, PROFILE, TRUST_ANCHOR_ARN, PROFILE_ARN, ROLE_ARN, BUCKET
# Region and account are intentionally fixed to the Ohio data plane.  This
# script installs no IAM or CloudFormation resources; the infrastructure layer
# owns those.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/lib.sh" ] && . "$ROOT/lib.sh"
if ! command -v item >/dev/null 2>&1; then item() { echo "$1"; }; fi

readonly AWS_CLI_VERSION="2.36.32"
readonly AWS_CLI_SHA256="ddd7a5aabf363f5b82085ef732c806d4fe73ad0d10e35cffedd5c3560f56a641"
readonly SIGNING_HELPER_VERSION="1.8.4"
readonly SIGNING_HELPER_SHA256="b7568acd6e1517a4e1adaee68d52bfd6284a0e5305677166cd83d43a07c815c9"
readonly AWS_ACCOUNT="624198668504"
readonly AWS_REGION="us-east-2"
readonly IDENTITY_PROFILE_DEFAULT="fmtower-processor"
readonly CERTIFICATE_CN="fmtower-processor"
readonly RENEWAL_WINDOW=2592000

IDENTITY_ETC_DIR="${FM_AWS_IDENTITY_ETC_DIR:-/etc/fm-aws-identity}"
IDENTITY_STATE_DIR="${FM_AWS_IDENTITY_STATE_DIR:-/var/lib/fm-processor/identity}"
IDENTITY_SYSTEMD_DIR="${FM_AWS_IDENTITY_SYSTEMD_DIR:-/etc/systemd/system}"
IDENTITY_SBIN_DIR="${FM_AWS_IDENTITY_SBIN_DIR:-/usr/local/sbin}"
IDENTITY_BIN_DIR="${FM_AWS_IDENTITY_BIN_DIR:-/usr/local/bin}"
IDENTITY_AWS_INSTALL_DIR="${FM_AWS_IDENTITY_AWS_INSTALL_DIR:-/usr/local/aws-cli}"
IDENTITY_CONFIG_FILE="${FM_AWS_IDENTITY_CONFIG_FILE:-$IDENTITY_ETC_DIR/identity.env}"
SERVICE_USER="${FM_AWS_IDENTITY_SERVICE_USER:-fm-processor}"
CALLER_USER="${FM_AWS_IDENTITY_CALLER_USER:-${SUDO_USER:-${USER:-}}}"
AWS_BIN="${FM_AWS_IDENTITY_AWS_PATH:-$IDENTITY_BIN_DIR/aws}"
SIGNING_HELPER_BIN="${FM_AWS_IDENTITY_SIGNING_HELPER_PATH:-$IDENTITY_BIN_DIR/aws_signing_helper}"
MONITOR_BIN="$IDENTITY_SBIN_DIR/fm-aws-identity-monitor"
CREDENTIAL_WRAPPER="$IDENTITY_SBIN_DIR/fm-aws-credential-process"
KEY_FILE="$IDENTITY_STATE_DIR/private-key.pem"
CSR_FILE="$IDENTITY_STATE_DIR/processor.csr.pem"
CERT_FILE="$IDENTITY_ETC_DIR/certificate.pem"
CA_FILE="$IDENTITY_ETC_DIR/ca.cert.pem"
PROFILE_FILE="$IDENTITY_ETC_DIR/aws-config"
RECEIPT_FILE="$IDENTITY_STATE_DIR/receipt.json"
DROPIN_DIR="$IDENTITY_SYSTEMD_DIR/fm-processor.service.d"
DROPIN_FILE="$DROPIN_DIR/10-fm-aws-identity.conf"
EXPIRY_SERVICE="$IDENTITY_SYSTEMD_DIR/fm-aws-identity-expiry.service"
WARNING_SERVICE="$IDENTITY_SYSTEMD_DIR/fm-aws-identity-expiry-warning.service"
EXPIRY_TIMER="$IDENTITY_SYSTEMD_DIR/fm-aws-identity-expiry.timer"
SUDOERS_FILE="${FM_AWS_IDENTITY_SUDOERS_FILE:-/etc/sudoers.d/fm-processor-aws-identity}"

# Test mode is intentionally opt-in.  It lets the offline CI test use a private
# temporary root and fake binaries without weakening a real tower install.
TEST_MODE="${FM_AWS_IDENTITY_TEST_MODE:-0}"
SKIP_DOWNLOAD="${FM_AWS_IDENTITY_SKIP_DOWNLOAD:-0}"
SKIP_SYSTEMD="${FM_AWS_IDENTITY_SKIP_SYSTEMD:-0}"
NO_ROOT="${FM_AWS_IDENTITY_NO_ROOT:-0}"
ROOT_OWNER="${FM_AWS_IDENTITY_ROOT_OWNER:-root}"
ROOT_GROUP="${FM_AWS_IDENTITY_ROOT_GROUP:-root}"
if [ "$TEST_MODE" = 1 ]; then
  ROOT_OWNER="${FM_AWS_IDENTITY_ROOT_OWNER:-$(id -un)}"
  ROOT_GROUP="${FM_AWS_IDENTITY_ROOT_GROUP:-$(id -gn)}"
fi

usage() {
  cat <<'EOF'
install-processor-identity.sh — install the Ohio Roles Anywhere processor identity

  install    create/preserve the key and CSR, then install a supplied certificate
             and profile, expiry monitor, timer, and processor service drop-in
  check      read-only validation; exits 3 while waiting for offline CA signing
  receipt    print safe JSON status (never prints a key or temporary credentials)
  uninstall  remove generated wiring only; preserve the key, CSR, CA, certificate
             and other identity material for a later resume

Configuration is supplied with FM_AWS_IDENTITY_ACCOUNT_ID, _REGION, _PROFILE,
_TRUST_ANCHOR_ARN, _PROFILE_ARN, _ROLE_ARN, and _BUCKET.  The accepted route is
account 624198668504 in us-east-2 with profile fmtower-processor.

For the offline boundary, set FM_AWS_IDENTITY_CERTIFICATE_INPUT and
FM_AWS_IDENTITY_CA_CERTIFICATE_INPUT to public PEM files, then run install again.
EOF
}

die() {
  echo "ERROR: $*" >&2
  return 1
}

warn_next() {
  echo "       next safe action: $*" >&2
}

root_run() {
  if [ "$NO_ROOT" = 1 ] || [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

root_install() { # mode owner group source destination
  local mode="$1" owner="$2" group="$3" source="$4" destination="$5"
  root_run install -m "$mode" -o "$owner" -g "$group" "$source" "$destination"
}

root_mkdir() { # mode owner group path
  local mode="$1" owner="$2" group="$3" path="$4"
  root_run install -d -m "$mode" -o "$owner" -g "$group" "$path"
}

atomic_install_text() { # mode owner group destination
  local mode="$1" owner="$2" group="$3" destination="$4" staging
  staging="$(mktemp "${TMPDIR:-/tmp}/fm-aws-identity.XXXXXX")"
  cat > "$staging"
  root_install "$mode" "$owner" "$group" "$staging" "${destination}.staging.$$"
  root_run mv -f "${destination}.staging.$$" "$destination"
  rm -f "$staging"
}

atomic_install_file() { # mode owner group source destination
  local mode="$1" owner="$2" group="$3" source="$4" destination="$5"
  root_install "$mode" "$owner" "$group" "$source" "${destination}.staging.$$"
  root_run mv -f "${destination}.staging.$$" "$destination"
}

load_identity_config() {
  [ -f "$IDENTITY_CONFIG_FILE" ] || return 0
  # The generated file is a simple systemd EnvironmentFile.  Read it before the
  # caller's environment, so an explicit invocation can override a stale file.
  local names=(
    FM_AWS_IDENTITY_ACCOUNT_ID FM_AWS_IDENTITY_REGION FM_AWS_IDENTITY_PROFILE
    FM_AWS_IDENTITY_TRUST_ANCHOR_ARN FM_AWS_IDENTITY_PROFILE_ARN
    FM_AWS_IDENTITY_ROLE_ARN FM_AWS_IDENTITY_BUCKET
  )
  local name value value_saved
  local -a saved=()
  for name in "${names[@]}"; do
    if [ "${!name+x}" ]; then
      value_saved="${!name}"
      saved+=("$name=$value_saved")
    fi
  done
  set -a
  # shellcheck source=/dev/null
  . "$IDENTITY_CONFIG_FILE"
  set +a
  for value in "${saved[@]}"; do
    name="${value%%=*}"
    value="${value#*=}"
    export "$name=$value"
  done
}

require_config() {
  FM_AWS_IDENTITY_ACCOUNT_ID="${FM_AWS_IDENTITY_ACCOUNT_ID:-${FM_AWS_IDENTITY_ACCOUNT:-}}"
  FM_AWS_IDENTITY_REGION="${FM_AWS_IDENTITY_REGION:-}"
  FM_AWS_IDENTITY_PROFILE="${FM_AWS_IDENTITY_PROFILE:-}"
  FM_AWS_IDENTITY_TRUST_ANCHOR_ARN="${FM_AWS_IDENTITY_TRUST_ANCHOR_ARN:-}"
  FM_AWS_IDENTITY_PROFILE_ARN="${FM_AWS_IDENTITY_PROFILE_ARN:-}"
  FM_AWS_IDENTITY_ROLE_ARN="${FM_AWS_IDENTITY_ROLE_ARN:-}"
  FM_AWS_IDENTITY_BUCKET="${FM_AWS_IDENTITY_BUCKET:-}"

  local name missing=0
  for name in ACCOUNT_ID REGION PROFILE TRUST_ANCHOR_ARN PROFILE_ARN ROLE_ARN BUCKET; do
    # shellcheck disable=SC2163
    eval "value=\${FM_AWS_IDENTITY_$name:-}"
    if [ -z "${value:-}" ]; then
      echo "ERROR: FM_AWS_IDENTITY_$name is required; refusing an implicit AWS target." >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || return 1

  [ "$FM_AWS_IDENTITY_ACCOUNT_ID" = "$AWS_ACCOUNT" ] || {
    die "AWS account must be $AWS_ACCOUNT (got '$FM_AWS_IDENTITY_ACCOUNT_ID')"
    return 1
  }
  [ "$FM_AWS_IDENTITY_REGION" = "$AWS_REGION" ] || {
    die "AWS region must be $AWS_REGION (Ohio); Virginia or another fallback is forbidden"
    return 1
  }
  [ "$FM_AWS_IDENTITY_PROFILE" = "$IDENTITY_PROFILE_DEFAULT" ] || {
    die "AWS profile must be $IDENTITY_PROFILE_DEFAULT (got '$FM_AWS_IDENTITY_PROFILE')"
    return 1
  }
  case "$FM_AWS_IDENTITY_PROFILE" in *[!A-Za-z0-9._-]*) die "profile contains unsafe characters"; return 1 ;; esac
  case "$FM_AWS_IDENTITY_BUCKET" in *[!a-z0-9.-]*|.*|*-|[.-]*) die "bucket must be a plain Ohio data-plane bucket name"; return 1 ;; esac
  case "$FM_AWS_IDENTITY_TRUST_ANCHOR_ARN" in *[!A-Za-z0-9:/_-]*) die "trust-anchor ARN contains unsafe characters"; return 1 ;; esac
  case "$FM_AWS_IDENTITY_PROFILE_ARN" in *[!A-Za-z0-9:/_-]*) die "profile ARN contains unsafe characters"; return 1 ;; esac
  case "$FM_AWS_IDENTITY_ROLE_ARN" in *[!A-Za-z0-9+=,.@_:/-]*) die "role ARN contains unsafe characters"; return 1 ;; esac
  case "$FM_AWS_IDENTITY_TRUST_ANCHOR_ARN" in
    arn:aws:rolesanywhere:"$AWS_REGION":"$AWS_ACCOUNT":trust-anchor/*) ;;
    *) die "trust-anchor ARN is not scoped to account $AWS_ACCOUNT in $AWS_REGION"; return 1 ;;
  esac
  case "$FM_AWS_IDENTITY_PROFILE_ARN" in
    arn:aws:rolesanywhere:"$AWS_REGION":"$AWS_ACCOUNT":profile/*) ;;
    *) die "profile ARN is not scoped to account $AWS_ACCOUNT in $AWS_REGION"; return 1 ;;
  esac
  case "$FM_AWS_IDENTITY_ROLE_ARN" in
    arn:aws:iam::"$AWS_ACCOUNT":role/*) ;;
    *) die "role ARN is not scoped to account $AWS_ACCOUNT"; return 1 ;;
  esac

  export FM_AWS_IDENTITY_ACCOUNT_ID FM_AWS_IDENTITY_REGION FM_AWS_IDENTITY_PROFILE
  export FM_AWS_IDENTITY_TRUST_ANCHOR_ARN FM_AWS_IDENTITY_PROFILE_ARN
  export FM_AWS_IDENTITY_ROLE_ARN FM_AWS_IDENTITY_BUCKET
}

require_linux() {
  [ "$(uname -s)" = Linux ] || {
    echo "WARNING: the Roles Anywhere processor identity is Linux-only — skipping." >&2
    return 1
  }
  return 0
}

verify_tool_version() { # tool expected version
  local tool="$1" expected="$2" output
  [ -x "$tool" ] || return 1
  output="$($tool --version 2>&1 || true)"
  if printf '%s\n' "$output" | grep -Fq "$expected"; then
    return 0
  fi
  output="$($tool version 2>&1 || true)"
  printf '%s\n' "$output" | grep -Fq "$expected"
}

ensure_architecture() {
  [ "$(uname -m)" = x86_64 ] || {
    die "this pinned bootstrap is x86_64-only (host reports $(uname -m)); use a reviewed arm64 pin"
    return 1
  }
}

install_aws_cli() {
  local tmp actual url
  command -v curl >/dev/null 2>&1 || { die "curl is required to install AWS CLI $AWS_CLI_VERSION"; return 1; }
  command -v sha256sum >/dev/null 2>&1 || { die "sha256sum is required to verify AWS CLI"; return 1; }
  command -v unzip >/dev/null 2>&1 || { die "unzip is required to install AWS CLI"; return 1; }
  url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fm-aws-cli.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL --proto '=https' --proto-redir '=https' "$url" -o "$tmp/aws.zip"
  actual="$(sha256sum "$tmp/aws.zip" | awk '{print $1}')"
  [ "$actual" = "$AWS_CLI_SHA256" ] || {
    die "AWS CLI checksum mismatch (wanted $AWS_CLI_SHA256, got $actual)"
    return 1
  }
  unzip -q "$tmp/aws.zip" -d "$tmp"
  root_run mkdir -p "$IDENTITY_BIN_DIR" "$IDENTITY_AWS_INSTALL_DIR"
  if [ -x "$IDENTITY_AWS_INSTALL_DIR/v2/current/bin/aws" ]; then
    root_run "$tmp/aws/install" --install-dir "$IDENTITY_AWS_INSTALL_DIR" \
      --bin-dir "$IDENTITY_BIN_DIR" --update
  else
    root_run "$tmp/aws/install" --install-dir "$IDENTITY_AWS_INSTALL_DIR" \
      --bin-dir "$IDENTITY_BIN_DIR"
  fi
  trap - RETURN
  rm -rf "$tmp"
}

install_signing_helper() {
  local tmp actual url
  command -v curl >/dev/null 2>&1 || { die "curl is required to install aws_signing_helper"; return 1; }
  command -v sha256sum >/dev/null 2>&1 || { die "sha256sum is required to verify aws_signing_helper"; return 1; }
  url="https://rolesanywhere.amazonaws.com/releases/${SIGNING_HELPER_VERSION}/X86_64/Linux/Amzn2023/aws_signing_helper"
  tmp="$(mktemp "${TMPDIR:-/tmp}/aws_signing_helper.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  curl -fsSL --proto '=https' --proto-redir '=https' "$url" -o "$tmp"
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  [ "$actual" = "$SIGNING_HELPER_SHA256" ] || {
    die "aws_signing_helper checksum mismatch (wanted $SIGNING_HELPER_SHA256, got $actual)"
    return 1
  }
  root_run mkdir -p "$(dirname "$SIGNING_HELPER_BIN")"
  root_install 0755 "$ROOT_OWNER" "$ROOT_GROUP" "$tmp" "$SIGNING_HELPER_BIN"
  trap - RETURN
  rm -f "$tmp"
}

ensure_toolchain() { # mode
  local mode="$1"
  ensure_architecture
  if ! verify_tool_version "$AWS_BIN" "$AWS_CLI_VERSION"; then
    if [ "$mode" = check ] || [ "$SKIP_DOWNLOAD" = 1 ]; then
      die "AWS CLI $AWS_CLI_VERSION is not installed at $AWS_BIN (check is non-mutating)"
      return 1
    fi
    item "installing and verifying pinned AWS CLI $AWS_CLI_VERSION ..."
    install_aws_cli
  fi
  verify_tool_version "$AWS_BIN" "$AWS_CLI_VERSION" || {
    die "AWS CLI at $AWS_BIN is not the pinned $AWS_CLI_VERSION"
    return 1
  }
  if ! verify_tool_version "$SIGNING_HELPER_BIN" "$SIGNING_HELPER_VERSION"; then
    if [ "$mode" = check ] || [ "$SKIP_DOWNLOAD" = 1 ]; then
      die "aws_signing_helper $SIGNING_HELPER_VERSION is not installed at $SIGNING_HELPER_BIN (check is non-mutating)"
      return 1
    fi
    item "installing and verifying pinned aws_signing_helper $SIGNING_HELPER_VERSION ..."
    install_signing_helper
  fi
  verify_tool_version "$SIGNING_HELPER_BIN" "$SIGNING_HELPER_VERSION" || {
    die "aws_signing_helper at $SIGNING_HELPER_BIN is not the pinned $SIGNING_HELPER_VERSION"
    return 1
  }
}

service_group() {
  if [ "$TEST_MODE" = 1 ] && ! id "$SERVICE_USER" >/dev/null 2>&1; then
    printf '%s\n' "$(id -gn)"
  else
    id -gn "$SERVICE_USER" 2>/dev/null || printf '%s\n' "$SERVICE_USER"
  fi
}

ensure_service_user() {
  local shell group
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    if [ "$TEST_MODE" = 1 ]; then
      return 0
    fi
    [ "$SERVICE_USER" = fm-processor ] || { die "service identity $SERVICE_USER does not exist"; return 1; }
    command -v useradd >/dev/null 2>&1 || { die "useradd is required to create fm-processor"; return 1; }
    root_run useradd --system --home-dir /var/lib/fm-processor --shell /usr/sbin/nologin \
      --create-home "$SERVICE_USER"
  fi
  shell="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f7 || true)"
  if [ -n "$shell" ] && [ "$shell" != /usr/sbin/nologin ] && [ "$shell" != /bin/false ]; then
    [ "$TEST_MODE" = 1 ] || root_run usermod --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  group="$(service_group)"
  root_mkdir 0700 "$SERVICE_USER" "$group" "$IDENTITY_STATE_DIR"
  root_mkdir 0755 "$ROOT_OWNER" "$ROOT_GROUP" "$IDENTITY_ETC_DIR"
}

ensure_key() {
  local group
  group="$(service_group)"
  if [ -e "$KEY_FILE" ]; then
    [ -f "$KEY_FILE" ] || { die "$KEY_FILE is not a regular file"; return 1; }
    openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 || { die "existing processor key is unreadable"; return 1; }
    if ! openssl pkey -in "$KEY_FILE" -text -noout 2>/dev/null | grep -Eiq 'secp384r1|P-384'; then
      die "existing processor key is not the required EC P-384 key"
      return 1
    fi
    root_run chown "$SERVICE_USER:$group" "$KEY_FILE"
    root_run chmod 600 "$KEY_FILE"
    return 0
  fi
  item "creating the processor's tower-local EC P-384 private key ..."
  local staging
  staging="$(mktemp "${TMPDIR:-/tmp}/fm-processor-key.XXXXXX")"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$staging" >/dev/null 2>&1
  root_install 0600 "$SERVICE_USER" "$group" "$staging" "${KEY_FILE}.staging.$$"
  root_run mv -f "${KEY_FILE}.staging.$$" "$KEY_FILE"
  rm -f "$staging"
}

ensure_csr() {
  local subject csr_digest key_digest reason staging
  if [ -e "$CSR_FILE" ]; then
    [ -f "$CSR_FILE" ] || { die "$CSR_FILE is not a regular file"; return 1; }
    reason=""
    if ! openssl req -in "$CSR_FILE" -noout -verify >/dev/null 2>&1; then
      reason="it is unreadable or its self-signature is invalid"
    else
      subject="$(openssl req -in "$CSR_FILE" -nameopt RFC2253 -noout -subject 2>/dev/null || true)"
      case "$subject" in
        *"CN=$CERTIFICATE_CN"*) ;;
        *) reason="its subject is not CN=$CERTIFICATE_CN" ;;
      esac
      key_digest="$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null | \
        openssl dgst -sha256 -binary | od -An -tx1 | tr -d ' \n')"
      csr_digest="$(openssl req -in "$CSR_FILE" -pubkey -noout 2>/dev/null | \
        openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 -binary | \
        od -An -tx1 | tr -d ' \n')"
      if [ -z "$key_digest" ] || [ "$key_digest" != "$csr_digest" ]; then
        reason="its public key does not match the tower-local private key"
      fi
    fi
    if [ -z "$reason" ]; then
      return 0
    fi
    item "replacing the stale processor CSR because $reason ..."
  fi
  if [ ! -e "$CSR_FILE" ]; then
    item "creating the processor CSR (the encrypted CA key stays offline) ..."
  fi
  staging="$(mktemp "${TMPDIR:-/tmp}/fm-processor-csr.XXXXXX")"
  openssl req -new -sha384 -key "$KEY_FILE" -subj "/CN=$CERTIFICATE_CN" -out "$staging" >/dev/null 2>&1
  root_install 0644 "$SERVICE_USER" "$(service_group)" "$staging" "${CSR_FILE}.staging.$$"
  root_run mv -f "${CSR_FILE}.staging.$$" "$CSR_FILE"
  rm -f "$staging"
}

certificate_subject() {
  openssl x509 -in "$1" -nameopt RFC2253 -noout -subject 2>/dev/null || true
}

verify_certificate() { # certificate ca key
  local certificate="$1" ca="$2" key="$3" subject cert_pub key_pub
  [ -r "$certificate" ] || { die "certificate is not readable: $certificate"; return 1; }
  [ -r "$ca" ] || { die "CA certificate is not readable: $ca"; return 1; }
  openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || { die "certificate is not valid PEM"; return 1; }
  if ! openssl x509 -in "$ca" -text -noout 2>/dev/null | grep -Eiq 'CA:TRUE'; then
    die "configured CA certificate is not marked CA:TRUE"
    return 1
  fi
  if ! openssl x509 -in "$ca" -text -noout 2>/dev/null | grep -Eiq 'Certificate Sign|keyCertSign'; then
    die "configured CA certificate cannot sign certificates (keyCertSign is missing)"
    return 1
  fi
  openssl x509 -in "$ca" -checkend "$RENEWAL_WINDOW" -noout >/dev/null 2>&1 || {
    die "configured CA certificate expires inside the 30-day renewal window"
    return 1
  }
  subject="$(certificate_subject "$certificate")"
  case "$subject" in *"CN=$CERTIFICATE_CN"*) ;; *) die "certificate subject must contain CN=$CERTIFICATE_CN"; return 1 ;; esac
  openssl verify -CAfile "$ca" "$certificate" >/dev/null 2>&1 || { die "certificate chain does not verify against the installed CA"; return 1; }
  if ! openssl x509 -in "$certificate" -text -noout 2>/dev/null | grep -Eiq 'CA:FALSE'; then
    die "processor certificate must be marked CA:FALSE"
    return 1
  fi
  if ! openssl x509 -in "$certificate" -text -noout 2>/dev/null | grep -Eiq 'Digital Signature|digitalSignature'; then
    die "processor certificate must permit digitalSignature"
    return 1
  fi
  if ! openssl x509 -in "$certificate" -text -noout 2>/dev/null | grep -Eiq 'TLS Web Client Authentication|clientAuth'; then
    die "certificate must include the TLS Web Client Authentication EKU"
    return 1
  fi
  openssl x509 -in "$certificate" -checkend 0 -noout >/dev/null 2>&1 || { die "certificate is expired"; return 1; }
  openssl x509 -in "$certificate" -checkend "$RENEWAL_WINDOW" -noout >/dev/null 2>&1 || {
    die "certificate expires inside the 30-day renewal window"
    return 1
  }
  openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | \
    openssl dgst -sha256 -binary | od -An -tx1 | tr -d ' \n' > "${TMPDIR:-/tmp}/fm-key-digest.$$"
  openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null | \
    openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 -binary | \
    od -An -tx1 | tr -d ' \n' > "${TMPDIR:-/tmp}/fm-cert-digest.$$"
  key_pub="$(cat "${TMPDIR:-/tmp}/fm-key-digest.$$")"
  cert_pub="$(cat "${TMPDIR:-/tmp}/fm-cert-digest.$$")"
  rm -f "${TMPDIR:-/tmp}/fm-key-digest.$$" "${TMPDIR:-/tmp}/fm-cert-digest.$$"
  [ -n "$key_pub" ] && [ "$key_pub" = "$cert_pub" ] || {
    die "certificate public key does not match the tower-local private key"
    return 1
  }
}

install_public_material() {
  local certificate_input ca_input candidate_ca candidate_cert
  certificate_input="${FM_AWS_IDENTITY_CERTIFICATE_INPUT:-${FM_AWS_IDENTITY_CERTIFICATE:-}}"
  ca_input="${FM_AWS_IDENTITY_CA_CERTIFICATE_INPUT:-${FM_AWS_IDENTITY_CA_CERTIFICATE:-}}"
  if [ -z "$certificate_input" ] && [ ! -f "$CERT_FILE" ] && [ -f "$IDENTITY_STATE_DIR/signed-certificate.pem" ]; then
    certificate_input="$IDENTITY_STATE_DIR/signed-certificate.pem"
  fi
  if [ -z "$ca_input" ] && [ ! -f "$CA_FILE" ] && [ -f "$IDENTITY_STATE_DIR/ca.cert.pem" ]; then
    ca_input="$IDENTITY_STATE_DIR/ca.cert.pem"
  fi
  candidate_ca="$CA_FILE"
  candidate_cert="$CERT_FILE"
  if [ -n "$ca_input" ] && [ -f "$ca_input" ]; then
    openssl x509 -in "$ca_input" -noout >/dev/null 2>&1 || { die "CA certificate input is not valid PEM"; return 1; }
    if ! openssl x509 -in "$ca_input" -text -noout 2>/dev/null | grep -Eiq 'CA:TRUE'; then
      die "CA certificate input is not a CA certificate"
      return 1
    fi
    if ! openssl x509 -in "$ca_input" -text -noout 2>/dev/null | grep -Eiq 'Certificate Sign|keyCertSign'; then
      die "CA certificate input cannot sign certificates (keyCertSign is missing)"
      return 1
    fi
    candidate_ca="$ca_input"
  fi
  if [ -n "$certificate_input" ] && [ -f "$certificate_input" ]; then
    openssl x509 -in "$certificate_input" -noout >/dev/null 2>&1 || { die "certificate input is not valid PEM"; return 1; }
    candidate_cert="$certificate_input"
  fi
  [ -f "$candidate_ca" ] || return 2
  [ -f "$candidate_cert" ] || return 3

  # Validate the complete candidate pair before replacing either active file.
  # This is what makes certificate rotation resumable: a bad CA or mismatched
  # certificate cannot destroy the last known-good pair.
  verify_certificate "$candidate_cert" "$candidate_ca" "$KEY_FILE" || return $?
  if [ -n "$ca_input" ] && [ -f "$ca_input" ] && { [ ! -f "$CA_FILE" ] || ! cmp -s "$ca_input" "$CA_FILE"; }; then
    atomic_install_file 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$ca_input" "$CA_FILE"
  fi
  if [ -n "$certificate_input" ] && [ -f "$certificate_input" ] && { [ ! -f "$CERT_FILE" ] || ! cmp -s "$certificate_input" "$CERT_FILE"; }; then
    atomic_install_file 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$certificate_input" "$CERT_FILE"
  fi
  verify_certificate "$CERT_FILE" "$CA_FILE" "$KEY_FILE" || return $?
}

write_identity_env() {
  atomic_install_text 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$IDENTITY_CONFIG_FILE" <<EOF
FM_AWS_IDENTITY_ACCOUNT_ID=$FM_AWS_IDENTITY_ACCOUNT_ID
FM_AWS_IDENTITY_REGION=$FM_AWS_IDENTITY_REGION
FM_AWS_IDENTITY_PROFILE=$FM_AWS_IDENTITY_PROFILE
FM_AWS_IDENTITY_TRUST_ANCHOR_ARN=$FM_AWS_IDENTITY_TRUST_ANCHOR_ARN
FM_AWS_IDENTITY_PROFILE_ARN=$FM_AWS_IDENTITY_PROFILE_ARN
FM_AWS_IDENTITY_ROLE_ARN=$FM_AWS_IDENTITY_ROLE_ARN
FM_AWS_IDENTITY_BUCKET=$FM_AWS_IDENTITY_BUCKET
FM_AWS_IDENTITY_SERVICE_USER=$SERVICE_USER
EOF
}

write_credential_wrapper() {
  atomic_install_text 0755 "$ROOT_OWNER" "$ROOT_GROUP" "$CREDENTIAL_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IDENTITY_ENV="$IDENTITY_CONFIG_FILE"
[ -r "\$IDENTITY_ENV" ] || { echo "credential_process: identity config is missing" >&2; exit 1; }
PROCESSOR_USER="$SERVICE_USER"
# The host processor service runs as the installing user for access to its data
# tree.  A narrow sudoers rule below invokes this wrapper as fm-processor, which
# is the only account allowed to read the 0600 private key.  In the container the
# wrapper normally runs as root, so it executes directly without sudo.
if [ "\$(id -un)" != "\$PROCESSOR_USER" ] && id "\$PROCESSOR_USER" >/dev/null 2>&1; then
  command -v sudo >/dev/null 2>&1 || { echo "credential_process: sudo is required for the fm-processor key boundary" >&2; exit 1; }
  exec sudo -n -u "\$PROCESSOR_USER" -- "\$0" "\$@"
fi
. "\$IDENTITY_ENV"
[ "\${FM_AWS_IDENTITY_REGION:-}" = "$AWS_REGION" ] || { echo "credential_process: region is not Ohio" >&2; exit 1; }
exec "$SIGNING_HELPER_BIN" credential-process \\
  --certificate "$CERT_FILE" \\
  --private-key "$KEY_FILE" \\
  --trust-anchor-arn "\$FM_AWS_IDENTITY_TRUST_ANCHOR_ARN" \\
  --profile-arn "\$FM_AWS_IDENTITY_PROFILE_ARN" \\
  --role-arn "\$FM_AWS_IDENTITY_ROLE_ARN"
EOF
}

write_profile() {
  atomic_install_text 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$PROFILE_FILE" <<EOF
[profile $FM_AWS_IDENTITY_PROFILE]
region = $AWS_REGION
credential_process = $CREDENTIAL_WRAPPER
EOF
}

write_dropin() {
  root_mkdir 0755 "$ROOT_OWNER" "$ROOT_GROUP" "$DROPIN_DIR"
  atomic_install_text 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$DROPIN_FILE" <<EOF
[Service]
Environment=AWS_CONFIG_FILE=$PROFILE_FILE
Environment=AWS_PROFILE=$FM_AWS_IDENTITY_PROFILE
Environment=AWS_DEFAULT_PROFILE=$FM_AWS_IDENTITY_PROFILE
Environment=FM_AWS_PROFILE=$FM_AWS_IDENTITY_PROFILE
Environment=AWS_DEFAULT_REGION=$AWS_REGION
Environment=AWS_REGION=$AWS_REGION
ExecStartPre=$MONITOR_BIN
EOF
}

write_units() {
  atomic_install_text 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$EXPIRY_SERVICE" <<EOF
[Unit]
Description=Check the First Motive processor Roles Anywhere certificate

[Service]
Type=oneshot
User=root
ExecStart=$MONITOR_BIN
OnFailure=fm-aws-identity-expiry-warning.service
EOF
  atomic_install_text 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$WARNING_SERVICE" <<EOF
[Unit]
Description=Warn that the First Motive processor certificate needs attention

[Service]
Type=oneshot
ExecStart=/usr/bin/logger -p authpriv.crit -t fm-aws-identity "processor certificate is expired or inside its 30-day renewal window"
EOF
  atomic_install_text 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$EXPIRY_TIMER" <<EOF
[Unit]
Description=Periodic First Motive processor certificate check

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
Persistent=true
RandomizedDelaySec=5min
Unit=fm-aws-identity-expiry.service

[Install]
WantedBy=timers.target
EOF
}

install_monitor() {
  [ -f "$ROOT/scripts/service/fm-aws-identity-monitor.sh" ] || { die "identity monitor source is missing"; return 1; }
  root_mkdir 0755 "$ROOT_OWNER" "$ROOT_GROUP" "$IDENTITY_SBIN_DIR"
  root_install 0755 "$ROOT_OWNER" "$ROOT_GROUP" "$ROOT/scripts/service/fm-aws-identity-monitor.sh" "$MONITOR_BIN"
}

install_sudoers() {
  [ -n "$CALLER_USER" ] || return 0
  [ "$CALLER_USER" = root ] && return 0
  [ "$CALLER_USER" != "$SERVICE_USER" ] || return 0
  [ "$TEST_MODE" = 1 ] && return 0
  command -v visudo >/dev/null 2>&1 || { die "visudo is required to validate the narrow key-operation rule"; return 1; }
  local staging
  staging="$(mktemp "${TMPDIR:-/tmp}/fm-aws-sudoers.XXXXXX")"
  printf '%s ALL=(%s) NOPASSWD: %s\n' "$CALLER_USER" "$SERVICE_USER" "$CREDENTIAL_WRAPPER" > "$staging"
  visudo -c -f "$staging" >/dev/null
  root_install 0440 "$ROOT_OWNER" "$ROOT_GROUP" "$staging" "$SUDOERS_FILE"
  rm -f "$staging"
}

systemd_ready() {
  [ "$SKIP_SYSTEMD" = 1 ] && return 1
  command -v systemctl >/dev/null 2>&1
}

enable_units() {
  systemd_ready || return 0
  root_run systemctl daemon-reload
  root_run systemctl enable --now fm-aws-identity-expiry.timer
}

write_receipt() { # status
  local status="$1" ready=false
  [ "$status" = ready ] && ready=true
  atomic_install_text 0644 "$ROOT_OWNER" "$ROOT_GROUP" "$RECEIPT_FILE" <<EOF
{
  "schema": "fm-processor-aws-identity-v1",
  "ready": $ready,
  "status": "$status",
  "account": "$FM_AWS_IDENTITY_ACCOUNT_ID",
  "region": "$AWS_REGION",
  "profile": "$FM_AWS_IDENTITY_PROFILE",
  "certificate_cn": "$CERTIFICATE_CN",
  "certificate": "$CERT_FILE",
  "ca_certificate": "$CA_FILE",
  "csr": "$CSR_FILE",
  "key": "$KEY_FILE",
  "aws_cli": "$AWS_CLI_VERSION",
  "aws_signing_helper": "$SIGNING_HELPER_VERSION"
}
EOF
}

status_from_files() {
  if [ ! -f "$KEY_FILE" ]; then printf '%s\n' missing_key; return; fi
  if [ ! -f "$CSR_FILE" ]; then printf '%s\n' missing_csr; return; fi
  if [ ! -f "$CA_FILE" ]; then printf '%s\n' pending_ca; return; fi
  if [ ! -f "$CERT_FILE" ]; then printf '%s\n' pending_signed_certificate; return; fi
  printf '%s\n' ready
}

do_install() {
  require_linux || return 0
  load_identity_config
  require_config
  ensure_architecture
  ensure_service_user
  ensure_toolchain install
  ensure_key
  ensure_csr

  local material_status
  set +e
  install_public_material
  material_status=$?
  set -e
  if [ "$material_status" -eq 2 ]; then
    write_receipt pending_ca
    echo "CSR ready at $CSR_FILE, but no CA certificate is installed." >&2
    warn_next "copy the public CA certificate to the tower and rerun this installer"
    return 3
  fi
  if [ "$material_status" -eq 3 ]; then
    write_receipt pending_signed_certificate
    echo "CSR ready at $CSR_FILE; waiting at the offline CA approval boundary." >&2
    warn_next "sign the CSR offline, copy the signed certificate to $IDENTITY_STATE_DIR/signed-certificate.pem, and rerun"
    return 3
  fi
  [ "$material_status" -eq 0 ] || return "$material_status"

  write_identity_env
  write_profile
  install_monitor
  write_credential_wrapper
  write_dropin
  write_units
  install_sudoers
  enable_units
  write_receipt ready
  item "processor identity ready: $FM_AWS_IDENTITY_PROFILE in $AWS_REGION (certificate expires after verification)"
}

do_check() {
  require_linux || return 0
  load_identity_config
  require_config
  ensure_architecture
  ensure_toolchain check
  [ -d "$IDENTITY_STATE_DIR" ] || { die "identity state directory is missing: $IDENTITY_STATE_DIR"; return 1; }
  [ -f "$KEY_FILE" ] || { die "processor key is missing: $KEY_FILE"; return 1; }
  [ "$(stat -c '%a' "$KEY_FILE" 2>/dev/null || stat -f '%Lp' "$KEY_FILE")" = 600 ] || {
    die "processor private key must be mode 0600"; return 1;
  }
  [ -f "$CSR_FILE" ] || { die "processor CSR is missing: $CSR_FILE"; return 1; }
  [ -f "$CA_FILE" ] || { echo "check: waiting for the offline CA certificate" >&2; return 3; }
  [ -f "$CERT_FILE" ] || { echo "check: waiting for the signed processor certificate" >&2; return 3; }
  verify_certificate "$CERT_FILE" "$CA_FILE" "$KEY_FILE"
  [ -f "$PROFILE_FILE" ] || { die "credential_process profile is missing: $PROFILE_FILE"; return 1; }
  grep -Fq "credential_process = $CREDENTIAL_WRAPPER" "$PROFILE_FILE" || { die "profile credential_process is not pinned to the wrapper"; return 1; }
  [ -f "$DROPIN_FILE" ] || { die "processor service identity drop-in is missing"; return 1; }
  [ -f "$EXPIRY_TIMER" ] || { die "identity expiry timer is missing"; return 1; }
  printf 'check: processor identity valid (account=%s region=%s profile=%s)\n' \
    "$FM_AWS_IDENTITY_ACCOUNT_ID" "$AWS_REGION" "$FM_AWS_IDENTITY_PROFILE"
}

do_receipt() {
  load_identity_config
  if [ -f "$RECEIPT_FILE" ]; then
    sed -E 's#("key": ")[^"]+(" )#\1[redacted]\2#' "$RECEIPT_FILE"
    return 0
  fi
  require_config
  printf '{"schema":"fm-processor-aws-identity-v1","ready":false,"status":"%s","region":"%s","profile":"%s"}\n' \
    "$(status_from_files)" "$AWS_REGION" "${FM_AWS_IDENTITY_PROFILE:-$IDENTITY_PROFILE_DEFAULT}"
}

do_uninstall() {
  require_linux || return 0
  if systemd_ready; then
    root_run systemctl disable --now fm-aws-identity-expiry.timer 2>/dev/null || true
    root_run systemctl disable --now fm-aws-identity-expiry.service 2>/dev/null || true
  fi
  # Do not remove KEY_FILE, CSR_FILE, CA_FILE, CERT_FILE, or RECEIPT_FILE. They
  # are the resumable identity record and the private key never leaves the tower.
  local path
  for path in "$PROFILE_FILE" "$IDENTITY_CONFIG_FILE" "$DROPIN_FILE" "$EXPIRY_SERVICE" "$WARNING_SERVICE" "$EXPIRY_TIMER" "$MONITOR_BIN" "$CREDENTIAL_WRAPPER" "$SUDOERS_FILE"; do
    root_run rm -f "$path"
  done
  root_run rmdir "$DROPIN_DIR" 2>/dev/null || true
  if systemd_ready; then root_run systemctl daemon-reload 2>/dev/null || true; fi
  item "processor identity wiring removed; key, CSR, CA, certificate, and receipt preserved"
}

main() {
  case "${1:-install}" in
    -h|--help) usage; return 0 ;;
    install) do_install ;;
    check|--check) do_check ;;
    receipt|--receipt) do_receipt ;;
    uninstall|--uninstall) do_uninstall ;;
    *) echo "error: unknown mode '$1'" >&2; usage >&2; return 2 ;;
  esac
}

main "$@"
