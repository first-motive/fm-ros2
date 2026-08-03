#!/usr/bin/env bash
# Regression checks for the appliance updater's recorder busy gate.
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

echo "test-appliance-update: passed"
