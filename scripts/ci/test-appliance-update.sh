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
  # Passed through to the real git: the updater marks the checkouts safe for
  # root before it reads them, and this test asserts on what that wrote.
  config) exec /usr/bin/git "$@" ;;
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

# The updater runs as root from systemd while the checkouts belong to the
# appliance user, and git refuses a repository it does not own. The exemption git
# grants root keys off SUDO_UID, which an interactive `sudo git` sets and systemd
# does not — so this failed only unattended, and a rig sat two days on a
# superseded tag while every tick printed "up to date". Assert the updater marks
# the checkouts safe, and that asking twice does not stack duplicate entries.
FAKE_HOME="$TMP_DIR/roothome"
mkdir -p "$FAKE_HOME"
# INVOCATION_ID stands in for systemd: these helpers edit the caller's global git
# config, so they act only on the unattended path.
for _ in 1 2; do
  HOME="$FAKE_HOME" INVOCATION_ID=test \
    FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/quiet-recordings" \
    PATH="$TMP_DIR/bin:$PATH" \
    "$ROOT/scripts/service/appliance-update.sh" recorder >/dev/null
done
if ! HOME="$FAKE_HOME" /usr/bin/git config --global --get-all safe.directory 2>/dev/null | grep -qxF '*'; then
  echo "the updater did not mark the checkouts safe for root" >&2
  exit 1
fi
entries="$(HOME="$FAKE_HOME" /usr/bin/git config --global --get-all safe.directory 2>/dev/null | grep -cxF '*')"
if [ "$entries" != "1" ]; then
  printf 'safe.directory stacked %s duplicate entries across runs\n' "$entries" >&2
  exit 1
fi

# Run by hand, the same script must leave the caller's git config alone.
BYHAND_HOME="$TMP_DIR/byhand"
mkdir -p "$BYHAND_HOME"
env -u INVOCATION_ID HOME="$BYHAND_HOME" \
  FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/quiet-recordings" \
  PATH="$TMP_DIR/bin:$PATH" \
  "$ROOT/scripts/service/appliance-update.sh" recorder >/dev/null
if [ -e "$BYHAND_HOME/.gitconfig" ]; then
  echo "an interactive run edited the caller's global git config" >&2
  cat "$BYHAND_HOME/.gitconfig" >&2
  exit 1
fi

# The token lives in the appliance user's home; the updater runs as root, which
# has neither the file nor a helper. Every private repo therefore came back
# "dirty or unfetchable" and stayed at its flash-time commit. Point root at the
# user's store — and never at a store that is not there.
CRED_HOME="$TMP_DIR/credhome"
OWNER_HOME="$TMP_DIR/ownerhome"
mkdir -p "$CRED_HOME" "$OWNER_HOME"
printf 'https://x-access-token:token@github.com\n' > "$OWNER_HOME/.git-credentials"
chmod 600 "$OWNER_HOME/.git-credentials"
HOME="$CRED_HOME" INVOCATION_ID=test FM_OWNER_HOME="$OWNER_HOME" \
  FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/quiet-recordings" \
  PATH="$TMP_DIR/bin:$PATH" \
  "$ROOT/scripts/service/appliance-update.sh" recorder >/dev/null
helper="$(HOME="$CRED_HOME" /usr/bin/git config --global --get credential.helper 2>/dev/null || true)"
if [ "$helper" != "store --file=$OWNER_HOME/.git-credentials" ]; then
  printf 'git was not pointed at the owner store; got: %s\n' "'$helper'" >&2
  exit 1
fi

# A rig with no token has no private repos to converge — that is not a failure,
# and it must not leave a helper pointing at a file that does not exist.
NOCRED_HOME="$TMP_DIR/nocredhome"
EMPTY_OWNER="$TMP_DIR/emptyowner"
mkdir -p "$NOCRED_HOME" "$EMPTY_OWNER"
HOME="$NOCRED_HOME" INVOCATION_ID=test FM_OWNER_HOME="$EMPTY_OWNER" \
  FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/quiet-recordings" \
  PATH="$TMP_DIR/bin:$PATH" \
  "$ROOT/scripts/service/appliance-update.sh" recorder >/dev/null
if HOME="$NOCRED_HOME" /usr/bin/git config --global --get credential.helper >/dev/null 2>&1; then
  echo "a rig with no token was given a credential helper anyway" >&2
  exit 1
fi

echo "test-appliance-update: passed"
