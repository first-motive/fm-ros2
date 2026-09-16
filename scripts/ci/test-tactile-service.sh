#!/usr/bin/env bash
# Regression checks for the per-hand tactile receiver install: one templated unit,
# one rule + config per side, legacy single-glove migration, converge, uninstall.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/etc/systemd" "$TMP_DIR/etc/udev" "$TMP_DIR/home" \
  "$TMP_DIR/overlay/ros2_ws/src/fm_tactile_bridge"

# sudo runs the command as-is; `sudo -u USER cmd` drops the user switch.
cat > "$TMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -u ] && shift 2
exec "$@"
EOF
# `restart` fails like the real one does when the glove's device unit is absent.
cat > "$TMP_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SYSTEMCTL_LOG"
[ "$1" = restart ] && [ "${FM_TEST_DEVICE_ABSENT:-0}" = 1 ] && exit 1
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

# 1. One side, port named: rule pinned to it, config and unit carry that side only.
FM_TACTILE_USB_PORT=1-1 run install right
rule="$TMP_DIR/etc/udev/99-fm-tactile-right.rules"
grep -q 'KERNELS=="1-1"' "$rule"
grep -q 'SYMLINK+="fm-tactile-right"' "$rule"
grep -q 'ENV{SYSTEMD_WANTS}="fm-tactile@right.service"' "$rule"
grep -q 'device_id: "glove_right"' "$cfg/receiver-right.yaml"
grep -q 'topic: "/glove_right/tactile"' "$cfg/receiver-right.yaml"
grep -q 'recordings/tactile-raw/glove_right"' "$cfg/receiver-right.yaml"
grep -q '^/\*\*:' "$cfg/receiver-right.yaml"
grep -q 'BindsTo=dev-fm\\x2dtactile\\x2d%i.device' "$unit"
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
grep -q 'ENV{SYSTEMD_WANTS}="fm-tactile@left.service"' "$TMP_DIR/etc/udev/99-fm-tactile-left.rules"

# 3. No side: converge every installed side, never clobber a config.
: > "$log"
run
grep -qx 'enable fm-tactile@left.service' "$log"
grep -qx 'enable fm-tactile@right.service' "$log"
grep -qx 'tuned: yes' "$cfg/receiver-left.yaml"
grep -q 'KERNELS=="1-1"' "$rule"   # right keeps its pin with the board unplugged

# 3b. A stray rule whose name is not a hand is skipped, not installed.
: > "$TMP_DIR/etc/udev/99-fm-tactile-bogus.rules"
: > "$log"
run
grep -qx 'enable fm-tactile@left.service' "$log"
! grep -q 'bogus' "$log"
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

# 5. Installing with the glove unplugged is not a failure: the rule starts it at plug-in.
FM_TEST_DEVICE_ABSENT=1 run install left

# 6. A side that is not a hand is refused.
if run install middle 2>/dev/null; then
  echo "install must refuse an unknown side" >&2
  exit 1
fi

echo "test-tactile-service: passed"
