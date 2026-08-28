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

# A reset can remove the private key while a public CSR survives. The installer
# must replace that stale CSR with one derived from the new tower-local key.
stale_csr_digest="$(openssl req -in "$TMP_DIR/state/processor.csr.pem" -pubkey -noout | \
  openssl pkey -pubin -outform DER | openssl dgst -sha256)"
rm "$TMP_DIR/state/private-key.pem"
if bash "$IDENTITY" install >"$TMP_DIR/reset.out" 2>"$TMP_DIR/reset.err"; then
  fail "reset recovery must stop at the offline CA boundary"
else
  rc=$?
  [ "$rc" -eq 3 ] || fail "reset recovery returned $rc, expected 3 while waiting for CA"
fi
reset_key_digest="$(openssl pkey -in "$TMP_DIR/state/private-key.pem" -pubout -outform DER | openssl dgst -sha256)"
reset_csr_digest="$(openssl req -in "$TMP_DIR/state/processor.csr.pem" -pubkey -noout | \
  openssl pkey -pubin -outform DER | openssl dgst -sha256)"
[ "$reset_key_digest" = "$reset_csr_digest" ] || fail "reset recovery left a CSR that does not match the new key"
[ "$stale_csr_digest" != "$reset_csr_digest" ] || fail "reset recovery reused the stale CSR"
pass "reset recovery replaces a stale CSR without exporting the new private key"

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

expiry_unit="$TMP_DIR/systemd/fm-aws-identity-expiry.service"
[ -f "$expiry_unit" ] || fail "identity install did not write the expiry unit"
on_failure_line="$(grep -n '^OnFailure=fm-aws-identity-expiry-warning.service$' "$expiry_unit" | cut -d: -f1)"
service_line="$(grep -n '^\[Service\]$' "$expiry_unit" | cut -d: -f1)"
[ -n "$on_failure_line" ] && [ -n "$service_line" ] && [ "$on_failure_line" -lt "$service_line" ] || \
  fail "expiry unit places OnFailure outside [Unit]"
if awk '/^\[Service\]/{service=1} service && /^OnFailure=/{bad=1} END{exit bad}' "$expiry_unit"; then
  pass "expiry unit places OnFailure in [Unit]"
else
  fail "expiry unit places OnFailure in [Service]"
fi

# Older tower installs placed OnFailure under [Service].  check must reject that
# stale binding, while repair rewrites only the three expiry units and leaves all
# identity material untouched.
awk '
  /^OnFailure=fm-aws-identity-expiry-warning\.service$/ { next }
  /^\[Service\]$/ { print; print "OnFailure=fm-aws-identity-expiry-warning.service"; next }
  { print }
' "$expiry_unit" > "$expiry_unit.stale"
mv "$expiry_unit.stale" "$expiry_unit"
if bash "$IDENTITY" check >/dev/null 2>&1; then
  fail "check accepted an expiry OnFailure binding under [Service]"
fi
pass "check rejects a stale expiry OnFailure binding"

key_file_digest_before_repair="$(openssl dgst -sha256 "$TMP_DIR/state/private-key.pem" | awk '{print $2}')"
certificate_file_digest_before_repair="$(openssl dgst -sha256 "$TMP_DIR/etc/certificate.pem" | awk '{print $2}')"
identity_env_digest_before_repair="$(openssl dgst -sha256 "$TMP_DIR/etc/identity.env" | awk '{print $2}')"
printf 'exit 71\n' > "$TMP_DIR/forbidden-identity.env"
FM_AWS_IDENTITY_CONFIG_FILE="$TMP_DIR/forbidden-identity.env" \
  bash "$IDENTITY" --repair-expiry-units >/dev/null
pass "expiry repair rewrites the stale binding without reading identity.env"

for unit in "$expiry_unit" "$TMP_DIR/systemd/fm-aws-identity-expiry-warning.service" "$TMP_DIR/systemd/fm-aws-identity-expiry.timer"; do
  [ -f "$unit" ] || fail "expiry repair did not recreate $unit"
done
bash "$IDENTITY" check >/dev/null
repair_expiry_digest="$(openssl dgst -sha256 "$expiry_unit" | awk '{print $2}')"
repair_warning_digest="$(openssl dgst -sha256 "$TMP_DIR/systemd/fm-aws-identity-expiry-warning.service" | awk '{print $2}')"
repair_timer_digest="$(openssl dgst -sha256 "$TMP_DIR/systemd/fm-aws-identity-expiry.timer" | awk '{print $2}')"
FM_AWS_IDENTITY_CONFIG_FILE="$TMP_DIR/forbidden-identity.env" \
  bash "$IDENTITY" --repair-expiry-units >/dev/null
[ "$repair_expiry_digest" = "$(openssl dgst -sha256 "$expiry_unit" | awk '{print $2}')" ] || \
  fail "repeat expiry repair changed the expiry service"
[ "$repair_warning_digest" = "$(openssl dgst -sha256 "$TMP_DIR/systemd/fm-aws-identity-expiry-warning.service" | awk '{print $2}')" ] || \
  fail "repeat expiry repair changed the warning service"
[ "$repair_timer_digest" = "$(openssl dgst -sha256 "$TMP_DIR/systemd/fm-aws-identity-expiry.timer" | awk '{print $2}')" ] || \
  fail "repeat expiry repair changed the timer"
[ "$key_file_digest_before_repair" = "$(openssl dgst -sha256 "$TMP_DIR/state/private-key.pem" | awk '{print $2}')" ] || \
  fail "expiry repair changed the private key"
[ "$certificate_file_digest_before_repair" = "$(openssl dgst -sha256 "$TMP_DIR/etc/certificate.pem" | awk '{print $2}')" ] || \
  fail "expiry repair changed the certificate"
[ "$identity_env_digest_before_repair" = "$(openssl dgst -sha256 "$TMP_DIR/etc/identity.env" | awk '{print $2}')" ] || \
  fail "expiry repair changed identity.env"
pass "expiry repair is idempotent and preserves key, certificate, and identity.env"

bash "$IDENTITY" uninstall >/dev/null
[ -f "$TMP_DIR/state/private-key.pem" ] && [ -f "$TMP_DIR/etc/certificate.pem" ] || \
  fail "uninstall removed resumable identity material"
[ ! -f "$TMP_DIR/etc/aws-config" ] && [ ! -f "$TMP_DIR/sbin/fm-aws-credential-process" ] || \
  fail "uninstall left generated wiring"
pass "uninstall removes wiring and preserves key/certificate material"

grep -Fq ':ro' "$ROOT/compose.processor.aws.yaml" || fail "processor AWS overlay has no read-only identity mounts"
grep -Fq 'FM_AWS_IDENTITY_AWS_INSTALL_DIR' "$ROOT/compose.processor.aws.yaml" || \
  fail "processor AWS overlay does not mount the pinned AWS CLI tree"
grep -Fq 'v2/current/bin' "$ROOT/compose.processor.aws.yaml" || \
  fail "processor AWS overlay does not put the mounted CLI runtime on PATH"
if grep -Eq 'FM_AWS_IDENTITY_AWS_PATH.*:ro' "$ROOT/compose.processor.aws.yaml"; then
  fail "processor AWS overlay mounts the host AWS symlink instead of its runtime tree"
fi
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

# AWS CLI v2 is a directory runtime: its bin launcher is commonly a symlink to
# a sibling dist/ binary. The host preflight must require both pieces before the
# read-only tree is handed to Docker; this fixture proves the check without
# starting Docker or contacting AWS.
aws_tree="$TMP_DIR/aws-cli"
mkdir -p "$TMP_DIR/mount-etc" "$TMP_DIR/mount-state" "$aws_tree/v2/current/bin" "$aws_tree/v2/current/dist"
touch "$TMP_DIR/mount-etc/aws-config"
printf '%s\n' '#!/usr/bin/env bash' > "$aws_tree/v2/current/dist/aws"
chmod +x "$aws_tree/v2/current/dist/aws"
ln -s ../dist/aws "$aws_tree/v2/current/bin/aws"
if ! (
  export FM_AWS_IDENTITY_ETC_DIR="$TMP_DIR/mount-etc"
  export FM_AWS_IDENTITY_STATE_DIR="$TMP_DIR/mount-state"
  export FM_AWS_IDENTITY_AWS_INSTALL_DIR="$aws_tree"
  . "$ROOT/scripts/internal/lib-processor.sh"
  fm_processor_prepare_identity_mounts 2>/dev/null
); then
  fail "processor identity mount preflight rejected a complete AWS CLI v2 tree"
fi
rm "$aws_tree/v2/current/dist/aws"
if (
  export FM_AWS_IDENTITY_ETC_DIR="$TMP_DIR/mount-etc"
  export FM_AWS_IDENTITY_STATE_DIR="$TMP_DIR/mount-state"
  export FM_AWS_IDENTITY_AWS_INSTALL_DIR="$aws_tree"
  . "$ROOT/scripts/internal/lib-processor.sh"
  fm_processor_prepare_identity_mounts 2>/dev/null
); then
  fail "processor identity mount preflight accepted a broken AWS CLI symlink"
fi
pass "optional container identity mounts, in-tree AWS CLI runtime, and AWS environment allowlist are present"

# Production keeps the state directory 0700 and owned by fm-processor. Exercise
# the real sudo re-entry boundary on Linux so the caller cannot silently recreate
# a key it cannot inspect. This remains a temporary, offline identity fixture.
if [ "$(/usr/bin/uname -s)" = Linux ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  protected_root="$TMP_DIR/protected"
  mkdir -p "$protected_root"
  if (
    unset FM_AWS_IDENTITY_TEST_MODE FM_AWS_IDENTITY_NO_ROOT
    export FM_AWS_IDENTITY_ETC_DIR="$protected_root/etc"
    export FM_AWS_IDENTITY_STATE_DIR="$protected_root/state"
    export FM_AWS_IDENTITY_SYSTEMD_DIR="$protected_root/systemd"
    export FM_AWS_IDENTITY_SBIN_DIR="$protected_root/sbin"
    export FM_AWS_IDENTITY_BIN_DIR="$TMP_DIR/bin"
    export FM_AWS_IDENTITY_AWS_INSTALL_DIR="$protected_root/aws-cli"
    export FM_AWS_IDENTITY_CONFIG_FILE="$protected_root/etc/identity.env"
    export FM_AWS_IDENTITY_SERVICE_USER=nobody
    FM_AWS_IDENTITY_CALLER_USER="$(id -un)"
    export FM_AWS_IDENTITY_CALLER_USER
    export FM_AWS_IDENTITY_AWS_PATH="$TMP_DIR/bin/aws"
    export FM_AWS_IDENTITY_SIGNING_HELPER_PATH="$TMP_DIR/bin/aws_signing_helper"
    export FM_AWS_IDENTITY_SUDOERS_FILE="$protected_root/fm-processor-aws-identity.sudoers"
    export FM_AWS_IDENTITY_SKIP_DOWNLOAD=1
    export FM_AWS_IDENTITY_SKIP_SYSTEMD=1
    bash "$IDENTITY" install
  ) >"$TMP_DIR/protected.out" 2>"$TMP_DIR/protected.err"; then
    fail "protected-state install must stop at the offline CA boundary"
  else
    rc=$?
    [ "$rc" -eq 3 ] || fail "protected-state install returned $rc, expected 3 while waiting for CA"
  fi
  protected_mode="$(sudo stat -c '%a' "$protected_root/state")"
  [ "$protected_mode" = 700 ] || fail "protected identity state is not mode 0700 (mode=$protected_mode)"
  protected_key_digest="$(sudo openssl pkey -in "$protected_root/state/private-key.pem" -pubout -outform DER | openssl dgst -sha256)"
  protected_csr_digest="$(sudo openssl req -in "$protected_root/state/processor.csr.pem" -pubkey -noout | \
    openssl pkey -pubin -outform DER | openssl dgst -sha256)"
  [ "$protected_key_digest" = "$protected_csr_digest" ] || fail "protected-state CSR does not match its private key"
  sudo rm -rf "$protected_root"
  pass "production sudo boundary preserves protected state and creates a matching CSR"
else
  pass "production sudo boundary test skipped because passwordless Linux sudo is unavailable"
fi

echo "processor identity: all checks passed"
