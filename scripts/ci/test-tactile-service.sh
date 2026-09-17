#!/usr/bin/env bash
# Regression checks for the per-hand tactile receiver install: one templated unit,
# one rule + config per side, no port pins (a glove is found by the hand it
# announces), pinned-config and legacy single-glove migration, converge, uninstall.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/etc/systemd" "$TMP_DIR/etc/udev" "$TMP_DIR/home" \
  "$TMP_DIR/overlay/ros2_ws/src/fm_tactile_bridge/fm_tactile_bridge"
# The installer only drops port pins for a receiver that can find a glove itself.
echo "    def discovering(self): ..." \
  > "$TMP_DIR/overlay/ros2_ws/src/fm_tactile_bridge/fm_tactile_bridge/receiver.py"

# sudo runs the command as-is; `sudo -u USER cmd` drops the user switch.
cat > "$TMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -u ] && shift 2
exec "$@"
EOF
cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SYSTEMCTL_LOG"
exit 0
EOF
cat > "$TMP_DIR/bin/udevadm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF
cat > "$TMP_DIR/bin/usermod" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# getent resolves the service user's home; macOS has no getent, so answer from $HOME.
cat > "$TMP_DIR/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '%s:x:1000:1000::%s:/bin/bash\n' "$2" "$HOME"
EOF
chmod +x "$TMP_DIR"/bin/*

log="$TMP_DIR/systemctl.log"
run() {
  HOME="$TMP_DIR/home" SUDO_USER="" \
    FM_TACTILE_UNIT_DIR="$TMP_DIR/etc/systemd" \
    FM_TACTILE_RULES_DIR="$TMP_DIR/etc/udev" \
    FM_TACTILE_OVERLAY="$TMP_DIR/overlay" \
    FM_TEST_SYSTEMCTL_LOG="$log" \
    PATH="$TMP_DIR/bin:$PATH" \
    bash "$ROOT/scripts/install/install-tactile-service.sh" "$@" >/dev/null 2>"$TMP_DIR/stderr"
}
unit="$TMP_DIR/etc/systemd/fm-tactile@.service"
cfg="$TMP_DIR/home/.config/fm-tactile"

# 1. One side: the rule names every glove board and pins no port, the receiver reads
#    the pattern, and the unit lives independently of any one USB link.
run install right
rule="$TMP_DIR/etc/udev/99-fm-tactile-right.rules"
grep -q 'SYMLINK+="fm-tactile-glove-%k"' "$rule"
if grep -q 'KERNELS==' "$rule"; then echo "the rule must not pin a USB port" >&2; exit 1; fi
grep -q 'serial_device: "/dev/fm-tactile-glove-\*"' "$cfg/receiver-right.yaml"
grep -q 'device_id: "glove_right"' "$cfg/receiver-right.yaml"
grep -q 'topic: "/glove_right/tactile"' "$cfg/receiver-right.yaml"
grep -q 'recordings/tactile-raw/glove_right"' "$cfg/receiver-right.yaml"
grep -q '^/\*\*:' "$cfg/receiver-right.yaml"
if grep -q 'BindsTo=' "$unit"; then echo "the unit must not bind to a pinned device" >&2; exit 1; fi
grep -qx 'Restart=always' "$unit"
grep -q 'receiver-%i.yaml node_name:=tactile_receiver_%i' "$unit"
grep -qx 'enable fm-tactile@right.service' "$log"
grep -qx 'restart fm-tactile@right.service' "$log"
[ ! -e "$TMP_DIR/etc/udev/99-fm-tactile-left.rules" ]

# 2. Legacy single-glove install migrates: unit retired, tuned config renamed to left.
: > "$TMP_DIR/etc/systemd/fm-tactile.service"
printf 'tuned: yes\n' > "$cfg/receiver.yaml"
run install left
[ ! -e "$TMP_DIR/etc/systemd/fm-tactile.service" ]
[ ! -e "$cfg/receiver.yaml" ]
grep -qx 'tuned: yes' "$cfg/receiver-left.yaml"
grep -qx 'disable --now fm-tactile.service' "$log"
grep -q 'SYMLINK+="fm-tactile-glove-%k"' "$TMP_DIR/etc/udev/99-fm-tactile-left.rules"

# 3. No side: converge every installed side, never clobber a config.
: > "$log"
run
grep -qx 'enable fm-tactile@left.service' "$log"
grep -qx 'enable fm-tactile@right.service' "$log"
grep -qx 'tuned: yes' "$cfg/receiver-left.yaml"

# 3a. A host converging from the pinned era: the old rule loses its pin and the tuned
#     config keeps its values while its device path moves to the pattern.
printf 'SUBSYSTEM=="tty", KERNELS=="1-1", SYMLINK+="fm-tactile-right"\n' > "$rule"
printf '    serial_device: "/dev/fm-tactile-right"\n    ack_interval_frames: 4\n' > "$cfg/receiver-right.yaml"
run
if grep -q 'KERNELS==' "$rule"; then echo "converge must drop a legacy port pin" >&2; exit 1; fi
grep -q 'serial_device: "/dev/fm-tactile-glove-\*"' "$cfg/receiver-right.yaml"
grep -q 'ack_interval_frames: 4' "$cfg/receiver-right.yaml"

# 3b. A stray rule whose name is not a hand is skipped, not installed.
: > "$TMP_DIR/etc/udev/99-fm-tactile-bogus.rules"
: > "$log"
run
grep -qx 'enable fm-tactile@left.service' "$log"
if grep -q 'bogus' "$log"; then echo "a stray rule must not be installed as a side" >&2; exit 1; fi
[ ! -e "$cfg/receiver-bogus.yaml" ]
rm "$TMP_DIR/etc/udev/99-fm-tactile-bogus.rules"

# 4. Uninstall one side leaves the other and the template; uninstall all removes the template.
run uninstall right
[ ! -e "$rule" ]
[ ! -e "$cfg/receiver-right.yaml" ]
[ -e "$unit" ]
[ -e "$TMP_DIR/etc/udev/99-fm-tactile-left.rules" ]
run uninstall
[ ! -e "$unit" ]
[ ! -e "$TMP_DIR/etc/udev/99-fm-tactile-left.rules" ]

# 5. A receiver that cannot find a glove by its HELLO keeps its pinned install: the
#    installer warns and writes nothing.
: > "$TMP_DIR/overlay/ros2_ws/src/fm_tactile_bridge/fm_tactile_bridge/receiver.py"
run install left
[ ! -e "$TMP_DIR/etc/udev/99-fm-tactile-left.rules" ]
grep -q 'predates glove discovery' "$TMP_DIR/stderr"
echo "    def discovering(self): ..." \
  > "$TMP_DIR/overlay/ros2_ws/src/fm_tactile_bridge/fm_tactile_bridge/receiver.py"

# 6. A side that is not a hand is refused.
if run install middle 2>/dev/null; then
  echo "install must refuse an unknown side" >&2
  exit 1
fi

echo "test-tactile-service: passed"
