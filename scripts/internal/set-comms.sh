#!/usr/bin/env bash
# set-comms.sh — write this host's transport choice where everything reads it.
#
# Called by `./run.sh --comms <profile>` and `./install.sh --comms <profile>`;
# never invoked directly. One script rather than two copies, because the two
# front doors must agree about where the answer is stored — a `--comms` that
# meant one file on install and another at launch is a host that changes its
# transport when you restart it.
#
#     ./scripts/internal/set-comms.sh zenoh
#     ./scripts/internal/set-comms.sh dds-lan
#
# The identity card is the destination. fm-setup owns writing it (`fm machine
# init --transport`), so this delegates rather than editing the card by hand:
# the card is validated and written atomically there, and a second writer with
# its own idea of the schema is how the two drift apart.
#
# A machine with no card — a developer laptop, a checkout that has not been
# provisioned — falls back to the `comms` key in .fm_ros2.json, which comms.sh
# reads when there is no card. That fallback is deliberately second: it is the
# per-checkout answer, and the card is the per-machine one.
set -euo pipefail

cd "$(dirname "$0")/../.."

PROFILE="${1:?usage: set-comms.sh <zenoh|dds-lan>}"

case "$PROFILE" in
  zenoh | dds-lan) ;;
  foxglove)
    # The old name for dds-lan. Accepted so an existing runbook keeps working,
    # and translated here so only one spelling is ever written down.
    echo "note: 'foxglove' is now called 'dds-lan' — writing dds-lan." >&2
    PROFILE=dds-lan
    ;;
  *)
    echo "error: unknown comms profile '$PROFILE' (want zenoh or dds-lan)" >&2
    exit 2
    ;;
esac

# The card's own path, matching what comms.sh resolves.
card_path() {
  if [[ -n "${FM_MACHINE_FILE:-}" ]]; then echo "$FM_MACHINE_FILE"; return; fi
  case "$(uname -s)" in
    Darwin) echo "${XDG_CONFIG_HOME:-$HOME/.config}/fm/machine.json" ;;
    *) echo /etc/fm/machine.json ;;
  esac
}

# Fall back to the per-checkout profile. Written with a real JSON writer rather
# than sed: the file carries the install path and viewer too, and a regex edit
# that met an unexpected shape would quietly drop one of them.
write_checkout_profile() {
  uv run --quiet python - "$PROFILE" <<'PY'
import json, pathlib, sys

profile = sys.argv[1]
path = pathlib.Path(".fm_ros2.json")
data = json.loads(path.read_text()) if path.exists() else {}
data["comms"] = profile
path.write_text(json.dumps(data, indent=2) + "\n")
print(f"profile written: .fm_ros2.json (comms={profile})")
PY
}

CARD="$(card_path)"

if [[ -f "$CARD" ]] && command -v fm >/dev/null 2>&1; then
  # `machine init` is idempotent and repairs in place: it keeps every field it
  # was not asked to change, so this rewrites the transport and nothing else.
  fm machine init --transport "$PROFILE"
  exit 0
fi

if [[ -f "$CARD" ]]; then
  echo "error: $CARD exists but the fm CLI is not on PATH, and the card is fm-setup's to write." >&2
  echo "       install fm-tools, then: fm machine init --transport $PROFILE" >&2
  exit 3
fi

echo "note: this machine has no identity card at $CARD — recording the choice for this checkout only."
echo "      provision the host with 'fm machine init' to make it a machine-wide fact."
write_checkout_profile
