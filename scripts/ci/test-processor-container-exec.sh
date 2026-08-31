#!/usr/bin/env bash
# Offline behavior test for the processor container entry. A temporary nested
# data package Git repo and fake docker prove the host-side source identity route;
# no Docker daemon, ROS image, network, credentials, or host checkout is used.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

WORKSPACE="$TMP_DIR/workspace"
mkdir -p "$WORKSPACE/scripts/internal" "$WORKSPACE/scripts/service" "$WORKSPACE/src/fm_data" "$TMP_DIR/bin"
cp "$ROOT/scripts/service/container-exec.sh" "$WORKSPACE/scripts/service/"
cp "$ROOT/scripts/internal/lib-processor.sh" "$WORKSPACE/scripts/internal/"
cp "$ROOT/scripts/internal/lib-compose.sh" "$WORKSPACE/scripts/internal/"
for wrapper in archive-boot.sh archive-uploader-boot.sh; do
  : >"$WORKSPACE/scripts/service/$wrapper"
  chmod +x "$WORKSPACE/scripts/service/$wrapper"
done

git -C "$WORKSPACE/src/fm_data" init -q
git -C "$WORKSPACE/src/fm_data" config user.email ci@example.invalid
git -C "$WORKSPACE/src/fm_data" config user.name 'CI Fixture'
printf '%s\n' 'source fixture' >"$WORKSPACE/src/fm_data/README.md"
git -C "$WORKSPACE/src/fm_data" add README.md
git -C "$WORKSPACE/src/fm_data" -c commit.gpgsign=false commit -q -m 'chore: source fixture'
COMMIT="$(git -C "$WORKSPACE/src/fm_data" rev-parse HEAD)"

cat >"$TMP_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'argv=%s\n' "$*" >>"${FM_TEST_DOCKER_LOG:?}"
printf 'commit=%s\n' "${FM_PROCESSOR_ANNOTATE_GIT_COMMIT:-<unset>}" >>"${FM_TEST_DOCKER_LOG:?}"
if [[ "$*" == *" ps --status running --services"* ]] && [ "${FM_TEST_DOCKER_RUNNING:-0}" = 1 ]; then
  printf 'fm\n'
fi
EOF
chmod +x "$TMP_DIR/bin/docker"

export PATH="$TMP_DIR/bin:$PATH"
export FM_TEST_DOCKER_LOG="$TMP_DIR/docker.log"
export FM_AWS_IDENTITY_ETC_DIR="$TMP_DIR/no-identity"
export FM_IMAGE=test-image
export FM_COMPOSE_PROJECT=test-processor

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
clear_log() { : >"$FM_TEST_DOCKER_LOG"; }
run_entry() {
  clear_log
  env -u FM_PROCESSOR_ANNOTATE_GIT_COMMIT \
    bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/processor-boot.sh \
    >"$TMP_DIR/entry.out" 2>"$TMP_DIR/entry.err"
}

run_entry || { cat "$TMP_DIR/entry.err" >&2; fail "valid host source launch failed"; }
grep -Fxq "commit=$COMMIT" "$FM_TEST_DOCKER_LOG" || fail "valid host source commit was not forwarded"
grep -q 'FM_PROCESSOR_ANNOTATE_GIT_COMMIT' "$FM_TEST_DOCKER_LOG" || fail "compose exec did not receive the source identity variable"
pass "clean host data package HEAD is forwarded before container entry"

clear_log
if FM_PROCESSOR_ANNOTATE_GIT_COMMIT="$(printf 'a%.0s' {1..40})" \
    bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/processor-boot.sh \
    >"$TMP_DIR/mismatch.out" 2>"$TMP_DIR/mismatch.err"; then
  fail "mismatched explicit source commit was accepted"
fi
[ ! -s "$FM_TEST_DOCKER_LOG" ] || fail "mismatched source commit reached Docker"
grep -q 'does not match' "$TMP_DIR/mismatch.err" || fail "mismatch error did not explain the expected source"
pass "mismatched explicit source commit is refused before Docker"

clear_log
if FM_PROCESSOR_ANNOTATE_GIT_COMMIT=0000000000000000000000000000000000000000 \
    bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/processor-boot.sh \
    >"$TMP_DIR/sentinel.out" 2>"$TMP_DIR/sentinel.err"; then
  fail "all-zero source commit sentinel was accepted"
fi
[ ! -s "$FM_TEST_DOCKER_LOG" ] || fail "all-zero source sentinel reached Docker"
grep -q 'full 40-character' "$TMP_DIR/sentinel.err" || fail "sentinel error did not require a real commit"
pass "all-zero source commit sentinel is refused"

# Tracked edits invalidate HEAD; untracked runtime outputs do not. The offline
# lane remains launchable without an annotation identity, while cloud mode fails
# closed before compose starts.
printf '%s\n' 'tracked edit' >>"$WORKSPACE/src/fm_data/README.md"
clear_log
if FM_AWS_INFERENCE_SERVICE_MODE=1 \
    bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/processor-boot.sh \
    >"$TMP_DIR/dirty-cloud.out" 2>"$TMP_DIR/dirty-cloud.err"; then
  fail "tracked-dirty cloud source was accepted"
fi
[ ! -s "$FM_TEST_DOCKER_LOG" ] || fail "tracked-dirty cloud source reached Docker"
grep -q 'tracked changes' "$TMP_DIR/dirty-cloud.err" || fail "dirty source error did not identify tracked changes"
pass "tracked-dirty cloud source is refused before Docker"

run_entry || { cat "$TMP_DIR/entry.err" >&2; fail "offline launch from tracked source failed"; }
grep -Fxq 'commit=<unset>' "$FM_TEST_DOCKER_LOG" || fail "offline dirty launch stamped an untrusted HEAD"
pass "offline launch tolerates tracked source edits without stamping HEAD"

# An untracked runtime output is intentionally ignored by the cleanliness gate.
git -C "$WORKSPACE/src/fm_data" restore README.md
printf '%s\n' 'runtime output' >"$WORKSPACE/src/fm_data/runtime-output.json"
FM_AWS_INFERENCE_SERVICE_MODE=1 run_entry || { cat "$TMP_DIR/entry.err" >&2; fail "untracked output blocked cloud launch"; }
grep -Fxq "commit=$COMMIT" "$FM_TEST_DOCKER_LOG" || fail "clean source with untracked output lost its commit"
pass "untracked runtime output does not invalidate the source identity"

# No checkout is an offline/local condition, but cloud mode must not run without
# a source identity; this reproduces the container's ownership-blocked Git path.
mv "$WORKSPACE/src/fm_data" "$WORKSPACE/src/fm_data.missing"
clear_log
if FM_AWS_INFERENCE_SERVICE_MODE=1 \
    bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/processor-boot.sh \
    >"$TMP_DIR/missing-cloud.out" 2>"$TMP_DIR/missing-cloud.err"; then
  fail "missing source cloud launch was accepted"
fi
[ ! -s "$FM_TEST_DOCKER_LOG" ] || fail "missing source cloud launch reached Docker"
grep -q 'source commit' "$TMP_DIR/missing-cloud.err" || fail "missing source error did not identify source identity"
pass "missing data package source refuses cloud launch"

run_entry || { cat "$TMP_DIR/entry.err" >&2; fail "offline launch without source failed"; }
grep -Fxq 'commit=<unset>' "$FM_TEST_DOCKER_LOG" || fail "offline missing source stamped a commit"
pass "offline launch without data package remains supported"

# Only archive role wrappers receive the two canonical service credential pairs.
# Generic AWS access keys stay out of the allowlist, and the processor wrapper
# itself never receives a static B2 key that could shadow Roles Anywhere.
clear_log
BACKBLAZE_B2_PROCARCH_KEY_ID=reader-id \
BACKBLAZE_B2_PROCARCH_APPLICATION_KEY=reader-secret \
AWS_ACCESS_KEY_ID=generic-id AWS_SECRET_ACCESS_KEY=generic-secret \
  run_entry || { cat "$TMP_DIR/entry.err" >&2; fail "credential allowlist launch failed"; }
if grep -q 'BACKBLAZE_B2_' "$FM_TEST_DOCKER_LOG"; then
  fail "static B2 credential crossed into the processor wrapper"
fi
if grep -q 'AWS_ACCESS_KEY_ID' "$FM_TEST_DOCKER_LOG"; then
  fail "generic AWS access key crossed the container boundary"
fi
if grep -q 'AWS_SECRET_ACCESS_KEY' "$FM_TEST_DOCKER_LOG"; then
  fail "generic AWS secret crossed the container boundary"
fi
pass "processor wrapper excludes static B2 and generic AWS credentials"

clear_log
BACKBLAZE_B2_FMREC_KEY_ID=uploader-id \
BACKBLAZE_B2_FMREC_APPLICATION_KEY=uploader-secret \
BACKBLAZE_B2_PROCARCH_KEY_ID=reader-id \
BACKBLAZE_B2_PROCARCH_APPLICATION_KEY=reader-secret \
  FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1 FM_TEST_DOCKER_RUNNING=1 \
  bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/archive-uploader-boot.sh \
  >"$TMP_DIR/uploader-creds.out" 2>"$TMP_DIR/uploader-creds.err" || {
    cat "$TMP_DIR/uploader-creds.err" >&2
    fail "uploader credential allowlist launch failed"
  }
grep -q 'BACKBLAZE_B2_FMREC_KEY_ID' "$FM_TEST_DOCKER_LOG" || fail "canonical uploader key was not forwarded"
grep -q 'BACKBLAZE_B2_FMREC_APPLICATION_KEY' "$FM_TEST_DOCKER_LOG" || fail "canonical uploader secret was not forwarded"
if grep -q 'BACKBLAZE_B2_PROCARCH_' "$FM_TEST_DOCKER_LOG"; then
  fail "reader credential crossed into uploader wrapper"
fi
pass "archive wrapper receives only its canonical service credential pair"

clear_log
BACKBLAZE_B2_PROCARCH_KEY_ID=reader-id \
BACKBLAZE_B2_PROCARCH_APPLICATION_KEY=reader-secret \
BACKBLAZE_B2_FMREC_KEY_ID=uploader-id \
BACKBLAZE_B2_FMREC_APPLICATION_KEY=uploader-secret \
  FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1 FM_TEST_DOCKER_RUNNING=1 \
  bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/archive-boot.sh \
  >"$TMP_DIR/reader-creds.out" 2>"$TMP_DIR/reader-creds.err" || {
    cat "$TMP_DIR/reader-creds.err" >&2
    fail "reader credential allowlist launch failed"
  }
grep -q 'BACKBLAZE_B2_PROCARCH_KEY_ID' "$FM_TEST_DOCKER_LOG" || fail "canonical reader key was not forwarded"
grep -q 'BACKBLAZE_B2_PROCARCH_APPLICATION_KEY' "$FM_TEST_DOCKER_LOG" || fail "canonical reader secret was not forwarded"
if grep -q 'BACKBLAZE_B2_FMREC_' "$FM_TEST_DOCKER_LOG"; then
  fail "uploader credential crossed into reader wrapper"
fi
pass "reader wrapper receives only its canonical service credential pair"

# Standalone archive/browser services must never recreate the processor
# container. The existing-only mode refuses before `up -d` when the role is not
# already running, and reaches only `compose exec` once the `fm` service exists.
clear_log
if FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1 \
    bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/archive-uploader-boot.sh \
    >"$TMP_DIR/not-running.out" 2>"$TMP_DIR/not-running.err"; then
  fail "existing-only container entry accepted a stopped processor"
fi
if grep -q 'up -d' "$FM_TEST_DOCKER_LOG"; then
  fail "existing-only container entry ran compose up"
fi
grep -q 'not already running' "$TMP_DIR/not-running.err" || fail "existing-only refusal was not actionable"
pass "existing-only entry refuses a stopped processor without compose up"

clear_log
FM_PROCESSOR_CONTAINER_REQUIRE_RUNNING=1 FM_TEST_DOCKER_RUNNING=1 \
  bash "$WORKSPACE/scripts/service/container-exec.sh" scripts/service/archive-uploader-boot.sh \
  >"$TMP_DIR/running.out" 2>"$TMP_DIR/running.err" || {
    cat "$TMP_DIR/running.err" >&2
    fail "existing-only container entry rejected a running processor"
  }
if grep -q 'up -d' "$FM_TEST_DOCKER_LOG"; then
  fail "existing-only container entry recreated the running processor"
fi
grep -q 'exec' "$FM_TEST_DOCKER_LOG" || fail "existing-only entry did not exec the uploader"
pass "existing-only entry execs a running processor without lifecycle changes"

echo "processor container-exec behavior: all checks passed"
