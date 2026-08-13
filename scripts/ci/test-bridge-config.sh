#!/usr/bin/env bash
# Regression checks for the shared bridge endpoint and the configured-port probe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

CONFIG="$TMP_DIR/fm-bridge.env"

FM_BRIDGE_ENV_FILE="$CONFIG" FM_BRIDGE_PORT=8766 FM_BRIDGE_NO_SUDO=1 \
  "$ROOT/scripts/install/install-bridge-config.sh" --owner standalone >/dev/null
grep -qx 'FM_BRIDGE_PORT=8766' "$CONFIG"
grep -qx 'FM_BRIDGE_OWNER=standalone' "$CONFIG"
printf 'EXTRA_KEY=preserved\n' >> "$CONFIG"

# A role re-install with no explicit option must keep the persisted tower value
# and unrelated config lines.
FM_BRIDGE_ENV_FILE="$CONFIG" FM_BRIDGE_NO_SUDO=1 \
  "$ROOT/scripts/install/install-bridge-config.sh" >/dev/null
grep -qx 'FM_BRIDGE_PORT=8766' "$CONFIG"
grep -qx 'EXTRA_KEY=preserved' "$CONFIG"

if FM_BRIDGE_ENV_FILE="$CONFIG" FM_BRIDGE_NO_SUDO=1 \
  "$ROOT/scripts/install/install-bridge-config.sh" --port 70000 >/dev/null 2>&1; then
  echo "invalid bridge port was accepted" >&2
  exit 1
fi

# Probe resolution uses the configured port, not a fixed 8765. The --print path
# keeps this host-side check independent of ROS/systemd and restricted sockets;
# the live service installer uses the same probe without --print.
FM_BRIDGE_ENV_FILE="$CONFIG" FM_BRIDGE_NO_SUDO=1 \
  "$ROOT/scripts/install/install-bridge-config.sh" --port 18765 >/dev/null
endpoint="$(FM_BRIDGE_ENV_FILE="$CONFIG" python3 -B "$ROOT/scripts/internal/bridge-probe.py" --print)"
[ "$endpoint" = 127.0.0.1:18765 ]
FM_BRIDGE_ENV_FILE="$CONFIG" python3 -B - <<'PY'
import importlib.util

spec = importlib.util.spec_from_file_location(
    "topic_probe", "scripts/service/bridge-probe.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module._configured_port() == 18765
PY

# The source-controlled boot path must use the fm-data launch argument when it
# exists, while retaining an older-checkout fallback at the historic default.
grep -q 'foxglove_port:=' "$ROOT/scripts/service/recorder-boot.sh"
grep -q 'FM_BRIDGE_PORT' "$ROOT/scripts/service/recorder-boot.sh"
grep -q 'needs a newer fm-data' "$ROOT/scripts/service/recorder-boot.sh"

echo "test-bridge-config: passed"
