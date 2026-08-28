#!/usr/bin/env bash
# Offline checks for the standalone Foxglove service's native/container routes.
#
# The installer and wrappers are copied into a temporary workspace. Fake compose,
# systemd, and socket tools prove runtime selection, existing-only container
# execution, scoped stop, and unit rendering without starting a service or
# touching /etc, Docker, ROS, credentials, or a host listener.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
TARGET_PID=""
CHILD_PID=""
SIBLING_PID=""
CHILD_PID_FILE=""

cleanup_test_processes() {
  local pid
  if [ -z "$CHILD_PID" ] && [ -n "$CHILD_PID_FILE" ] && [ -f "$CHILD_PID_FILE" ]; then
    CHILD_PID="$(cat "$CHILD_PID_FILE" 2>/dev/null || true)"
  fi
  for pid in "$TARGET_PID" "$CHILD_PID" "$SIBLING_PID"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "$TARGET_PID" "$CHILD_PID" "$SIBLING_PID"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_test_processes; rm -rf "$TMP_DIR"' EXIT

WORKSPACE="$TMP_DIR/workspace"
BIN="$TMP_DIR/bin"
mkdir -p "$WORKSPACE/scripts/ci" "$WORKSPACE/scripts/env" \
  "$WORKSPACE/scripts/internal" "$WORKSPACE/scripts/install" \
  "$WORKSPACE/scripts/service" "$WORKSPACE/docker" "$BIN"

cp "$ROOT/lib.sh" "$WORKSPACE/"
cp "$ROOT/scripts/env/bridge.sh" "$WORKSPACE/scripts/env/"
cp "$ROOT/scripts/internal/lib-compose.sh" "$WORKSPACE/scripts/internal/"
cp "$ROOT/scripts/internal/lib-processor.sh" "$WORKSPACE/scripts/internal/"
cp "$ROOT/scripts/service/container-exec.sh" "$WORKSPACE/scripts/service/"
cp "$ROOT/scripts/service/container-stop.sh" "$WORKSPACE/scripts/service/"
cp "$ROOT/scripts/service/foxglove-boot.sh" "$WORKSPACE/scripts/service/"
cp "$ROOT/scripts/install/install-bridge-config.sh" "$WORKSPACE/scripts/install/"
cp "$ROOT/scripts/install/install-foxglove-service.sh" "$WORKSPACE/scripts/install/"
touch "$WORKSPACE/docker/compose.yaml"

cat >"$BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${FM_TEST_DOCKER_LOG:?}"
if [[ "$*" == *" ps --status running --services"* ]]; then
  if [ "${FM_TEST_CONTAINER_RUNNING:-1}" = 1 ]; then
    printf 'fm\n'
  fi
  exit 0
fi
if [[ "$*" == *" exec "* ]]; then
  exit 0
fi
echo "unexpected fake docker invocation: $*" >&2
exit 1
EOF
chmod +x "$BIN/docker"

cat >"$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"${FM_TEST_SYSTEMCTL_LOG:?}"
exit 0
EOF
chmod +x "$BIN/systemctl"

# Make the bridge preflight deterministic and independent of this host's ports.
cat >"$BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/ss"

export PATH="$BIN:$PATH"
export FM_TEST_DOCKER_LOG="$TMP_DIR/docker.log"
export FM_TEST_SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
export FM_BRIDGE_NO_SUDO=1

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
new_root() {
  local name="$1"
  rm -rf "${TMP_DIR:?}/$name"
  mkdir -p "$TMP_DIR/$name/etc" "$TMP_DIR/$name/systemd"
}

# The installer must render a container unit only when the prepared processor
# role is already running, and test mode must stop before any service action.
new_root container-install
CONTAINER_ROOT="$TMP_DIR/container-install"
printf '%s\n' 'FM_RECORDER_FOXGLOVE=true' >"$CONTAINER_ROOT/etc/fm-recorder.env"
export FM_FOXGLOVE_SERVICE_TEST_MODE=1
export FM_FOXGLOVE_SERVICE_TEST_ROOT="$CONTAINER_ROOT"
export FM_BRIDGE_ENV_FILE="$CONTAINER_ROOT/etc/fm-bridge.env"
export FM_PROCESSOR_RUNTIME=container
export FM_TEST_CONTAINER_RUNNING=1
: >"$FM_TEST_DOCKER_LOG"
: >"$FM_TEST_SYSTEMCTL_LOG"
bash "$WORKSPACE/scripts/install/install-foxglove-service.sh" --port 28765 \
  >"$TMP_DIR/container-install.out" \
  || fail "container installer test mode failed"
UNIT="$CONTAINER_ROOT/systemd/fm-foxglove.service"
[ -f "$UNIT" ] || fail "container installer did not render a unit"
grep -Fxq "ExecStart=/bin/bash $WORKSPACE/scripts/service/foxglove-boot.sh" "$UNIT" \
  || fail "container unit does not use the host runtime-selecting wrapper"
grep -Fxq "ExecStop=/bin/bash $WORKSPACE/scripts/service/container-exec.sh stop 'foxglove-boot.sh'" "$UNIT" \
  || fail "container unit has no scoped Foxglove stop"
grep -Fxq 'Requires=docker.service' "$UNIT" || fail "container unit has no Docker requirement"
grep -Fxq 'FM_BRIDGE_PORT=28765' "$CONTAINER_ROOT/etc/fm-bridge.env" || fail "container port was not persisted"
grep -Fxq 'FM_BRIDGE_OWNER=standalone' "$CONTAINER_ROOT/etc/fm-bridge.env" || fail "container owner was not persisted"
grep -Fxq 'FM_RECORDER_FOXGLOVE=false' "$CONTAINER_ROOT/etc/fm-recorder.env" \
  || fail "container installer did not disable the embedded recorder bridge"
grep -q 'service not started' "$TMP_DIR/container-install.out" || fail "test mode did not report that service was not started"
if grep -Eq 'restart|enable|up -d' "$FM_TEST_SYSTEMCTL_LOG" "$FM_TEST_DOCKER_LOG"; then
  fail "installer test mode launched or enabled a service"
fi
pass "container installer renders an existing-only unit without launching"

# A stopped/missing processor container fails before bridge ownership or unit
# files are changed.
new_root stopped-install
STOPPED_ROOT="$TMP_DIR/stopped-install"
export FM_FOXGLOVE_SERVICE_TEST_ROOT="$STOPPED_ROOT"
export FM_BRIDGE_ENV_FILE="$STOPPED_ROOT/etc/fm-bridge.env"
export FM_TEST_CONTAINER_RUNNING=0
: >"$FM_TEST_DOCKER_LOG"
if bash "$WORKSPACE/scripts/install/install-foxglove-service.sh" --port 28766 \
    >"$TMP_DIR/stopped-install.out" 2>"$TMP_DIR/stopped-install.err"; then
  fail "stopped processor container was accepted"
fi
grep -q 'not running' "$TMP_DIR/stopped-install.err" || fail "stopped-container error was not actionable"
[ ! -e "$STOPPED_ROOT/etc/fm-bridge.env" ] || fail "stopped validation changed bridge ownership"
[ ! -e "$STOPPED_ROOT/systemd/fm-foxglove.service" ] || fail "stopped validation rendered a unit"
pass "container installer refuses a stopped processor before mutation"

# Native Humble keeps the direct wrapper ExecStart and has no Docker dependency
# or container stop hook.
new_root native-install
NATIVE_ROOT="$TMP_DIR/native-install"
printf '%s\n' 'FM_RECORDER_FOXGLOVE=true' >"$NATIVE_ROOT/etc/fm-recorder.env"
export FM_FOXGLOVE_SERVICE_TEST_ROOT="$NATIVE_ROOT"
export FM_BRIDGE_ENV_FILE="$NATIVE_ROOT/etc/fm-bridge.env"
export FM_PROCESSOR_RUNTIME=native
export FM_TEST_CONTAINER_RUNNING=1
: >"$FM_TEST_DOCKER_LOG"
bash "$WORKSPACE/scripts/install/install-foxglove-service.sh" --port 28767 \
  >"$TMP_DIR/native-install.out" \
  || fail "native installer test mode failed"
NATIVE_UNIT="$NATIVE_ROOT/systemd/fm-foxglove.service"
grep -Fxq "ExecStart=/bin/bash $WORKSPACE/scripts/service/foxglove-boot.sh" "$NATIVE_UNIT" \
  || fail "native unit changed its direct wrapper"
if grep -Eq 'ExecStop=|Requires=docker.service|container-exec.sh' "$NATIVE_UNIT"; then
  fail "native unit gained container-only lifecycle wiring"
fi
[ ! -s "$FM_TEST_DOCKER_LOG" ] || fail "native installer consulted Docker"
pass "native installer keeps the direct Humble route"

# The host wrapper routes a non-Humble host through the existing processor
# compose project, requires the running fm service, and never calls `up -d`.
new_root bridge-config
BRIDGE_ROOT="$TMP_DIR/bridge-config"
export FM_FOXGLOVE_SERVICE_TEST_MODE=0
export FM_FOXGLOVE_SERVICE_TEST_ROOT=
export FM_BRIDGE_ENV_FILE="$BRIDGE_ROOT/etc/fm-bridge.env"
mkdir -p "$BRIDGE_ROOT/etc"
printf '%s\n' 'FM_BRIDGE_PORT=28768' 'FM_BRIDGE_OWNER=standalone' >"$FM_BRIDGE_ENV_FILE"
export FM_PROCESSOR_RUNTIME=container
export FM_TEST_CONTAINER_RUNNING=1
: >"$FM_TEST_DOCKER_LOG"
if ! bash "$WORKSPACE/scripts/service/foxglove-boot.sh" \
    >"$TMP_DIR/bridge.out" 2>"$TMP_DIR/bridge.err"; then
  fail "container Foxglove wrapper route failed"
fi
grep -q 'ps --status running --services' "$FM_TEST_DOCKER_LOG" \
  || fail "container route did not check the existing processor"
grep -q 'exec .*foxglove-boot.sh' "$FM_TEST_DOCKER_LOG" \
  || fail "container route did not exec the bridge wrapper"
if grep -q ' up -d ' "$FM_TEST_DOCKER_LOG"; then
  fail "container route recreated the processor container"
fi
pass "container Foxglove wrapper reuses the running processor container"

# The existing-only route fails closed when the processor disappears between
# installation and service start; Docker is never asked to exec the bridge.
export FM_TEST_CONTAINER_RUNNING=0
: >"$FM_TEST_DOCKER_LOG"
if bash "$WORKSPACE/scripts/service/foxglove-boot.sh" \
    >"$TMP_DIR/bridge-stopped.out" 2>"$TMP_DIR/bridge-stopped.err"; then
  fail "container Foxglove wrapper accepted a stopped processor"
fi
grep -q 'not already running' "$TMP_DIR/bridge-stopped.err" \
  || fail "container route did not explain the stopped processor"
if grep -q 'exec .*foxglove-boot.sh' "$FM_TEST_DOCKER_LOG"; then
  fail "container route execed after the running check failed"
fi
pass "container Foxglove wrapper fails closed when the processor is stopped"

# Exercise the real stop helper against a disposable process tree where /proc is
# available (Linux CI and an actual processor container). The root exits on TERM
# without touching its child, so the assertion proves root-first signalling plus
# the bounded descendant fallback (not only the Docker argv).
if [ "$(uname -s)" = Linux ] && [ -r /proc/1/stat ]; then
TARGET_TOKEN="foxglove-stop-target-$$"
TARGET_SCRIPT="$TMP_DIR/$TARGET_TOKEN.sh"
CHILD_TOKEN="foxglove-stop-child-$$"
CHILD_SCRIPT="$TMP_DIR/$CHILD_TOKEN.sh"
SIBLING_TOKEN="foxglove-stop-sibling-$$"
SIBLING_SCRIPT="$TMP_DIR/$SIBLING_TOKEN.sh"
STOP_LOG="$TMP_DIR/stop-tree.log"
CHILD_READY_FILE="$TMP_DIR/stop-tree.child.ready"
ROOT_READY_FILE="$TMP_DIR/stop-tree.root.ready"
SIBLING_READY_FILE="$TMP_DIR/stop-tree.sibling.ready"
CHILD_PID_FILE="$TMP_DIR/stop-tree.child.pid"
cat >"$CHILD_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' ready >"${FM_STOP_CHILD_READY_FILE:?}"
trap 'printf "child-term\n" >>"${FM_STOP_TEST_LOG:?}"; exit 0' TERM INT
while :; do sleep 0.1; done
EOF
cat >"$TARGET_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
"${1:?child script}" &
child="$!"
printf '%s\n' "$child" >"${FM_STOP_CHILD_PID_FILE:?}"
trap 'printf "root-term\n" >>"${FM_STOP_TEST_LOG:?}"; exit 0' TERM INT
for _try in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "${FM_STOP_CHILD_READY_FILE:?}" ] && break
  sleep 0.1
done
printf '%s\n' root-ready >"${FM_STOP_ROOT_READY_FILE:?}"
wait "$child"
EOF
cat >"$SIBLING_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' sibling-ready >"${FM_STOP_SIBLING_READY_FILE:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
EOF
chmod +x "$TARGET_SCRIPT" "$CHILD_SCRIPT"
chmod +x "$SIBLING_SCRIPT"
: >"$STOP_LOG"
FM_STOP_TEST_LOG="$STOP_LOG" \
  FM_STOP_CHILD_READY_FILE="$CHILD_READY_FILE" \
  FM_STOP_ROOT_READY_FILE="$ROOT_READY_FILE" \
  FM_STOP_CHILD_PID_FILE="$CHILD_PID_FILE" \
  bash "$TARGET_SCRIPT" "$CHILD_SCRIPT" &
TARGET_PID="$!"
for _try in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^root-ready$' "$ROOT_READY_FILE" 2>/dev/null && break
  sleep 0.1
done
grep -q '^root-ready$' "$ROOT_READY_FILE" || fail "stop-tree root did not become ready"
CHILD_PID="$(cat "$CHILD_PID_FILE")"
FM_STOP_TEST_LOG="$STOP_LOG" FM_STOP_SIBLING_READY_FILE="$SIBLING_READY_FILE" \
  bash "$SIBLING_SCRIPT" &
SIBLING_PID="$!"
for _try in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^sibling-ready$' "$SIBLING_READY_FILE" 2>/dev/null && break
  sleep 0.1
done
grep -q '^sibling-ready$' "$SIBLING_READY_FILE" || fail "stop-tree sibling did not become ready"
FM_CONTAINER_STOP_IN_CONTAINER=1 FM_STOP_PATTERN="$TARGET_TOKEN" \
  FM_STOP_TEST_LOG="$STOP_LOG" \
  bash "$WORKSPACE/scripts/service/container-stop.sh" \
  || fail "real process-tree stop helper failed"
wait "$TARGET_PID" 2>/dev/null || true
grep -Fxq 'root-term' "$STOP_LOG" || fail "stop helper did not signal the launch root"
grep -Fxq 'child-term' "$STOP_LOG" || fail "stop helper did not signal the surviving child"
root_line="$(grep -n -m1 -Fx 'root-term' "$STOP_LOG" | cut -d: -f1)"
child_line="$(grep -n -m1 -Fx 'child-term' "$STOP_LOG" | cut -d: -f1)"
[ "$root_line" -lt "$child_line" ] || fail "stop helper signalled the child before its root"
if pgrep -f -- "$CHILD_TOKEN" >/dev/null 2>&1; then
  fail "stop helper left a child process running"
fi
if ! kill -0 "$SIBLING_PID" 2>/dev/null; then
  fail "stop helper touched an unrelated sibling process"
fi
kill -TERM "$SIBLING_PID" 2>/dev/null || true
wait "$SIBLING_PID" 2>/dev/null || true
pass "real process-tree stop is root-first, bounded, and descendant-scoped"
else
  pass "real process-tree stop runs in Linux CI (no /proc on this host)"
fi


# systemd's container stop hook targets only the Foxglove wrapper process and
# sends a process-tree helper through the role-owned container.
: >"$FM_TEST_DOCKER_LOG"
bash "$WORKSPACE/scripts/service/container-exec.sh" stop 'foxglove-boot.sh' \
  >"$TMP_DIR/stop.out" \
  || fail "container stop helper failed"
grep -q "exec -T -e FM_STOP_PATTERN=foxglove-boot.sh -e FM_CONTAINER_STOP_IN_CONTAINER=1 fm bash /ws/scripts/service/container-stop.sh" "$FM_TEST_DOCKER_LOG" \
  || fail "container stop helper did not target the Foxglove wrapper"
if grep -q 'pkill -f' "$FM_TEST_DOCKER_LOG"; then
  fail "container stop helper regressed to broad pkill"
fi
pass "container stop hook is scoped to Foxglove"

echo "test-foxglove-service: all checks passed"
