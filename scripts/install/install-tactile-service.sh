#!/usr/bin/env bash
# install-tactile-service.sh — install (or remove) the systemd unit that runs one
# five-channel tactile-glove receiver per hand, plus the udev rule that names every
# glove board so the receivers can find them.
#
# A glove is an ESP32 reading five FSRs, tethered to the recorder host by USB. Its
# firmware burns in which hand it is (usb_tactile_glove.ino says glove_left,
# usb_tactile_glove_right.ino says glove_right) and announces that in its HELLO line;
# a receiver configured for one hand refuses the other. The receiver
# (fm_tactile_bridge) owns that serial port exclusively: it maps the board's monotonic
# clock onto the host clock, publishes /glove_<side>/tactile at 40 Hz, and writes an
# independent CSV audit log under ~/recordings/tactile-raw/glove_<side>. Each hand is
# its own instance of the templated unit, fm-tactile@<side>.service, so a replug of one
# glove never touches the other or the recorder, and the glove keeps streaming (and
# keeps its clock fit warm) while the recorder sits idle between takes.
#
# Three things here are not obvious and are load-bearing:
#
#   1. The CH340 USB-serial adapter reports no factory serial number, so udev cannot
#      tell one board from another — but the board can: its HELLO names its hand. The
#      rule therefore gives EVERY glove board the shared name /dev/fm-tactile-glove-*,
#      both receivers read that pattern, and each claims the board announcing its own
#      hand (fm-tactile >= v0.1.1). Any socket, any cable, any hub. This replaced
#      per-port pins, which went stale with a cable change (2026-09-17) and crossed
#      silently when two plugs were swapped (2026-09-16).
#   2. brltty claims any CH340 as a Braille display before a serial reader can open
#      it. Its udev unit is masked here. The brltty package itself is left installed.
#   3. Nothing else may hold the port. An Arduino Serial Monitor or a stray `screen`
#      will take it and the instance will restart-loop.
#
# Linux + systemd only, best-effort (warns + returns 0 elsewhere), idempotent. Invoked
# by setup-recorder.sh when install.sh got --service; runnable standalone.
#
# Usage:
#   ./scripts/install/install-tactile-service.sh                  # converge every installed side (left if none yet)
#   ./scripts/install/install-tactile-service.sh install right    # install + enable + start one side
#   ./scripts/install/install-tactile-service.sh uninstall right  # stop + disable + remove one side
#   ./scripts/install/install-tactile-service.sh uninstall        # remove every side
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # item()
cd "$ROOT"

# Test seams (scripts/ci/test-tactile-service.sh): the system paths and the overlay
# location, so the install logic runs against a scratch tree with no root and no ROS.
UNIT_DIR="${FM_TACTILE_UNIT_DIR:-/etc/systemd/system}"
RULES_DIR="${FM_TACTILE_RULES_DIR:-/etc/udev/rules.d}"
OVERLAY="${FM_TACTILE_OVERLAY:-$ROOT/src/external/fm_tactile}"

UNIT="$UNIT_DIR/fm-tactile@.service"
LEGACY_UNIT="$UNIT_DIR/fm-tactile.service"

# CH340 (QinHeng) vendor/product — the adapter on the production glove board.
USB_VENDOR="${FM_TACTILE_USB_VENDOR:-1a86}"
USB_PRODUCT="${FM_TACTILE_USB_PRODUCT:-7523}"
# The name every glove board gets, and the pattern both receivers read.
GLOVE_LINK="fm-tactile-glove"
GLOVE_PATTERN="/dev/$GLOVE_LINK-*"

# Sides this host already carries, read back from the rule files it wrote — the
# machine state is the record, so a converge run needs no env to know what to keep.
_installed_sides() {
  local f
  for f in "$RULES_DIR"/99-fm-tactile-*.rules; do
    [ -e "$f" ] || continue
    f="${f##*/99-fm-tactile-}"
    echo "${f%.rules}"
  done
}

# Run the service as the human who installed it, not root — the audit CSVs land beside
# the recorder's bags in that user's ~/recordings, and dialout group access is theirs.
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"
CONFIG_DIR="$SERVICE_HOME/.config/fm-tactile"

usage() {
  cat <<'EOF'
install-tactile-service.sh — install/remove the fm-tactile glove receivers (Linux)

  [install] [SIDE]   write SIDE's udev rule + config and the templated unit, enable
                     for boot, start now. SIDE is left or right. No SIDE: converge
                     every side already installed on this host (left if none yet)
  uninstall [SIDE]   stop + disable + remove SIDE's instance, rule, and config.
                     No SIDE: remove every side and the templated unit
  -h, --help         show this help

Environment:
  FM_TACTILE_USB_VENDOR    USB idVendor,  default 1a86 (CH340)
  FM_TACTILE_USB_PRODUCT   USB idProduct, default 7523 (CH340)

Each side publishes /glove_<side>/tactile at 40 Hz and writes a CSV audit log to
~/recordings/tactile-raw/glove_<side>. Tune it via
~/.config/fm-tactile/receiver-<side>.yaml, then: sudo systemctl restart fm-tactile@<side>.
The glove's firmware decides its side: flash usb_tactile_glove.ino for the left hand
and usb_tactile_glove_right.ino for the right. Plug a glove into any USB socket — its
receiver finds it by the hand it announces.
EOF
}

# Guard: this is a Linux + systemd appliance step. Off that, warn and let the caller
# carry on (the workspace build still works; only the boot service is skipped).
_require_linux_systemd() {
  if [ "$(uname -s)" != Linux ]; then
    echo "WARNING: the tactile receiver service is Linux-only — skipping." >&2
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "WARNING: systemctl not found (no systemd) — skipping the tactile service." >&2
    return 1
  fi
  return 0
}

_require_side() {
  case "${1:-}" in
    left|right) return 0 ;;
    *) echo "error: side must be left or right, got '${1:-}'" >&2; return 1 ;;
  esac
}

# The pre-template single-glove install: fm-tactile.service bound to fm-tactile-left,
# configured by receiver.yaml. Its rule file already carried the left name, so only
# the unit and the config move; the tuned values survive the rename.
_retire_legacy_unit() {
  [ -e "$LEGACY_UNIT" ] || return 0
  item "retiring the single-glove fm-tactile.service (replaced by fm-tactile@<side>) ..."
  sudo systemctl disable --now fm-tactile.service 2>/dev/null || true
  sudo rm -f "$LEGACY_UNIT"
  if [ -f "$CONFIG_DIR/receiver.yaml" ] && [ ! -f "$CONFIG_DIR/receiver-left.yaml" ]; then
    sudo -u "$SERVICE_USER" mv "$CONFIG_DIR/receiver.yaml" "$CONFIG_DIR/receiver-left.yaml"
  fi
}

_write_unit() {
  # The instance runs from boot and outlives any one USB link: with no port to bind
  # to, the receiver itself walks the glove pattern once a second and reconnects, so a
  # replug, a new cable, or a different socket needs no unit restart. %i is the side.
  item "writing $UNIT (User=$SERVICE_USER, workspace=$ROOT) ..."
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive tactile glove receiver (%i hand, ESP32, 5-channel, 40 Hz)
# The receiver fits the glove's clock to the host's; a fit started in 1970 is wrong.
After=time-sync.target
Wants=time-sync.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
WorkingDirectory=$ROOT
ExecStart=/bin/bash -lc 'source /opt/ros/humble/setup.bash && source $ROOT/install/setup.bash && source $ROOT/scripts/env/comms.sh && exec ros2 launch fm_tactile_bridge receiver.launch.py config:=$CONFIG_DIR/receiver-%i.yaml node_name:=tactile_receiver_%i'
Restart=always
RestartSec=2
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
}

_write_rule() {  # side
  local side="$1" rule="$RULES_DIR/99-fm-tactile-$1.rules"
  item "writing $rule (every glove board -> $GLOVE_PATTERN) ..."
  sudo tee "$rule" >/dev/null <<EOF
# First Motive tactile glove ($side hand) — names every glove board for the receivers.
#
# The CH340 on this board reports no factory USB serial number, so udev cannot tell
# two boards apart and this rule does not try: it matches ANY glove board and gives it
# the shared name $GLOVE_LINK-<tty>. The $side receiver reads that pattern and
# claims the board whose HELLO announces glove_$side. One file per installed hand is
# this host's record of which sides it carries; the match is the same in each.
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", ATTRS{idVendor}=="$USB_VENDOR", ATTRS{idProduct}=="$USB_PRODUCT", SYMLINK+="$GLOVE_LINK-%k", GROUP="dialout", MODE="0660"
EOF
}

_write_config() {  # side
  # Template only when absent, so a re-install never clobbers a host's tuned values.
  # Owner-only: the Wi-Fi transport variant carries a token path. The /**: key lets
  # the one file serve whichever node name the unit passes.
  local side="$1" file="$CONFIG_DIR/receiver-$1.yaml"
  if [ -f "$file" ]; then
    # A tuned config is kept; only the pinned device path it may still carry moves
    # to the pattern, or the receiver would wait on a name no rule creates any more.
    if grep -q "serial_device: \"/dev/fm-tactile-$side\"" "$file"; then
      item "pointing $file at $GLOVE_PATTERN (was a pinned port name) ..."
      sudo sed -i.bak "s|serial_device: \"/dev/fm-tactile-$side\"|serial_device: \"$GLOVE_PATTERN\"|" "$file"
      sudo rm -f "$file.bak"
    fi
    # A config migrated from the single-glove install is keyed to the old fixed node
    # name. The unit now names the node tactile_receiver_<side> (fm-tactile >= v0.2.0
    # honours it), so that key would match nothing and the receiver would start on
    # defaults (tcp, no token) and crash-loop, probing every glove port each restart.
    if grep -q '^tactile_receiver:$' "$file"; then
      item "keying $file to /**: (was the single-glove node name) ..."
      sudo sed -i.bak 's|^tactile_receiver:$|/**:|' "$file"
      sudo rm -f "$file.bak"
    fi
    return 0
  fi
  item "writing $file (receiver config — edit, then restart the instance) ..."
  sudo -u "$SERVICE_USER" install -d -m 0700 "$CONFIG_DIR"
  sudo -u "$SERVICE_USER" tee "$file" >/dev/null <<EOF
# fm-tactile@$side.service — receiver parameters. Edit, then: sudo systemctl restart fm-tactile@$side
/**:
  ros__parameters:
    # "serial" for the USB-tethered board; "tcp" for the Wi-Fi variant (which also
    # needs bind_address, port, and a token_file readable only by this user).
    transport: "serial"
    # A pattern, not a port: the receiver claims the board announcing glove_$side.
    serial_device: "$GLOVE_PATTERN"
    serial_baud: 115200
    device_id: "glove_$side"
    topic: "/glove_$side/tactile"
    # Audit CSVs land beside the recorder's bags, one directory per hand so two
    # receivers never write the same episode file. The parent must stay exactly
    # <recordings>/tactile-raw: appliance-update.sh prunes that one tree from its
    # busy check, and a path outside it would block every auto-update tick instead.
    audit_output_dir: "$SERVICE_HOME/recordings/tactile-raw/glove_$side"
    recorder_status_topic: "/fm_data_record/recorder_status"
    # time_synchronized is reported true only below this clock-fit uncertainty.
    max_sync_uncertainty_ms: 10.0
    ack_interval_frames: 8
    sensor_names: ["S1", "S2", "S3", "S4", "S5"]
EOF
  sudo chmod 0600 "$file"
  sudo chown "$SERVICE_USER" "$file"
}

do_install() {  # side
  local side="$1"
  _require_linux_systemd || return 0
  if [ ! -d "$OVERLAY/ros2_ws/src/fm_tactile_bridge" ]; then
    echo "WARNING: the tactile overlay is not checked out at $OVERLAY — skipping." >&2
    echo "         Run ./install.sh --recorder first (it clones and builds it)." >&2
    return 0
  fi
  # Finding a glove by its HELLO lives in the receiver. An overlay that predates it
  # cannot read a pattern, so this host's working pinned install is left alone.
  if ! grep -q "def discovering" "$OVERLAY/ros2_ws/src/fm_tactile_bridge/fm_tactile_bridge/receiver.py" 2>/dev/null; then
    echo "WARNING: the tactile overlay at $OVERLAY predates glove discovery (needs" >&2
    echo "         fm-tactile >= v0.1.1) — leaving the existing receiver install as it is." >&2
    return 0
  fi

  # 0. The unit runs as the installing user, and the udev rule below grants the
  #    device to group dialout — a wizard-created user (fresh Jetson) is not in
  #    it, so the receiver would land on a port it cannot open (found live,
  #    2026-08-13). Idempotent; takes effect for the unit at its next start.
  if ! id -nG "$SERVICE_USER" | tr " " "\n" | grep -qx dialout; then
    item "adding $SERVICE_USER to the dialout group (serial port access) ..."
    sudo usermod -aG dialout "$SERVICE_USER"
  fi

  _retire_legacy_unit

  # 1. Name every glove board. The receiver, not the socket, decides whose it is.
  _write_rule "$side"

  # 2. brltty grabs any CH340 as a Braille display within a second of plug-in, before
  #    the receiver can open the port. Masking its udev unit is the documented fix and
  #    is reversible: sudo systemctl unmask --now brltty-udev.service
  if systemctl list-unit-files brltty-udev.service >/dev/null 2>&1; then
    item "masking brltty-udev.service (it claims the CH340 before the receiver can) ..."
    sudo systemctl mask --now brltty-udev.service 2>/dev/null || true
  fi

  sudo udevadm control --reload-rules && sudo udevadm trigger

  # 3. Receiver config and the templated unit shared by every side.
  _write_config "$side"
  _write_unit

  item "enabling + starting fm-tactile@$side.service ..."
  sudo systemctl daemon-reload
  sudo systemctl enable "fm-tactile@$side.service"
  sudo systemctl restart "fm-tactile@$side.service"

  cat <<EOF

fm-tactile@$side.service installed and started — it now comes up on every boot.

  status:  systemctl is-active fm-tactile@$side   |  journalctl -u fm-tactile@$side -f
  device:  ls -l $GLOVE_PATTERN          (one per plugged-in glove, either hand)
  stream:  ros2 topic hz /glove_$side/tactile      (expect 38-42 Hz)
  config:  sudo nano $CONFIG_DIR/receiver-$side.yaml  (then: sudo systemctl restart fm-tactile@$side)

Plug the $side glove into any USB socket: the receiver finds it by the hand its
firmware announces. Do not open a serial monitor while the service is running.
EOF
}

do_uninstall() {  # side
  local side="$1"
  _require_linux_systemd || return 0
  item "stopping + disabling fm-tactile@$side.service (if present) ..."
  sudo systemctl disable --now "fm-tactile@$side.service" 2>/dev/null || true
  sudo rm -f "$RULES_DIR/99-fm-tactile-$side.rules" "$CONFIG_DIR/receiver-$side.yaml"
  sudo systemctl daemon-reload 2>/dev/null || true
  sudo udevadm control --reload-rules 2>/dev/null || true
}

do_uninstall_all() {
  _require_linux_systemd || return 0
  local side
  for side in $(_installed_sides); do do_uninstall "$side"; done
  sudo systemctl disable --now fm-tactile.service 2>/dev/null || true
  sudo rm -f "$UNIT" "$LEGACY_UNIT"
  sudo systemctl daemon-reload 2>/dev/null || true
  # brltty stays masked: unmasking it would re-break any other CH340 device on the
  # host, and the operator can undo it deliberately if they need Braille support.
  item "fm-tactile receivers removed (brltty-udev stays masked; unmask it manually if needed)."
}

# No side named: converge what the host already carries. The legacy single-glove
# install and a fresh host both mean left, the default hand.
do_converge() {
  local sides side
  sides="$(_installed_sides)"
  [ -n "$sides" ] || sides=left
  for side in $sides; do
    # A rule file with a name that is not a hand is someone's stray edit, not a
    # side to install; skipping it keeps the auto-update converge alive.
    _require_side "$side" 2>/dev/null || { item "WARNING: ignoring $RULES_DIR/99-fm-tactile-$side.rules — not a hand"; continue; }
    do_install "$side"
  done
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    uninstall)
      if [ -n "${2:-}" ]; then _require_side "$2" && do_uninstall "$2"; else do_uninstall_all; fi ;;
    ""|install)
      if [ -n "${2:-}" ]; then _require_side "$2" && do_install "$2"; else do_converge; fi ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
  esac
}

main "$@"
