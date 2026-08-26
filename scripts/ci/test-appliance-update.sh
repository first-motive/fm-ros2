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
  tag)
    [ -z "${FM_TEST_TAG_NAME:-}" ] || printf '%s\n' "$FM_TEST_TAG_NAME"
    exit 0
    ;;
  status) exit 0 ;;
  rev-parse)
    case "${*: -1}" in
      HEAD) printf '%s\n' "${FM_TEST_HEAD_COMMIT:-same-revision}" ;;
      *\^\{commit\}) printf '%s\n' "${FM_TEST_TAG_COMMIT:-same-revision}" ;;
      --is-shallow-repository) printf '%s\n' "${FM_TEST_SHALLOW:-false}" ;;
      *) printf '%s\n' same-revision ;;
    esac
    exit 0
    ;;
  merge-base)
    first="${3:-}"
    second="${4:-}"
    case "${FM_TEST_RELATION:-same}" in
      head-before-tag)
        [ "$first" = "${FM_TEST_HEAD_COMMIT:-}" ] && \
          [ "$second" = "${FM_TEST_TAG_COMMIT:-}" ]
        ;;
      tag-before-head)
        [ "$first" = "${FM_TEST_TAG_COMMIT:-}" ] && \
          [ "$second" = "${FM_TEST_HEAD_COMMIT:-}" ]
        ;;
      diverged) exit 1 ;;
      same) exit 0 ;;
      *) exit 2 ;;
    esac
    exit $?
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

# A guarded exact-main installation can be newer than the published release
# tag. The updater must report that state without rolling the checkout back.
RESOLUTION_ROOT="$TMP_DIR/resolution-ws/fm_ros2"
mkdir -p "$RESOLUTION_ROOT/scripts/service" "$RESOLUTION_ROOT/.git"
cp "$ROOT/lib.sh" "$RESOLUTION_ROOT/lib.sh"
cp "$ROOT/scripts/service/appliance-update.sh" \
  "$RESOLUTION_ROOT/scripts/service/appliance-update.sh"
output="$(
  FM_TEST_TAG_NAME=v0.1.7 \
    FM_TEST_HEAD_COMMIT=new-main \
    FM_TEST_TAG_COMMIT=old-release \
    FM_TEST_RELATION=tag-before-head \
    PATH="$TMP_DIR/bin:$PATH" \
    "$RESOLUTION_ROOT/scripts/service/appliance-update.sh" --check processor
)"
if ! grep -q "check fm_ros2: ahead v0.1.7" <<< "$output"; then
  printf 'a newer checkout must not resolve as behind an older tag; got: %s\n' \
    "$output" >&2
  exit 1
fi
if ! grep -q "no checkout, build, or service change made" <<< "$output"; then
  printf 'the release check must state its non-mutating boundary; got: %s\n' \
    "$output" >&2
  exit 1
fi

# Check mode is safe during activity and must not edit unattended Git config.
CHECK_HOME="$TMP_DIR/check-home"
mkdir -p "$CHECK_HOME" "$TMP_DIR/check-recordings"
touch "$TMP_DIR/check-recordings/active.mcap"
output="$(
  HOME="$CHECK_HOME" INVOCATION_ID=test \
    FM_RECORDER_RECORDINGS_DIR="$TMP_DIR/check-recordings" \
    FM_TEST_TAG_NAME=v0.1.7 \
    FM_TEST_HEAD_COMMIT=new-main \
    FM_TEST_TAG_COMMIT=old-release \
    FM_TEST_RELATION=tag-before-head \
    PATH="$TMP_DIR/bin:$PATH" \
    "$RESOLUTION_ROOT/scripts/service/appliance-update.sh" --check recorder
)"
if ! grep -q "check fm_ros2: ahead v0.1.7" <<< "$output"; then
  printf 'an active recording must not block the read-only release check; got: %s\n' \
    "$output" >&2
  exit 1
fi
if [ -e "$CHECK_HOME/.gitconfig" ]; then
  echo "release check mode edited unattended Git config" >&2
  exit 1
fi

output="$(
  FM_TEST_TAG_NAME=v0.1.7 \
    FM_TEST_HEAD_COMMIT=new-main \
    FM_TEST_TAG_COMMIT=old-release \
    FM_TEST_RELATION=tag-before-head \
    PATH="$TMP_DIR/bin:$PATH" \
    "$RESOLUTION_ROOT/scripts/service/appliance-update.sh" processor
)"
if ! grep -q "fm_ros2 is ahead of v0.1.7" <<< "$output"; then
  printf 'the mutating path must also refuse an older tag; got: %s\n' \
    "$output" >&2
  exit 1
fi

# A newer descendant tag is a valid update, but check mode must only report it.
output="$(
  FM_TEST_TAG_NAME=v0.1.8 \
    FM_TEST_HEAD_COMMIT=old-release \
    FM_TEST_TAG_COMMIT=new-release \
    FM_TEST_RELATION=head-before-tag \
    PATH="$TMP_DIR/bin:$PATH" \
    "$RESOLUTION_ROOT/scripts/service/appliance-update.sh" processor --dry-run
)"
if ! grep -q "check fm_ros2: behind v0.1.8" <<< "$output"; then
  printf 'a descendant release must resolve as a pending update; got: %s\n' \
    "$output" >&2
  exit 1
fi

# A tagged checkout on divergent history must remain held in mutating mode.
output="$(
  FM_TEST_TAG_NAME=v0.1.8 \
    FM_TEST_HEAD_COMMIT=other-lineage \
    FM_TEST_TAG_COMMIT=new-release \
    FM_TEST_RELATION=diverged \
    PATH="$TMP_DIR/bin:$PATH" \
    "$RESOLUTION_ROOT/scripts/service/appliance-update.sh" processor
)"
if ! grep -q "fm_ros2 diverges from v0.1.8" <<< "$output"; then
  printf 'divergent tagged history must stay held; got: %s\n' "$output" >&2
  exit 1
fi

# Prove a real depth-one checkout created before the first release can resolve a
# later descendant tag without moving HEAD. The updater may complete missing
# history to prove ancestry, but check mode must not check out the release.
SHALLOW_SEED="$TMP_DIR/shallow-seed"
SHALLOW_REMOTE="$TMP_DIR/shallow-origin.git"
SHALLOW_ROOT="$TMP_DIR/shallow-ws/fm_ros2"
git init -q -b main "$SHALLOW_SEED"
git -C "$SHALLOW_SEED" config user.name "First Motive CI"
git -C "$SHALLOW_SEED" config user.email "ci@firstmotive.ai"
mkdir -p "$SHALLOW_SEED/scripts/service"
cp "$ROOT/lib.sh" "$SHALLOW_SEED/lib.sh"
cp "$ROOT/scripts/service/appliance-update.sh" \
  "$SHALLOW_SEED/scripts/service/appliance-update.sh"
printf 'initial\n' > "$SHALLOW_SEED/release-state.txt"
git -C "$SHALLOW_SEED" add .
git -C "$SHALLOW_SEED" commit -q -m "initial"
initial_head="$(git -C "$SHALLOW_SEED" rev-parse HEAD)"
git clone -q --bare "$SHALLOW_SEED" "$SHALLOW_REMOTE"
git clone -q --depth 1 "file://$SHALLOW_REMOTE" "$SHALLOW_ROOT"
printf 'released\n' > "$SHALLOW_SEED/release-state.txt"
git -C "$SHALLOW_SEED" add release-state.txt
git -C "$SHALLOW_SEED" commit -q -m "release"
git -C "$SHALLOW_SEED" tag -a v0.1.0 -m v0.1.0
git -C "$SHALLOW_SEED" remote add origin "$SHALLOW_REMOTE"
git -C "$SHALLOW_SEED" push -q origin main v0.1.0
output="$("$SHALLOW_ROOT/scripts/service/appliance-update.sh" --check processor)"
if ! grep -q "check fm_ros2: behind v0.1.0" <<< "$output"; then
  printf 'a shallow untagged checkout must resolve a descendant release; got: %s\n' \
    "$output" >&2
  exit 1
fi
if [ "$(git -C "$SHALLOW_ROOT" rev-parse HEAD)" != "$initial_head" ]; then
  echo "release check moved a shallow checkout" >&2
  exit 1
fi

# The reverse shallow case is the original failure: an untagged main checkout
# newer than the latest release must resolve as ahead and never roll back.
SHALLOW_AHEAD_ROOT="$TMP_DIR/shallow-ahead-ws/fm_ros2"
printf 'unreleased\n' > "$SHALLOW_SEED/release-state.txt"
git -C "$SHALLOW_SEED" add release-state.txt
git -C "$SHALLOW_SEED" commit -q -m "unreleased"
git -C "$SHALLOW_SEED" push -q origin main
git clone -q --depth 1 "file://$SHALLOW_REMOTE" "$SHALLOW_AHEAD_ROOT"
ahead_head="$(git -C "$SHALLOW_AHEAD_ROOT" rev-parse HEAD)"
output="$(
  "$SHALLOW_AHEAD_ROOT/scripts/service/appliance-update.sh" --check processor
)"
if ! grep -q "check fm_ros2: ahead v0.1.0" <<< "$output"; then
  printf 'a shallow checkout newer than its release must stay ahead; got: %s\n' \
    "$output" >&2
  exit 1
fi
if [ "$(git -C "$SHALLOW_AHEAD_ROOT" rev-parse HEAD)" != "$ahead_head" ]; then
  echo "release check rolled back a shallow ahead checkout" >&2
  exit 1
fi

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
