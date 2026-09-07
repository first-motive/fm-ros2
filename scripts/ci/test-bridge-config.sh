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

# The source-controlled boot path must use the recorder package launch argument when it
# exists, while retaining an older-checkout fallback at the historic default.
grep -q 'foxglove_port:=' "$ROOT/scripts/service/recorder-boot.sh"
grep -q 'FM_BRIDGE_PORT' "$ROOT/scripts/service/recorder-boot.sh"
grep -q 'needs a newer recorder package' "$ROOT/scripts/service/recorder-boot.sh"

# The standalone bridge must use the recorder's pinned DDS LAN interface.
# Otherwise a multihomed tower can start the bridge on a separate DDS graph.
grep -Fq 'EnvironmentFile=-$RECORDER_ENV' "$ROOT/scripts/install/install-foxglove-service.sh"
grep -q 'TimeoutStopSec=15' "$ROOT/scripts/install/install-foxglove-service.sh"

# Every appliance role that persists FM_BRIDGE_OWNER=standalone must reinstall
# the bridge on each updater run. The processor role lacked this, so a routine
# fm-update-processor run rewrote all its other units and left the desktop with
# no bridge (fm-ws-01, 7 September 2026).
for role in recorder processor; do
  setup="$ROOT/scripts/install/setup-$role.sh"
  grep -Fq 'install-foxglove-service.sh --port "$FM_BRIDGE_PORT"' "$setup" ||
    { echo "setup-$role.sh never reinstalls the standalone Foxglove bridge" >&2; exit 1; }
  grep -Fq '"$FM_BRIDGE_OWNER" = standalone' "$setup" ||
    { echo "setup-$role.sh does not treat FM_BRIDGE_OWNER=standalone as self-preserving" >&2; exit 1; }
done

# The processor installs its bridge AFTER the update timer on purpose: the
# installer refuses an occupied port, and this runs under `set -e` from the
# updater. Reversed, a port collision would also stop the appliance reinstalling
# its own updater and strand the box with no way to carry a fix.
processor_setup="$ROOT/scripts/install/setup-processor.sh"
timer_line="$(grep -n 'install-update-timer.sh processor' "$processor_setup" | head -1 | cut -d: -f1)"
bridge_line="$(grep -n 'install-foxglove-service.sh' "$processor_setup" | head -1 | cut -d: -f1)"
[ -n "$timer_line" ] && [ -n "$bridge_line" ] ||
  { echo "setup-processor.sh is missing the update timer or the bridge install" >&2; exit 1; }
[ "$bridge_line" -gt "$timer_line" ] ||
  { echo "setup-processor.sh installs the bridge before the update timer; a port collision would strand the appliance" >&2; exit 1; }

echo "test-bridge-config: passed"
