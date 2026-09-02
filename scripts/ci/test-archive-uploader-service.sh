#!/usr/bin/env bash
# Offline contract tests for the independent archive uploader service. The
# installer is exercised against a temporary unit/env root; sudo and systemctl
# are stubs, so this never changes /etc, systemd, Docker, ROS, B2, or tower data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/scripts/install/install-archive-uploader-service.sh"
BOOT="$ROOT/scripts/service/archive-uploader-boot.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

grep -q 'BACKBLAZE_B2_FMREC_KEY_ID=' "$INSTALLER" || fail "uploader key id name drifted"
grep -q 'BACKBLAZE_B2_FMREC_APPLICATION_KEY=' "$INSTALLER" || fail "uploader application key name drifted"
grep -q 'BACKBLAZE_B2_PROCARCH_KEY_ID' "$ROOT/scripts/install/install-archive-service.sh" || fail "reader key name missing"
grep -q "EnvironmentFile=-\$ENVFILE" "$INSTALLER" || fail "uploader env file is not isolated"
if grep -q 'EnvironmentFile=-/etc/fm-archive.env' "$INSTALLER"; then
  fail "uploader installer inherited the reader env file"
fi
grep -q 'FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1' "$INSTALLER" || fail "uploader unit lacks existing-only guard"
grep -q 'archive-uploader-boot.sh' "$INSTALLER" || fail "uploader unit lacks boot wrapper"
grep -q 'archive_uploader' "$BOOT" || fail "uploader entrypoint missing"
for topic in /archive/storage/index /archive/storage/status /archive/upload/retry \
  /archive/retention/verify /archive/retention/delete; do
  grep -q -- "$topic" "$BOOT" || fail "uploader topic missing: $topic"
done
if grep -qE 'FM_ARCHIVE_UPLOADER_(INDEX|STATUS|RETRY|VERIFY|DELETE)_TOPIC|INDEX_TOPIC|STATUS_TOPIC|RETRY_TOPIC|VERIFY_TOPIC|DELETE_TOPIC' \
  "$BOOT" "$INSTALLER"; then
  fail "uploader allows a topic override outside the Desktop contract"
fi
for param in recordings_dir state_dir upload_enabled deletion_enabled dry_run min_retention_days \
  eligibility_window_minutes max_concurrent_uploads max_bandwidth_bytes_s; do
  grep -q -- "-p $param:" "$BOOT" || fail "uploader parameter missing: $param"
done
if grep -E -- '-p (AWS_|BACKBLAZE_|bucket|key|prefix)' "$BOOT"; then
  fail "uploader credentials or provider selectors entered node arguments"
fi
grep -q 'FM_ARCHIVE_UPLOADER_DELETE_ENABLED=false' "$INSTALLER" || fail "delete is not disabled by default"
grep -q 'FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS=30' "$INSTALLER" || fail "retention floor drifted"
grep -q 'FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES=15' "$INSTALLER" || fail "eligibility floor drifted"
grep -q 'FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS=1' "$INSTALLER" || fail "concurrency default drifted"
grep -q 'FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S=8388608' "$INSTALLER" || fail "bandwidth ceiling drifted"
grep -q 'fm_processor_env FM_PROCESSOR_RECORDINGS_DIR' "$INSTALLER" || fail "uploader ignores the processor recording root"
grep -q 'ARCHIVE_DATA_ROOT/staged/archive-uploader' "$BOOT" || fail "uploader state is not on persistent data storage"
grep -q -- 'recordings:/data/recordings' "$ROOT/compose.processor.yaml" || fail "processor container does not mount the authoritative recording root"
grep -q 'archive_preflight' "$BOOT" || fail "live provider preflight gate is absent"
# The live provider preflight above is the upload gate. The account storage cap
# was operator-typed console evidence carrying a 24-hour freshness window, so it
# expired on a clock rather than on anything changing and stopped uploads at the
# next restart; it must not come back through the installer.
if grep -q 'FM_ARCHIVE_STORAGE_CAP' "$INSTALLER"; then
  fail "storage-cap gate reintroduced"
fi
if grep -R -E -q 'delete_object|delete_objects|DeleteObject|DeleteObjects' "$BOOT" "$INSTALLER"; then
  fail "uploader wiring contains a remote-delete API"
fi
pass "uploader contract names, topics, policy, and no-delete boundary"

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/etc" "$TMP_DIR/systemd"
cat > "$TMP_DIR/etc/fm-processor.env" <<EOF
FM_PROCESSOR_RECORDINGS_DIR=$TMP_DIR/data/recordings
FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=$TMP_DIR/data/annotations/runs/attempts
EOF
cat >"$TMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Test the real privilege boundary without requiring root: a protected fixture
# is unreadable to the installer, while commands routed through this sudo stub
# receive the minimum owner-read bit they need.
case "${1:-}" in
  sed|grep)
    target="${!#}"
    [ -e "$target" ] && chmod u+r "$target"
    ;;
esac
exec "$@"
EOF
cat >"$TMP_DIR/bin/systemctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"$TMP_DIR/systemctl.log"
exit 0
EOF
cat >"$TMP_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -s ]; then echo Linux; else /usr/bin/uname "$@"; fi
EOF
chmod +x "$TMP_DIR/bin/sudo" "$TMP_DIR/bin/systemctl" "$TMP_DIR/bin/uname"
export PATH="$TMP_DIR/bin:$PATH"
export FM_PROCESSOR_RUNTIME=native
export FM_TRANSPORT=none
export FM_ARCHIVE_UPLOADER_SERVICE_TEST_MODE=1
export FM_ARCHIVE_UPLOADER_SERVICE_TEST_ROOT="$TMP_DIR"
TEST_UNIT="$TMP_DIR/systemd/fm-archive-uploader.service"
TEST_ENV="$TMP_DIR/etc/fm-archive-uploader.env"

[ -x "$INSTALLER" ] || fail "uploader installer is not executable"
bash "$INSTALLER" install >/dev/null
[ -f "$TEST_UNIT" ] || fail "first install did not write unit"
[ -f "$TEST_ENV" ] || fail "first install did not write env"
grep -q "FM_ARCHIVE_UPLOADER_RECORDINGS_DIR=$TMP_DIR/data/recordings" "$TEST_ENV" || \
  fail "uploader did not inherit the processor recording root"
grep -q "FM_ARCHIVE_UPLOADER_STATE_DIR=$TMP_DIR/data/staged/archive-uploader" "$TEST_ENV" || \
  fail "uploader state does not share the processor persistent root"
env_mode="$(stat -c '%a' "$TEST_ENV" 2>/dev/null || stat -f '%Lp' "$TEST_ENV")"
[ "$env_mode" = 600 ] || fail "uploader env is not mode 600"
cp "$TEST_UNIT" "$TMP_DIR/unit.snapshot"
cp "$TEST_ENV" "$TMP_DIR/env.snapshot"
bash "$INSTALLER" install >/dev/null
cmp -s "$TEST_UNIT" "$TMP_DIR/unit.snapshot" || fail "repeat install changed unit"
cmp -s "$TEST_ENV" "$TMP_DIR/env.snapshot" || fail "repeat install changed env"
pass "first and repeat installs converge without clobbering env"

chmod 000 "$TEST_ENV"
bash "$INSTALLER" install >/dev/null
cmp -s "$TEST_ENV" "$TMP_DIR/env.snapshot" || fail "protected repeat install changed env"
env_mode="$(stat -c '%a' "$TEST_ENV" 2>/dev/null || stat -f '%Lp' "$TEST_ENV")"
[ "$env_mode" = 600 ] || fail "protected repeat install did not restore mode 600"
pass "repeat install reads protected policy fields through sudo"

# The container runtime uses the same role-owned processor project but an
# existing-only entry. The generated unit carries the guard explicitly.
FM_PROCESSOR_RUNTIME=container bash "$INSTALLER" install >/dev/null
grep -q 'container-exec.sh scripts/service/archive-uploader-boot.sh' \
  "$TEST_UNIT" || fail "container unit lacks compose entry"
grep -q 'Environment=FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1' \
  "$TEST_UNIT" || fail "container unit lacks existing-only env"
grep -q 'container-exec.sh stop archive_uploader' \
  "$TEST_UNIT" || fail "container unit lacks scoped stop"
pass "container unit uses existing-only exec and scoped process stop"

# The ExecStop ends the wrapper inside the container, so the unit's own compose
# exec is left to be SIGTERMed and exits 143. Without SuccessExitStatus, systemd
# logs every operator stop as a failure and a real one no longer stands out.
grep -q '^SuccessExitStatus=143$' \
  "$TEST_UNIT" || fail "container unit reports a deliberate stop as a failure"
pass "container unit treats a deliberate stop as a clean exit"

before_unit="$(hash_file "$TEST_UNIT")"
before_env="$(hash_file "$TEST_ENV")"
bash "$INSTALLER" --dry-run >/dev/null
[ "$before_unit" = "$(hash_file "$TEST_UNIT")" ] || fail "dry-run changed unit"
[ "$before_env" = "$(hash_file "$TEST_ENV")" ] || fail "dry-run changed env"
pass "installer dry-run is read-only"

output="$(FM_ARCHIVE_UPLOADER_ENABLED=false bash "$BOOT")"
grep -q disabled <<<"$output" || fail "default-off boot did not exit cleanly"

# Dry-run is a local discovery/reporting mode. It must get past the provider
# credential gate even on a fresh tower; the later ROS/package check may still
# refuse this host because no assembled workspace exists in the offline test.
dry_output="$(env -u BACKBLAZE_B2_FMREC_KEY_ID \
  -u BACKBLAZE_B2_FMREC_APPLICATION_KEY \
  FM_ARCHIVE_UPLOADER_ENABLED=true \
  FM_ARCHIVE_UPLOADER_DRY_RUN=true \
  FM_ARCHIVE_UPLOADER_DELETE_ENABLED=false \
  FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS=30 \
  FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES=15 \
  FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS=1 \
  FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S=8388608 \
  bash "$BOOT" 2>&1 || true)"
if grep -q 'write-scoped B2 credentials are absent' <<<"$dry_output"; then
  fail "dry-run still requires provider credentials"
fi
pass "dry-run bypasses provider credentials before the assembled ROS workspace check"

for invalid in \
  'FM_ARCHIVE_UPLOADER_ENABLED=invalid' \
  'FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS=29' \
  'FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES=14' \
  'FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS=0' \
  'FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS=2' \
  'FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S=0' \
  'FM_ARCHIVE_UPLOADER_DRY_RUN=invalid'; do
  if env FM_ARCHIVE_UPLOADER_ENABLED=true $invalid bash "$BOOT" >/dev/null 2>&1; then
    fail "invalid uploader setting accepted: $invalid"
  fi
done
if FM_ARCHIVE_UPLOADER_ENABLED=true bash "$BOOT" >/dev/null 2>&1; then
  fail "enabled uploader without credentials was accepted"
fi
pass "default-off and policy/failure exits are fail-closed"

echo "test-archive-uploader-service: passed"
