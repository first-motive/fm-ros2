#!/usr/bin/env bash
# The processor container mounts the directories the role is CONFIGURED with (#145).
#
#   ./scripts/ci/test-processor-mounts.sh
#
# compose.processor.yaml carries a fixed set under $HOME. A rig with a data volume
# points its knobs at /data/... instead, and those never crossed the boundary: the
# engine was handed /data/recordings — which the role reads and the container could
# not see — and reported the input as missing while the episodes sat exactly where
# the service would have looked (gate 4.2, fm-ws-01).
#
# Reads a fixture env file; mounts nothing and needs no Docker.
set -uo pipefail # not -e: run every check, aggregate at the end
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../internal/lib-processor.sh disable=SC1091
source scripts/internal/lib-processor.sh

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/uv-python"
export FM_PROCESSOR_UV_PYTHON_ROOT="$WORK/uv-python"

echo "== mount preparation fails closed =="
printf 'not a directory\n' > "$WORK/not-a-directory"
if (FM_PROCESSOR_DATA_ROOT="$WORK/not-a-directory" fm_processor_prepare_mounts "$WORK" >/dev/null 2>&1); then
  fail "an invalid shared data root was accepted"
else
  pass "an invalid shared data root stops before compose can create placeholders"
fi
cat > "$WORK/invalid-env" <<ENV
FM_PROCESSOR_RECORDINGS_DIR=$WORK/not-a-directory/recordings
ENV
if (FM_PROCESSOR_DATA_ROOT="$WORK/data" FM_PROCESSOR_ENV_FILE="$WORK/invalid-env" \
  fm_processor_prepare_mounts "$WORK" >/dev/null 2>&1); then
  fail "an invalid configured mount was accepted"
else
  pass "an invalid configured mount stops before compose can create it as root"
fi

cat > "$WORK/env" <<ENV
FM_PROCESSOR_RECORDINGS_DIR=/data/recordings
FM_PROCESSOR_OUTPUT_DIR=/data/processed
FM_PROCESSOR_RUNS_DIR=/data/fm-data-runs
FM_PROCESSOR_ANNOTATION_ATTEMPTS_DIR=/data/fm-data-runs/annotation-attempts
FM_PROCESSOR_ANNOTATION_REVIEWS_DIR=/data/fm-data-runs/annotation-reviews
FM_PROCESSOR_HOME_DIR=$HOME/processed
FM_PROCESSOR_RELATIVE_DIR=not-a-path
ENV
export FM_PROCESSOR_ENV_FILE="$WORK/env"

fm_processor_mounts_overlay "$WORK" >/dev/null
rendered="$WORK/.fm-processor-mounts.yaml"

if [[ -f "$rendered" ]]; then
  pass "a rig with configured directories gets an overlay"
else
  fail "no overlay was rendered for a rig pointed outside \$HOME"
fi

if grep -q -- "- /data/recordings:/data/recordings" "$rendered"; then
  pass "the configured recordings directory is mounted"
else
  fail "the configured recordings directory never crossed — this is gate 4.2"
fi

echo "== the annotation knobs collapse onto their parent =="
if grep -q -- "- /data/fm-data-runs:/data/fm-data-runs" "$rendered"; then
  pass "the runs directory is mounted once"
else
  fail "the runs directory is missing"
fi
if grep -q "annotation-attempts" "$rendered"; then
  fail "a child of an already-mounted directory was mounted again"
else
  pass "children of a mounted directory are not repeated"
fi

echo "== what does not belong =="
if grep -q "$HOME/processed" "$rendered"; then
  fail "a \$HOME directory was added — the base overlay already carries those"
else
  pass "\$HOME directories are left to the base overlay"
fi
if grep -q "not-a-path" "$rendered"; then
  fail "a non-path value was treated as a mount"
else
  pass "a value that is not an absolute path is not a mount"
fi

echo "== deterministic, so it is not itself a reason to recreate =="
first="$(cat "$rendered")"
fm_processor_mounts_overlay "$WORK" >/dev/null
if [[ "$first" == "$(cat "$rendered")" ]]; then
  pass "an unchanged configuration renders byte-identical"
else
  fail "the overlay changes between runs — every up would recreate the container"
fi

echo "== the compose invocation actually carries it =="
# The generator working is not the same as it being wired in. A wiring edit was
# lost once and every check above still passed, so the invocation is asserted too.
cat > "$WORK/env" <<ENV
FM_PROCESSOR_RECORDINGS_DIR=/data/recordings
ENV
mkdir -p "$WORK/docker"
fm_processor_compose "$WORK"
if [[ "${FM_COMPOSE[*]}" == *".fm-processor-mounts.yaml"* ]]; then
  pass "fm_processor_compose stacks the generated overlay in"
else
  fail "the overlay is generated and never passed to compose: ${FM_COMPOSE[*]}"
fi

echo "== a rig on the defaults gets nothing extra =="
printf 'FM_PROCESSOR_RECORDINGS_DIR=%s/recordings\n' "$HOME" > "$WORK/env"
fm_processor_mounts_overlay "$WORK" >/dev/null
if [[ -f "$rendered" ]]; then
  fail "an overlay was rendered for a rig that uses the \$HOME defaults"
else
  pass "a default rig adds no overlay at all"
fi
fm_processor_compose "$WORK"
if [[ "${FM_COMPOSE[*]}" == *".fm-processor-mounts.yaml"* ]]; then
  fail "compose still points at an overlay that is no longer rendered"
else
  pass "a default rig's compose invocation carries no overlay"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "processor mounts: all checks passed"
