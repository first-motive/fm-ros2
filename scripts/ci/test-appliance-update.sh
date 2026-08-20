#!/usr/bin/env bash
# Regression checks for the appliance updater's recorder busy gate and its
# report when the machine layer has no checkout to converge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/recordings/tactile-raw"

cat > "$TMP_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-C" ]; then
  shift 2
fi

case "${1:-}" in
  fetch) exit 0 ;;
  status) exit 0 ;;
  rev-parse)
    printf '%s\n' same-revision
    exit 0
    ;;
  merge-base)
    printf '%s\n' same-revision
    exit 0
    ;;
esac

printf 'unexpected git invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_DIR/bin/git"

cat > "$TMP_DIR/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP_DIR/bin/flock"

touch "$TMP_DIR/recordings/tactile-raw/continuous.tactile.csv"
output="$(
  FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/recordings" \
    PATH="$TMP_DIR/bin:$PATH" \
    "$ROOT/scripts/service/appliance-update.sh" recorder
)"
if ! grep -qx "up to date" <<< "$output"; then
  printf 'continuous tactile evidence must not block updates; got: %s\n' \
    "$output" >&2
  exit 1
fi

# The rig monitors' watchdog jsonl is the other continuous writer (it wedged
# the first Jetson's updater for six days) — it must not block updates either.
mkdir -p "$TMP_DIR/recordings/watchdog"
touch "$TMP_DIR/recordings/watchdog/watchdog-20260819.jsonl"
output="$(
  FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/recordings" \
    PATH="$TMP_DIR/bin:$PATH" \
    "$ROOT/scripts/service/appliance-update.sh" recorder
)"
if ! grep -qx "up to date" <<< "$output"; then
  printf 'continuous watchdog evidence must not block updates; got: %s\n' \
    "$output" >&2
  exit 1
fi

mkdir -p "$TMP_DIR/recordings/episode-active"
touch "$TMP_DIR/recordings/episode-active/chunk_0.mcap"
output="$(
  FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/recordings" \
    PATH="$TMP_DIR/bin:$PATH" \
    "$ROOT/scripts/service/appliance-update.sh" recorder
)"
if ! grep -q "recorder busy (recent writes" <<< "$output"; then
  printf 'recent episode writes must block updates; got: %s\n' "$output" >&2
  exit 1
fi

# A rig with no fm-setup beside the workspace has no machine layer to converge.
# That used to be an if with no else: the drivers, the container runtime, and ROS
# went unconverged on every tick while the updater still reported success. Run
# the updater from a workspace that holds only fm_ros2 and require it to say so.
mkdir -p "$TMP_DIR/ws" "$TMP_DIR/quiet-recordings"
ln -s "$ROOT" "$TMP_DIR/ws/fm_ros2"
output="$(
  FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/quiet-recordings" \
    PATH="$TMP_DIR/bin:$PATH" \
    "$TMP_DIR/ws/fm_ros2/scripts/service/appliance-update.sh" recorder
)"
if ! grep -q "no fm-setup checkout at $TMP_DIR/ws/fm-setup" <<< "$output"; then
  printf 'a missing machine layer must be reported, not skipped; got: %s\n' \
    "$output" >&2
  exit 1
fi
if ! grep -q "machine layer not converged" <<< "$output"; then
  printf 'the report must name the consequence; got: %s\n' "$output" >&2
  exit 1
fi

# A directory that is not a checkout is not a machine layer either — the guard
# tests for .git, so this must warn exactly as an absent path does.
mkdir -p "$TMP_DIR/ws/fm-setup"
output="$(
  FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/quiet-recordings" \
    PATH="$TMP_DIR/bin:$PATH" \
    "$TMP_DIR/ws/fm_ros2/scripts/service/appliance-update.sh" recorder
)"
if ! grep -q "machine layer not converged" <<< "$output"; then
  printf 'a non-checkout fm-setup dir must warn too; got: %s\n' "$output" >&2
  exit 1
fi

echo "test-appliance-update: passed"
