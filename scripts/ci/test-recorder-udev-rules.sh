#!/usr/bin/env bash
# Regression checks for repeat-safe and transient-safe RealSense rule install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$TMP_DIR/bin/udevadm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_UDEVADM_LOG"
EOF
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${FM_TEST_CURL_MUST_NOT_RUN:-0}" != 1 ] || exit 97
printf '%s\n' "$*" > "$FM_TEST_CURL_LOG"
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
[ -n "$output" ]
printf 'pinned rules\n' > "$output"
EOF
chmod +x "$TMP_DIR/bin/sudo" "$TMP_DIR/bin/udevadm" "$TMP_DIR/bin/curl"

rules_file="$TMP_DIR/99-realsense-libusb.rules"
udevadm_log="$TMP_DIR/udevadm.log"
curl_log="$TMP_DIR/curl.log"
rules_sha256="$(printf 'pinned rules\n' | sha256sum | cut -d' ' -f1)"
printf 'pinned rules\n' > "$rules_file"
FM_REALSENSE_UDEV_RULES_FILE="$rules_file" \
  FM_REALSENSE_UDEV_RULES_SHA256="$rules_sha256" \
  FM_TEST_CURL_MUST_NOT_RUN=1 \
  FM_TEST_UDEVADM_LOG="$udevadm_log" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$ROOT/scripts/internal/install-realsense-udev-rules.sh" >/dev/null
grep -qx 'pinned rules' "$rules_file"
[ ! -e "$curl_log" ]

printf 'partial rules\n' > "$rules_file"
FM_REALSENSE_UDEV_RULES_FILE="$rules_file" \
  FM_REALSENSE_UDEV_RULES_SHA256="$rules_sha256" \
  FM_TEST_CURL_LOG="$curl_log" \
  FM_TEST_UDEVADM_LOG="$udevadm_log" \
  PATH="$TMP_DIR/bin:$PATH" \
  bash "$ROOT/scripts/internal/install-realsense-udev-rules.sh" >/dev/null
grep -qx 'pinned rules' "$rules_file"
grep -q -- '--retry 4 --retry-all-errors --retry-delay 2' "$curl_log"
grep -q '7c3ee3fb7c640e9f315e663907208cb56c4febfd' "$curl_log"
if grep -q '/master/' "$curl_log"; then
  echo "RealSense rules URL must be pinned, not master" >&2
  exit 1
fi
[ "$(grep -c '^control --reload-rules$' "$udevadm_log")" -eq 2 ]
[ "$(grep -c '^trigger$' "$udevadm_log")" -eq 2 ]

echo "test-recorder-udev-rules: passed"
