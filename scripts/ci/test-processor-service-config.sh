#!/usr/bin/env bash
# Offline behavioral contract for the processor service installer. The real
# installer runs against a temporary root; only sudo, systemctl, and install
# are stubbed, so first/repeat/conflict/failure ordering is exercised without
# touching /etc or a live service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/scripts/install/install-processor-service.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/etc" "$TMP_DIR/systemd" "$TMP_DIR/identity" \
  "$TMP_DIR/uv-python"
export FM_PROCESSOR_UV_PYTHON_ROOT="$TMP_DIR/uv-python"
REAL_INSTALL="$(command -v install)"

cat >"$TMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF
cat >"$TMP_DIR/bin/install" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o|-g) shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
exec "$REAL_INSTALL" "\${args[@]}"
EOF
cat >"$TMP_DIR/bin/systemctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"$TMP_DIR/systemctl.log"
exit 0
EOF
cat >"$TMP_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -s ]; then echo Linux; else /usr/bin/uname "$@"; fi
EOF
chmod +x "$TMP_DIR/bin/sudo" "$TMP_DIR/bin/install" "$TMP_DIR/bin/systemctl" "$TMP_DIR/bin/uname"

# Public identity selectors are the supported source for the profile and
# reviewed bucket. No private certificate or credential is needed by this test.
cat >"$TMP_DIR/identity/identity.env" <<'EOF'
FM_AWS_IDENTITY_REGION=us-east-2
FM_AWS_IDENTITY_PROFILE=reviewed-profile
FM_AWS_IDENTITY_BUCKET=reviewed-bucket
EOF
cat >"$TMP_DIR/identity/install-identity.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = check ] || exit 2
printf '%s\\n' check >>"$TMP_DIR/identity-check.log"
EOF
chmod +x "$TMP_DIR/identity/install-identity.sh"

export PATH="$TMP_DIR/bin:$PATH"
export FM_PROCESSOR_SERVICE_TEST_MODE=1
export FM_PROCESSOR_SERVICE_TEST_ROOT="$TMP_DIR"
export FM_PROCESSOR_RUNTIME=native
export FM_AWS_INFERENCE_SERVICE_MODE=1
export FM_AWS_INFERENCE_READINESS_DIR="$TMP_DIR/readiness"
export FM_AWS_SERVICE_TIMEOUT_SECONDS=7200
# Exercise the managed default path, which is relative to the workspace and
# therefore works for both native and Humble-container processor launches.
export FM_PROCESSOR_AWS_INFERENCE_SCRIPT=src/fm_data/fm_data_annotate/scripts/run_qwen_aws_service.sh

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
assert_same() {
  cmp -s "$1" "$2" || fail "$3"
}
replace_line() { # file prefix replacement
  local file="$1" prefix="$2" replacement="$3" tmp
  tmp="${file}.tmp.$$"
  awk -v prefix="$prefix" -v replacement="$replacement" \
    'index($0, prefix) == 1 { print replacement; next } { print }' "$file" >"$tmp"
  mv "$tmp" "$file"
}
remove_line() { # file exact line
  local file="$1" line="$2" tmp
  tmp="${file}.tmp.$$"
  awk -v line="$line" '$0 != line { print }' "$file" >"$tmp"
  mv "$tmp" "$file"
}
systemctl_count() {
  [ -f "$TMP_DIR/systemctl.log" ] || { printf '0'; return; }
  wc -l <"$TMP_DIR/systemctl.log"
}

CONTAINER_ROOT="$TMP_DIR/container-case"
mkdir -p "$CONTAINER_ROOT/etc" "$CONTAINER_ROOT/systemd" "$CONTAINER_ROOT/identity" "$CONTAINER_ROOT/identity-state"
cat >"$CONTAINER_ROOT/identity/identity.env" <<'EOF'
FM_AWS_IDENTITY_REGION=us-east-2
FM_AWS_IDENTITY_PROFILE=reviewed-profile
FM_AWS_IDENTITY_BUCKET=reviewed-bucket
EOF
printf '%s\n' 'profile-placeholder' >"$CONTAINER_ROOT/identity/aws-config"
cat >"$CONTAINER_ROOT/identity/install-identity.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = check ] || exit 2
EOF
chmod +x "$CONTAINER_ROOT/identity/install-identity.sh"
systemctl_before="$(systemctl_count)"
if FM_PROCESSOR_SERVICE_TEST_ROOT="$CONTAINER_ROOT" \
   FM_PROCESSOR_RUNTIME=container \
   FM_AWS_IDENTITY_ETC_DIR="$CONTAINER_ROOT/identity" \
   FM_AWS_IDENTITY_STATE_DIR="$CONTAINER_ROOT/identity-state" \
   FM_AWS_IDENTITY_AWS_INSTALL_DIR="$CONTAINER_ROOT/missing-aws-cli" \
   bash "$INSTALLER" install >"$TMP_DIR/missing-tree.out" 2>"$TMP_DIR/missing-tree.err"; then
  fail "container service accepted an unavailable pinned AWS CLI tree"
fi
[ ! -e "$CONTAINER_ROOT/systemd/fm-processor.service" ] || fail "missing AWS tree created a unit"
[ ! -e "$CONTAINER_ROOT/etc/fm-processor.env" ] || fail "missing AWS tree created general env"
[ ! -e "$CONTAINER_ROOT/etc/fm-processor-aws.env" ] || fail "missing AWS tree created managed env"
[ ! -e "$CONTAINER_ROOT/etc/fm-bridge.env" ] || fail "missing AWS tree created bridge env"
[ "$(systemctl_count)" = "$systemctl_before" ] || \
  fail "missing AWS tree invoked systemd"
grep -q 'pinned AWS CLI install tree is missing' "$TMP_DIR/missing-tree.err" || {
  cat "$TMP_DIR/missing-tree.err" >&2
  fail "missing AWS tree error did not identify the unavailable runtime"
}
pass "container service refuses a missing AWS CLI tree before any writes"

if bash "$INSTALLER" install >"$TMP_DIR/no-identity.out" 2>"$TMP_DIR/no-identity.err"; then
  fail "Ohio service was accepted without an installed identity profile"
fi
[ ! -e "$TMP_DIR/systemd/fm-processor.service" ] || fail "missing identity created a unit"
[ ! -e "$TMP_DIR/etc/fm-processor-aws.env" ] || fail "missing identity created managed Ohio env"
[ ! -e "$TMP_DIR/etc/fm-bridge.env" ] || fail "missing identity created bridge env"
[ ! -e "$TMP_DIR/systemctl.log" ] || fail "missing identity invoked systemd"
grep -q 'requires an installed processor identity profile' "$TMP_DIR/no-identity.err" || \
  fail "missing identity error did not identify the required profile"
pass "Ohio service refuses before writes when the identity profile is absent"

printf '%s\n' 'profile-placeholder' >"$TMP_DIR/identity/aws-config"
bash "$INSTALLER" install >"$TMP_DIR/first.out" 2>"$TMP_DIR/first.err" || {
  cat "$TMP_DIR/first.err" >&2
  fail "first install failed"
}
[ -f "$TMP_DIR/systemd/fm-processor.service" ] || fail "first install did not write the unit"
[ -f "$TMP_DIR/etc/fm-processor.env" ] || fail "first install did not write the general env"
[ -f "$TMP_DIR/etc/fm-processor-aws.env" ] || fail "first install did not write managed Ohio env"
[ -f "$TMP_DIR/etc/fm-bridge.env" ] || fail "first install did not write bridge env"
grep -Fxq 'FM_AWS_INFERENCE_REGION=us-east-2' "$TMP_DIR/etc/fm-processor-aws.env" || fail "Ohio region was not persisted"
grep -Fxq 'FM_AWS_PROFILE=reviewed-profile' "$TMP_DIR/etc/fm-processor-aws.env" || fail "identity profile was not persisted"
grep -Fxq 'FM_AWS_INFERENCE_BUCKET=reviewed-bucket' "$TMP_DIR/etc/fm-processor-aws.env" || fail "identity bucket was not persisted"
grep -Fxq 'FM_PROCESSOR_AWS_INFERENCE_SCRIPT=src/fm_data/fm_data_annotate/scripts/run_qwen_aws_service.sh' \
  "$TMP_DIR/etc/fm-processor-aws.env" || fail "relative AWS adapter path was not persisted"
mkdir -p "$TMP_DIR/snapshot"
for file in systemd/fm-processor.service etc/fm-processor.env etc/fm-processor-aws.env etc/fm-bridge.env; do
  cp "$TMP_DIR/$file" "$TMP_DIR/snapshot/$(basename "$file")"
done
pass "first install writes unit, bridge env, and explicit Ohio selectors"

bash "$INSTALLER" install >"$TMP_DIR/repeat.out" 2>"$TMP_DIR/repeat.err" || {
  cat "$TMP_DIR/repeat.err" >&2
  fail "repeat install failed"
}
for file in systemd/fm-processor.service etc/fm-processor.env etc/fm-processor-aws.env etc/fm-bridge.env; do
  assert_same "$TMP_DIR/$file" "$TMP_DIR/snapshot/$(basename "$file")" "repeat changed $file"
done
# The unit is allowed to reload/restart on an explicit reinstall; the managed
# config and all content remain byte-for-byte convergent.
pass "repeat install converges without changing managed files"

aws_before="$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")"
unit_before="$(hash_file "$TMP_DIR/systemd/fm-processor.service")"
env_before="$(hash_file "$TMP_DIR/etc/fm-processor.env")"
systemctl_before="$(wc -l <"$TMP_DIR/systemctl.log")"
replace_line "$TMP_DIR/etc/fm-processor-aws.env" 'FM_AWS_INFERENCE_BUCKET=' 'FM_AWS_INFERENCE_BUCKET=conflicting-bucket'
aws_conflict_before="$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")"
if bash "$INSTALLER" install >"$TMP_DIR/managed-conflict.out" 2>"$TMP_DIR/managed-conflict.err"; then
  fail "managed Ohio conflict was accepted"
fi
[ "$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")" = "$aws_conflict_before" ] || fail "managed conflict changed its own fixture"
[ "$(hash_file "$TMP_DIR/systemd/fm-processor.service")" = "$unit_before" ] || fail "managed conflict changed the unit"
[ "$(hash_file "$TMP_DIR/etc/fm-processor.env")" = "$env_before" ] || fail "managed conflict changed the general env"
[ "$(wc -l <"$TMP_DIR/systemctl.log")" = "$systemctl_before" ] || fail "managed conflict restarted systemd"
[ "$aws_before" != "$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")" ] || fail "managed conflict fixture was not applied"
pass "managed Ohio conflict fails before any unit/env/systemd mutation"

# Restore the known-good managed file, then exercise a legacy active key in the
# general env. Append-only installers used to silently retain this conflict.
cat >"$TMP_DIR/etc/fm-processor-aws.env" <<EOF
# Managed by install-processor-service.sh; Ohio inference selectors only.
# Readiness receipts are supplied by the read-only AWS preflight; configuration alone is not Ready.
FM_AWS_INFERENCE_SERVICE_MODE=1
FM_AWS_INFERENCE_REGION=us-east-2
FM_AWS_PROFILE=reviewed-profile
FM_AWS_INFERENCE_BUCKET=reviewed-bucket
FM_AWS_INFERENCE_READINESS_DIR=$TMP_DIR/readiness
FM_AWS_SERVICE_TIMEOUT_SECONDS=7200
FM_PROCESSOR_AWS_INFERENCE_SCRIPT=src/fm_data/fm_data_annotate/scripts/run_qwen_aws_service.sh
EOF
printf '%s\n' 'FM_AWS_PROFILE=legacy-profile' >>"$TMP_DIR/etc/fm-processor.env"
unit_before="$(hash_file "$TMP_DIR/systemd/fm-processor.service")"
env_before="$(hash_file "$TMP_DIR/etc/fm-processor.env")"
systemctl_before="$(wc -l <"$TMP_DIR/systemctl.log")"
if bash "$INSTALLER" install >"$TMP_DIR/legacy-conflict.out" 2>"$TMP_DIR/legacy-conflict.err"; then
  fail "legacy active key conflict was accepted"
fi
[ "$(hash_file "$TMP_DIR/systemd/fm-processor.service")" = "$unit_before" ] || fail "legacy conflict changed the unit"
[ "$(hash_file "$TMP_DIR/etc/fm-processor.env")" = "$env_before" ] || fail "legacy conflict changed the general env"
[ "$(wc -l <"$TMP_DIR/systemctl.log")" = "$systemctl_before" ] || fail "legacy conflict restarted systemd"
pass "legacy active key conflict fails before any install writes"

# Remove the legacy conflict and exercise malformed input. Validation happens
# before the unit or managed env transaction, so no partial route can persist.
remove_line "$TMP_DIR/etc/fm-processor.env" 'FM_AWS_PROFILE=legacy-profile'
unit_before="$(hash_file "$TMP_DIR/systemd/fm-processor.service")"
aws_before="$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")"
env_before="$(hash_file "$TMP_DIR/etc/fm-processor.env")"
systemctl_before="$(wc -l <"$TMP_DIR/systemctl.log")"
if FM_AWS_INFERENCE_BUCKET='bad bucket' bash "$INSTALLER" install >"$TMP_DIR/malformed.out" 2>"$TMP_DIR/malformed.err"; then
  fail "malformed bucket value was accepted"
fi
[ "$(hash_file "$TMP_DIR/systemd/fm-processor.service")" = "$unit_before" ] || fail "malformed input changed the unit"
[ "$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")" = "$aws_before" ] || fail "malformed input changed managed env"
[ "$(hash_file "$TMP_DIR/etc/fm-processor.env")" = "$env_before" ] || fail "malformed input changed general env"
[ "$(wc -l <"$TMP_DIR/systemctl.log")" = "$systemctl_before" ] || fail "malformed input restarted systemd"
pass "malformed Ohio input fails before any install writes"

for timeout in 0 01 7201 99999; do
  unit_before="$(hash_file "$TMP_DIR/systemd/fm-processor.service")"
  aws_before="$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")"
  env_before="$(hash_file "$TMP_DIR/etc/fm-processor.env")"
  systemctl_before="$(systemctl_count)"
  if FM_AWS_SERVICE_TIMEOUT_SECONDS="$timeout" bash "$INSTALLER" install >"$TMP_DIR/timeout.out" 2>"$TMP_DIR/timeout.err"; then
    fail "out-of-range timeout was accepted: $timeout"
  fi
  [ "$(hash_file "$TMP_DIR/systemd/fm-processor.service")" = "$unit_before" ] || fail "timeout $timeout changed the unit"
  [ "$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")" = "$aws_before" ] || fail "timeout $timeout changed managed env"
  [ "$(hash_file "$TMP_DIR/etc/fm-processor.env")" = "$env_before" ] || fail "timeout $timeout changed general env"
  [ "$(systemctl_count)" = "$systemctl_before" ] || fail "timeout $timeout restarted systemd"
done
pass "timeouts outside 1 through 7200 fail before any install writes"

for override in FM_AWS_PROFILE=other-profile FM_AWS_INFERENCE_BUCKET=other-bucket FM_AWS_INFERENCE_REGION=us-east-1; do
  if env "$override" bash "$INSTALLER" install >"$TMP_DIR/identity-conflict.out" 2>"$TMP_DIR/identity-conflict.err"; then
    fail "conflicting workload identity selector was accepted: $override"
  fi
  [ "$(hash_file "$TMP_DIR/systemd/fm-processor.service")" = "$unit_before" ] || fail "identity conflict changed unit"
  [ "$(hash_file "$TMP_DIR/etc/fm-processor-aws.env")" = "$aws_before" ] || fail "identity conflict changed managed env"
  [ "$(wc -l <"$TMP_DIR/systemctl.log")" = "$systemctl_before" ] || fail "identity conflict restarted systemd"
done
pass "service selectors must bind the checked workload identity"

# --- an existing env file converges onto the current tree ----------------------
#
# The template is written only when the file is absent, so a rig provisioned
# before the data root moved would keep naming fm-data-runs — a tree nothing
# mounts any more, which sends every annotation it writes to the container's
# writable layer. Found on fm-ws-01, whose env file carried exactly these paths.

cat > "$TMP_DIR/etc/fm-processor.env" <<'OLDENV'
FM_PROCESSOR_RECORDINGS_DIR=/data/recordings
FM_PROCESSOR_LEROBOT_IMPORTS_DIR=/data/lerobot-staged
FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=/data/fm-data-runs/annotation-attempts
FM_PROCESSOR_ANNOTATION_LEARNING_DIR=/data/fm-data-runs/annotation-learning
FM_PROCESSOR_ANNOTATION_LEARNING_SNAPSHOTS_DIR=/data/fm-data-runs/annotation-learning-snapshots
FM_PROCESSOR_RELEASE_ROOT=/data/dataset-releases
FM_PROCESSOR_OPERATOR_CHOICE=/mnt/big/somewhere-else
# a comment naming /data/fm-data-runs/annotation-attempts stays prose
OLDENV

bash "$INSTALLER" install >/dev/null 2>&1 || true
moved="$TMP_DIR/etc/fm-processor.env"

grep -q '^FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=/data/annotations/runs/attempts$' "$moved" \
  || fail "the attempts directory did not move onto the current tree"
grep -q '^FM_PROCESSOR_ANNOTATION_LEARNING_DIR=/data/annotations/runs/learning$' "$moved" \
  || fail "the learning directory did not move"
grep -q '^FM_PROCESSOR_ANNOTATION_LEARNING_SNAPSHOTS_DIR=/data/annotations/runs/learning-snapshots$' "$moved" \
  || fail "the longer snapshots name was eaten by the shorter learning rule"
grep -q '^FM_PROCESSOR_LEROBOT_IMPORTS_DIR=/data/staged/lerobot$' "$moved" \
  || fail "the lerobot import directory did not move"
grep -q '^FM_PROCESSOR_RELEASE_ROOT=/data/releases$' "$moved" \
  || fail "the release root did not move"
grep -q '^FM_PROCESSOR_OPERATOR_CHOICE=/mnt/big/somewhere-else$' "$moved" \
  || fail "a directory the operator chose was rewritten"
grep -q 'a comment naming /data/fm-data-runs/annotation-attempts stays prose' "$moved" \
  || fail "a comment was rewritten as though it were a value"
grep -q 'fm-data-runs' <(grep -v '^#' "$moved") \
  && fail "a value still names the retired tree"
pass "an env file written before the move converges onto the current tree"

settled="$(hash_file "$moved")"
bash "$INSTALLER" install >/dev/null 2>&1 || true
[ "$(hash_file "$moved")" = "$settled" ] || fail "a second install moved the paths again"
pass "the move is idempotent"

# The path cutover must also preserve receipts written before the env value
# moved. Copy into the canonical tree, verify the bytes, keep the recovery
# source, and make the operation safe to repeat.
migration_root="$TMP_DIR/migration-data"
legacy_attempt="$migration_root/fm-data-runs/annotation-attempts/episode-a/attempt-a/ATTEMPT.json"
current_attempt="$migration_root/annotations/runs/attempts/episode-a/attempt-a/ATTEMPT.json"
mkdir -p "$(dirname "$legacy_attempt")"
printf '%s\n' '{"attempt_id":"attempt-a","episode_id":"episode-a"}' >"$legacy_attempt"
replace_line "$moved" 'FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=' \
  "FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=$migration_root/fm-data-runs/annotation-attempts"

bash "$INSTALLER" install >/dev/null 2>&1 || fail "legacy attempt migration failed"
assert_same "$legacy_attempt" "$current_attempt" "legacy attempt bytes changed during migration"
[ -f "$legacy_attempt" ] || fail "legacy recovery receipt was removed"
grep -Fxq "FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=$migration_root/annotations/runs/attempts" "$moved" \
  || fail "the migrated attempt root was not persisted"
pass "legacy attempt receipts are copied and verified in the current root"

attempt_before="$(hash_file "$current_attempt")"
bash "$INSTALLER" install >/dev/null 2>&1 || fail "repeat attempt migration failed"
[ "$(hash_file "$current_attempt")" = "$attempt_before" ] \
  || fail "repeat attempt migration changed the receipt"
pass "attempt evidence migration is idempotent"

conflict_legacy="$migration_root/fm-data-runs/annotation-attempts/episode-b/attempt-b/ATTEMPT.json"
conflict_current="$migration_root/annotations/runs/attempts/episode-b/attempt-b/ATTEMPT.json"
mkdir -p "$(dirname "$conflict_legacy")" "$(dirname "$conflict_current")"
printf '%s\n' '{"state":"failed"}' >"$conflict_legacy"
printf '%s\n' '{"state":"generated"}' >"$conflict_current"
systemctl_before="$(systemctl_count)"
if bash "$INSTALLER" install >"$TMP_DIR/attempt-conflict.out" 2>"$TMP_DIR/attempt-conflict.err"; then
  fail "conflicting attempt receipts were accepted"
fi
grep -q 'legacy attempt conflicts' "$TMP_DIR/attempt-conflict.err" \
  || fail "attempt conflict did not name the problem"
[ "$(systemctl_count)" = "$systemctl_before" ] \
  || fail "attempt conflict restarted systemd"
pass "conflicting attempt identities stop before service restart"

echo "processor service config behavior: all checks passed"
