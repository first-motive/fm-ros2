#!/usr/bin/env bash
# Offline contract test for the processor Roles Anywhere installer. It uses real
# OpenSSL for key/CSR/certificate checks and fake pinned AWS binaries; no network,
# systemd, AWS account, or production private key is involved.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/etc" "$TMP_DIR/state" "$TMP_DIR/systemd" "$TMP_DIR/sbin"

cat > "$TMP_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -m ]; then echo x86_64; else echo Linux; fi
EOF
cat > "$TMP_DIR/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo 'aws-cli/2.36.32 Python/3.11 Linux/ci'
EOF
cat > "$TMP_DIR/bin/aws_signing_helper" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
  echo 'aws_signing_helper 1.8.4'
elif [ "${1:-}" = --version ]; then
  echo 'unknown flag: --version' >&2
  exit 2
else
  printf '{"Version":1,"AccessKeyId":"fake","SecretAccessKey":"fake","SessionToken":"fake","Expiration":"2099-01-01T00:00:00Z"}\n'
fi
EOF
chmod +x "$TMP_DIR/bin/uname" "$TMP_DIR/bin/aws" "$TMP_DIR/bin/aws_signing_helper"

export PATH="$TMP_DIR/bin:$PATH"
export FM_AWS_IDENTITY_TEST_MODE=1
export FM_AWS_IDENTITY_SKIP_DOWNLOAD=1
export FM_AWS_IDENTITY_SKIP_SYSTEMD=1
export FM_AWS_IDENTITY_NO_ROOT=1
FM_AWS_IDENTITY_ROOT_OWNER="$(id -un)"
export FM_AWS_IDENTITY_ROOT_OWNER
FM_AWS_IDENTITY_ROOT_GROUP="$(id -gn)"
export FM_AWS_IDENTITY_ROOT_GROUP
export FM_AWS_IDENTITY_ETC_DIR="$TMP_DIR/etc"
export FM_AWS_IDENTITY_STATE_DIR="$TMP_DIR/state"
export FM_AWS_IDENTITY_SYSTEMD_DIR="$TMP_DIR/systemd"
export FM_AWS_IDENTITY_SBIN_DIR="$TMP_DIR/sbin"
export FM_AWS_IDENTITY_SUDOERS_FILE="$TMP_DIR/etc/fm-processor-aws-identity.sudoers"
export FM_AWS_IDENTITY_BIN_DIR="$TMP_DIR/bin"
export FM_AWS_IDENTITY_AWS_PATH="$TMP_DIR/bin/aws"
export FM_AWS_IDENTITY_SIGNING_HELPER_PATH="$TMP_DIR/bin/aws_signing_helper"
FM_AWS_IDENTITY_SERVICE_USER="$(id -un)"
export FM_AWS_IDENTITY_SERVICE_USER
export FM_AWS_IDENTITY_ACCOUNT_ID=624198668504
export FM_AWS_IDENTITY_REGION=us-east-2
export FM_AWS_IDENTITY_PROFILE=fmtower-processor
export FM_AWS_IDENTITY_TRUST_ANCHOR_ARN=arn:aws:rolesanywhere:us-east-2:624198668504:trust-anchor/test
export FM_AWS_IDENTITY_PROFILE_ARN=arn:aws:rolesanywhere:us-east-2:624198668504:profile/test
export FM_AWS_IDENTITY_ROLE_ARN=arn:aws:iam::624198668504:role/first-motive-processor-test
export FM_AWS_IDENTITY_BUCKET=first-motive-test-bucket

IDENTITY="$ROOT/scripts/install/install-processor-identity.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if bash "$IDENTITY" install >"$TMP_DIR/first.out" 2>"$TMP_DIR/first.err"; then
  fail "first install must stop at the offline CA boundary"
else
  rc=$?
  [ "$rc" -eq 3 ] || fail "first install returned $rc, expected 3 while waiting for CA"
fi
[ -f "$TMP_DIR/state/private-key.pem" ] || fail "first install did not create the private key"
[ -f "$TMP_DIR/state/processor.csr.pem" ] || fail "first install did not create the CSR"
key_mode="$(stat -c '%a' "$TMP_DIR/state/private-key.pem" 2>/dev/null || stat -f '%Lp' "$TMP_DIR/state/private-key.pem")"
[ "$key_mode" = 600 ] || fail "private key is not mode 0600 (mode=$key_mode)"
pass "first install creates a protected key/CSR and pauses safely"

key_digest_before="$(openssl pkey -in "$TMP_DIR/state/private-key.pem" -pubout -outform DER | openssl dgst -sha256)"

# Sign the CSR with a local test CA carrying the same client-auth constraints as
# the offline tower CA. The CA key exists only in this temporary test directory.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$TMP_DIR/ca.key" >/dev/null 2>&1
openssl req -x509 -new -sha384 -key "$TMP_DIR/ca.key" -out "$TMP_DIR/ca.pem" \
  -days 3650 -subj '/CN=Offline Test CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl x509 -req -in "$TMP_DIR/state/processor.csr.pem" -CA "$TMP_DIR/ca.pem" \
  -CAkey "$TMP_DIR/ca.key" -CAcreateserial -out "$TMP_DIR/cert.pem" -days 365 \
  -sha384 -extfile <(printf '%s\n' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=clientAuth') >/dev/null 2>&1

FM_AWS_IDENTITY_CA_CERTIFICATE_INPUT="$TMP_DIR/ca.pem" \
FM_AWS_IDENTITY_CERTIFICATE_INPUT="$TMP_DIR/cert.pem" \
  bash "$IDENTITY" install >/dev/null
bash "$IDENTITY" check >/dev/null
pass "offline CA resume verifies chain, CN, CA:FALSE, digitalSignature, clientAuth, validity, and key match"

key_digest_after="$(openssl pkey -in "$TMP_DIR/state/private-key.pem" -pubout -outform DER | openssl dgst -sha256)"
[ "$key_digest_before" = "$key_digest_after" ] || fail "repeat install changed the private key"
pass "repeat install preserves the tower-local key"

if FM_AWS_IDENTITY_BUCKET='' bash "$IDENTITY" check >/dev/null 2>&1; then
  fail "missing required identity configuration was accepted"
fi
pass "missing required identity configuration fails closed"

if FM_AWS_IDENTITY_REGION=us-east-1 bash "$IDENTITY" check >/dev/null 2>&1; then
  fail "Virginia region was accepted"
fi
pass "non-Ohio region is rejected"

if FM_AWS_IDENTITY_ROLE_ARN=$'arn:aws:iam::624198668504:role/good\nBAD=value' \
    bash "$IDENTITY" check >/dev/null 2>&1; then
  fail "newline injection in an identity ARN was accepted"
fi
pass "identity config rejects shell and EnvironmentFile injection characters"

# A renewed certificate for the same tower key must replace only the public
# endpoint material. The private key and its digest stay fixed.
openssl x509 -req -in "$TMP_DIR/state/processor.csr.pem" -CA "$TMP_DIR/ca.pem" \
  -CAkey "$TMP_DIR/ca.key" -CAcreateserial -out "$TMP_DIR/renewed-cert.pem" \
  -days 365 -sha384 -extfile <(printf '%s\n' \
    'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=clientAuth') >/dev/null 2>&1
certificate_digest_before="$(openssl dgst -sha256 "$TMP_DIR/etc/certificate.pem")"
FM_AWS_IDENTITY_CERTIFICATE_INPUT="$TMP_DIR/renewed-cert.pem" bash "$IDENTITY" install >/dev/null
certificate_digest_after="$(openssl dgst -sha256 "$TMP_DIR/etc/certificate.pem")"
[ "$certificate_digest_before" != "$certificate_digest_after" ] || fail "certificate renewal did not activate the new public certificate"
[ "$key_digest_before" = "$(openssl pkey -in "$TMP_DIR/state/private-key.pem" -pubout -outform DER | openssl dgst -sha256)" ] || \
  fail "certificate renewal changed the tower-local key"
pass "certificate renewal replaces public material and preserves the private key"

# A bad certificate must be rejected before replacing the currently valid cert.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$TMP_DIR/wrong.key" >/dev/null 2>&1
openssl req -new -sha384 -key "$TMP_DIR/wrong.key" -subj '/CN=wrong-processor' -out "$TMP_DIR/wrong.csr" >/dev/null 2>&1
openssl x509 -req -in "$TMP_DIR/wrong.csr" -CA "$TMP_DIR/ca.pem" -CAkey "$TMP_DIR/ca.key" \
  -CAcreateserial -out "$TMP_DIR/wrong-cert.pem" -days 365 -sha384 -extfile <(printf '%s\n' \
    'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=clientAuth') >/dev/null 2>&1
valid_cert_digest="$(openssl dgst -sha256 "$TMP_DIR/etc/certificate.pem")"
if FM_AWS_IDENTITY_CERTIFICATE_INPUT="$TMP_DIR/wrong-cert.pem" bash "$IDENTITY" install >/dev/null 2>&1; then
  fail "mismatched certificate was accepted"
fi
[ "$valid_cert_digest" = "$(openssl dgst -sha256 "$TMP_DIR/etc/certificate.pem")" ] || \
  fail "invalid certificate replaced the valid installed certificate"
pass "mismatched certificate is rejected without replacing the active cert"

receipt="$(bash "$IDENTITY" receipt)"
printf '%s' "$receipt" | grep -Fq 'fm-processor-aws-identity-v1' || fail "receipt schema missing"
printf '%s' "$receipt" | grep -Fq 'private-key.pem' || fail "receipt lost the key path evidence"
if printf '%s' "$receipt" | grep -Eiq 'BEGIN (EC|RSA|PRIVATE) KEY|AccessKeyId|SecretAccessKey|SessionToken'; then
  fail "receipt contains secret material"
fi
pass "receipt mode emits safe status without key or temporary credentials"

bash "$IDENTITY" uninstall >/dev/null
[ -f "$TMP_DIR/state/private-key.pem" ] && [ -f "$TMP_DIR/etc/certificate.pem" ] || \
  fail "uninstall removed resumable identity material"
[ ! -f "$TMP_DIR/etc/aws-config" ] && [ ! -f "$TMP_DIR/sbin/fm-aws-credential-process" ] || \
  fail "uninstall left generated wiring"
pass "uninstall removes wiring and preserves key/certificate material"

grep -Fq ':ro' "$ROOT/compose.processor.aws.yaml" || fail "processor AWS overlay has no read-only identity mounts"
if grep -Fq 'fm-aws-credential-process' "$ROOT/compose.processor.yaml"; then
  fail "base processor overlay requires optional AWS identity mounts"
fi
( # The processor remains usable without cloud identity, and adds the separate
  # read-only overlay only when the durable profile exists.
  # shellcheck disable=SC1091
  . "$ROOT/scripts/internal/lib-processor.sh"
  rm -f "$TMP_DIR/etc/aws-config"
  fm_processor_compose "$ROOT"
  [[ " ${FM_COMPOSE[*]} " != *"compose.processor.aws.yaml"* ]] || exit 1
  touch "$TMP_DIR/etc/aws-config"
  fm_processor_compose "$ROOT"
  [[ " ${FM_COMPOSE[*]} " == *"compose.processor.aws.yaml"* ]]
) || fail "optional AWS compose overlay selection is incorrect"
grep -Eq 'AWS_CONFIG_FILE\|AWS_PROFILE' "$ROOT/scripts/service/container-exec.sh" || \
  fail "container exec does not document the explicit AWS allowlist"
pass "optional container identity mounts and AWS environment allowlist are present"

echo "processor identity: all checks passed"
