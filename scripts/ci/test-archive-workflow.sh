#!/usr/bin/env bash
# Argument, dry-run, and local-preflight checks for the person-run archive verb.
# No systemd, Docker, ROS, B2, or tower state is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERB="$ROOT/scripts/run/archive.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

grep -q '"archive"' "$ROOT/fm.json" || fail "fm.json does not declare archive"
for action in status preflight reconcile install; do
  output="$(FM_SELFTEST=1 "$VERB" "$action" --json --dry-run)"
  grep -q "archive $action resolved" <<<"$output" || fail "archive action did not resolve: $action"
done
pass "fm archive exposes all four actions and parses options"

dry_output="$("$VERB" reconcile --dry-run --json)"
grep -q '"action":"reconcile"' <<<"$dry_output" || fail "reconcile dry-run omitted action"
grep -q '"result":"planned"' <<<"$dry_output" || fail "reconcile dry-run was not planned"
grep -q 'fm-archive-uploader.service' <<<"$dry_output" || fail "reconcile dry-run omitted uploader"
pass "reconcile dry-run is read-only and machine-readable"

mkdir -p "$TMP_DIR/etc"
cat >"$TMP_DIR/etc/archive.env" <<'EOF'
FM_ARCHIVE_ENABLED=false
BACKBLAZE_B2_PROCARCH_KEY_ID=
EOF
cat >"$TMP_DIR/etc/uploader.env" <<'EOF'
FM_ARCHIVE_UPLOADER_ENABLED=false
FM_ARCHIVE_UPLOADER_DELETE_ENABLED=false
FM_ARCHIVE_UPLOADER_MIN_RETENTION_DAYS=30
FM_ARCHIVE_UPLOADER_ELIGIBILITY_WINDOW_MINUTES=15
FM_ARCHIVE_UPLOADER_MAX_CONCURRENT_UPLOADS=1
FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S=8388608
BACKBLAZE_B2_FMREC_KEY_ID=
EOF
chmod 600 "$TMP_DIR/etc/archive.env" "$TMP_DIR/etc/uploader.env"
preflight_output="$(FM_ARCHIVE_ENVFILE="$TMP_DIR/etc/archive.env" \
  FM_ARCHIVE_UPLOADER_ENVFILE="$TMP_DIR/etc/uploader.env" \
  "$VERB" preflight --json)"
grep -q '"failures":0' <<<"$preflight_output" || {
  echo "$preflight_output" >&2
  fail "default-off archive preflight failed"
}
pass "default-off local preflight passes without credentials"

printf '%s\n' 'FM_ARCHIVE_UPLOADER_MAX_BANDWIDTH_BYTES_S=not-json' >>"$TMP_DIR/etc/uploader.env"
if FM_ARCHIVE_ENVFILE="$TMP_DIR/etc/archive.env" \
  FM_ARCHIVE_UPLOADER_ENVFILE="$TMP_DIR/etc/uploader.env" \
  "$VERB" status --json >/dev/null 2>&1; then
  fail "status accepted an invalid bandwidth value"
fi
pass "status refuses invalid numeric policy instead of emitting invalid JSON"

printf '%s\n' 'FM_ARCHIVE_ENABLED=true' >>"$TMP_DIR/etc/archive.env"
printf '%s\n' 'FM_ARCHIVE_UPLOADER_ENABLED=true' 'FM_ARCHIVE_UPLOADER_DELETE_ENABLED=false' >>"$TMP_DIR/etc/uploader.env"
if FM_ARCHIVE_ENVFILE="$TMP_DIR/etc/archive.env" \
  FM_ARCHIVE_UPLOADER_ENVFILE="$TMP_DIR/etc/uploader.env" \
  "$VERB" preflight --json >/dev/null 2>&1; then
  fail "preflight accepted enabled services without both application keys"
fi
pass "preflight rejects incomplete enabled credentials"

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/systemd"
cat >"$TMP_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -s ]; then echo Linux; else /usr/bin/uname "$@"; fi
EOF
cat >"$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$TMP_DIR/bin/uname" "$TMP_DIR/bin/systemctl"
dry_install="$(PATH="$TMP_DIR/bin:$PATH" FM_PROCESSOR_RUNTIME=native \
  FM_ARCHIVE_SERVICE_TEST_MODE=1 FM_ARCHIVE_SERVICE_TEST_ROOT="$TMP_DIR" \
  FM_ARCHIVE_UPLOADER_SERVICE_TEST_MODE=1 FM_ARCHIVE_UPLOADER_SERVICE_TEST_ROOT="$TMP_DIR" \
  "$VERB" install --dry-run --json 2>/dev/null)"
grep -q '"action":"install"' <<<"$dry_install" || fail "install dry-run omitted action"
grep -q '"result":"planned"' <<<"$dry_install" || fail "install dry-run was not planned"
[ ! -e "$TMP_DIR/systemd/fm-archive.service" ] || fail "install dry-run wrote archive unit"
[ ! -e "$TMP_DIR/systemd/fm-archive-uploader.service" ] || fail "install dry-run wrote uploader unit"
pass "install dry-run is read-only and machine-readable"

if "$VERB" unsupported >/dev/null 2>&1; then
  fail "unsupported archive action was accepted"
fi
pass "unsupported archive action returns a usage failure"

echo "test-archive-workflow: passed"
