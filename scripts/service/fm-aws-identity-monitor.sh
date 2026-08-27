#!/usr/bin/env bash
# fm-aws-identity-monitor.sh — fail-closed certificate check for the processor.
#
# This script is safe to run as a systemd ExecStartPre (the processor account only
# needs the public certificate and CA) or as the root-owned six-hour timer.  It
# never calls AWS and never prints key material or credentials.
set -euo pipefail

CERTIFICATE="${FM_AWS_IDENTITY_CERTIFICATE_PATH:-/etc/fm-aws-identity/certificate.pem}"
CA_CERTIFICATE="${FM_AWS_IDENTITY_CA_CERTIFICATE_PATH:-/etc/fm-aws-identity/ca.cert.pem}"
EXPECTED_CN="${FM_AWS_IDENTITY_EXPECTED_CN:-fmtower-processor}"
WARNING_SECONDS="${FM_AWS_IDENTITY_RENEWAL_WINDOW:-2592000}"
LOG_TAG="${FM_AWS_IDENTITY_LOG_TAG:-fm-aws-identity}"

fail_closed() {
  local message="$1"
  if command -v logger >/dev/null 2>&1; then
    logger -p authpriv.err -t "$LOG_TAG" -- "$message" 2>/dev/null || true
  fi
  echo "ERROR: $message" >&2
  return 1
}

case "$WARNING_SECONDS" in
  ''|*[!0-9]*) fail_closed "renewal window must be a number of seconds"; exit 1 ;;
esac

command -v openssl >/dev/null 2>&1 || { fail_closed "openssl is required"; exit 1; }
[ -r "$CERTIFICATE" ] || { fail_closed "processor certificate is missing: $CERTIFICATE"; exit 1; }
[ -r "$CA_CERTIFICATE" ] || { fail_closed "processor CA certificate is missing: $CA_CERTIFICATE"; exit 1; }

openssl x509 -in "$CERTIFICATE" -noout >/dev/null 2>&1 || {
  fail_closed "processor certificate is not parseable: $CERTIFICATE"; exit 1;
}
subject="$(openssl x509 -in "$CERTIFICATE" -nameopt RFC2253 -noout -subject 2>/dev/null || true)"
case "$subject" in
  *"CN=$EXPECTED_CN"*) ;;
  *) fail_closed "processor certificate subject does not contain CN=$EXPECTED_CN"; exit 1 ;;
esac

if ! openssl x509 -in "$CERTIFICATE" -text -noout 2>/dev/null | \
    grep -Eiq 'TLS Web Client Authentication|clientAuth'; then
  fail_closed "processor certificate does not allow TLS Web Client Authentication"
  exit 1
fi
openssl verify -CAfile "$CA_CERTIFICATE" "$CERTIFICATE" >/dev/null 2>&1 || {
  fail_closed "processor certificate chain does not verify against the configured CA"
  exit 1
}
openssl x509 -in "$CERTIFICATE" -checkend 0 -noout >/dev/null 2>&1 || {
  fail_closed "processor certificate is expired"; exit 1
}
if ! openssl x509 -in "$CERTIFICATE" -checkend "$WARNING_SECONDS" -noout >/dev/null 2>&1; then
  fail_closed "processor certificate is inside its renewal window (${WARNING_SECONDS}s)"
  exit 1
fi

serial="$(openssl x509 -in "$CERTIFICATE" -noout -serial 2>/dev/null | sed 's/^serial=//')"
fingerprint="$(openssl x509 -in "$CERTIFICATE" -noout -fingerprint -sha256 2>/dev/null | sed 's/^sha256 Fingerprint=//')"
not_after="$(openssl x509 -in "$CERTIFICATE" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
printf 'processor certificate valid: path=%s serial=%s sha256=%s not_after=%s\n' \
  "$CERTIFICATE" "$serial" "$fingerprint" "$not_after"
