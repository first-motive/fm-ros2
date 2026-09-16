#!/usr/bin/env bash
# install-tactile-service.sh — install (or remove) the systemd unit that runs one
# five-channel tactile-glove receiver per hand, plus the udev rule that gives each
# ESP32 a stable device name.
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
#      identify one board from another by identity alone. Each side's rule therefore
#      also matches the physical port path (FM_TACTILE_USB_PORT). Keep each board in
#      its port, or set the variable to the port you use. A side installed with no
#      board plugged gets a vendor-only rule that matches ANY CH340 — fine while it is
#      the host's only glove, wrong the moment a second one arrives.
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

# Physical USB port the ESP32 lives on, as udev's KERNELS attribute (`udevadm info -a
# -n /dev/ttyUSB0 | grep KERNELS` on the host reports it). Needed because the CH340
# carries no serial number — but the right port differs per host (3-1 on the first
# tower, something else on a Jetson), so there is no baked default. Resolution order:
#   1. FM_TACTILE_USB_PORT (explicit) — always wins.
#   2. The pin this side's rule already carries, so a converge run keeps it.
#   3. Exactly one CH340 tty plugged in that no OTHER side's rule already pins — its
#      port is derived and pinned.
#   4. Nothing plugged in — the rule matches vendor/product only (fine while the
#      glove is this host's only CH340); re-run with the board in its permanent
#      port to pin it, mandatory before a second glove ever shares the host.
USB_PORT="${FM_TACTILE_USB_PORT:-}"
# CH340 (QinHeng) vendor/product — the adapter on the production glove board.
USB_VENDOR="${FM_TACTILE_USB_VENDOR:-1a86}"
USB_PRODUCT="${FM_TACTILE_USB_PRODUCT:-7523}"

# Print the KERNELS-style USB port (e.g. 3-1, 1-2.4) of every CH340 tty present:
# walk each ttyUSB device's sysfs chain up past the interface (the `:`-suffixed
# dir) to the USB device node, whose basename is exactly what KERNELS matches.
_ch340_ports() {
  local dev p base
  for dev in /dev/ttyUSB*; do
    [ -e "$dev" ] || continue
    p="$(udevadm info -q property -n "$dev" 2>/dev/null)" || continue
    grep -q "^ID_VENDOR_ID=$USB_VENDOR$" <<<"$p" || continue
    grep -q "^ID_MODEL_ID=$USB_PRODUCT$" <<<"$p" || continue
    p="$(readlink -f "/sys/class/tty/${dev#/dev/}/device")"
    while [ -n "$p" ] && [ "$p" != / ]; do
      base="$(basename "$p")"
      case "$base" in
        *:*) ;;
        [0-9]*-*) echo "$base"; break ;;
      esac
      p="$(dirname "$p")"
    done
  done
}

# Ports already pinned by the rules of every side except the one being installed.
_pinned_ports_except() {  # side
  local f
  for f in "$RULES_DIR"/99-fm-tactile-*.rules; do
    [ -e "$f" ] || continue
    [ "$f" = "$RULES_DIR/99-fm-tactile-$1.rules" ] && continue
    sed -n 's/.*KERNELS=="\([^"]*\)".*/\1/p' "$f"
  done
}

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
  FM_TACTILE_USB_PORT      physical USB port for this side's ESP32 (udev KERNELS).
                           Unset: auto-detected from a plugged-in CH340 no other
                           side pins; with none plugged, the rule matches
                           vendor/product only
  FM_TACTILE_USB_VENDOR    USB idVendor,  default 1a86 (CH340)
  FM_TACTILE_USB_PRODUCT   USB idProduct, default 7523 (CH340)

Each side publishes /glove_<side>/tactile at 40 Hz and writes a CSV audit log to
~/recordings/tactile-raw/glove_<side>. Tune it via
~/.config/fm-tactile/receiver-<side>.yaml, then: sudo systemctl restart fm-tactile@<side>.
The glove's firmware decides its side: flash usb_tactile_glove.ino for the left hand
and usb_tactile_glove_right.ino for the right — a board on the wrong side's port
streams nothing.
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
  # BindsTo/After the device unit ties each instance's lifetime to its USB link, so a
  # replug restarts it cleanly instead of leaving it spinning on a dead handle. %i is
  # the side; systemd escapes the dashes in the device unit name, hence \x2d.
  item "writing $UNIT (User=$SERVICE_USER, workspace=$ROOT) ..."
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive tactile glove receiver (%i hand, ESP32, 5-channel, 40 Hz)
After=dev-fm\x2dtactile\x2d%i.device
BindsTo=dev-fm\x2dtactile\x2d%i.device
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
WorkingDirectory=$ROOT
ExecStart=/bin/bash -lc 'source /opt/ros/humble/setup.bash && source $ROOT/install/setup.bash && source $ROOT/scripts/env/comms.sh && exec ros2 launch fm_tactile_bridge receiver.launch.py config:=$CONFIG_DIR/receiver-%i.yaml node_name:=tactile_receiver_%i'
Restart=on-failure
RestartSec=2
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
}

_write_rule() {  # side port
  local side="$1" port="$2" match_port="" rule="$RULES_DIR/99-fm-tactile-$1.rules"
  [ -n "$port" ] && match_port=", KERNELS==\"$port\""
  item "writing $rule (ESP32 ${port:+on USB port $port }-> /dev/fm-tactile-$side) ..."
  sudo tee "$rule" >/dev/null <<EOF
# First Motive tactile glove ($side hand) — stable name for the ESP32's USB-serial adapter.
#
# The CH340 on this board reports no factory USB serial number, so identity alone
# cannot tell two boards apart. The installer therefore pins the physical port the
# board is kept in when it can (a plugged-in board, or FM_TACTILE_USB_PORT); a
# rule with no KERNELS pin was written with no board present and matches any
# CH340 — fine for a single-glove host, but re-run the installer with the board
# in its permanent port before a second CH340 device ever shares this host.
# Moving the board to another port needs this rule regenerated the same way.
#
# TAG+="systemd" plus SYSTEMD_WANTS start the receiver when the board is plugged in
# after boot. BindsTo= alone only ties the unit's lifetime downwards: it stops the service
# when the device goes away, and never starts it when the device appears. Without
# this, a glove plugged in after boot leaves the unit dead on a failed device
# dependency until someone starts it by hand.
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", ATTRS{idVendor}=="$USB_VENDOR", ATTRS{idProduct}=="$USB_PRODUCT"$match_port, SYMLINK+="fm-tactile-$side", GROUP="dialout", MODE="0660", TAG+="systemd", ENV{SYSTEMD_WANTS}="fm-tactile@$side.service"
EOF
}

_write_config() {  # side
  # Template only when absent, so a re-install never clobbers a host's tuned values.
  # Owner-only: the Wi-Fi transport variant carries a token path. The /**: key lets
  # the one file serve whichever node name the unit passes.
  local side="$1" file="$CONFIG_DIR/receiver-$1.yaml"
  [ -f "$file" ] && return 0
  item "writing $file (receiver config — edit, then restart the instance) ..."
  sudo -u "$SERVICE_USER" install -d -m 0700 "$CONFIG_DIR"
  sudo -u "$SERVICE_USER" tee "$file" >/dev/null <<EOF
# fm-tactile@$side.service — receiver parameters. Edit, then: sudo systemctl restart fm-tactile@$side
/**:
  ros__parameters:
    # "serial" for the USB-tethered board; "tcp" for the Wi-Fi variant (which also
    # needs bind_address, port, and a token_file readable only by this user).
    transport: "serial"
    serial_device: "/dev/fm-tactile-$side"
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

_resolve_port() {  # side  -> echoes the port to pin, or nothing
  if [ -n "$USB_PORT" ]; then
    echo "$USB_PORT"
    return 0
  fi
  # A pin this side already holds survives a converge run with the board unplugged:
  # forgetting it would widen the rule back to any CH340 on the next update tick.
  local kept
  kept="$(sed -n 's/.*KERNELS=="\([^"]*\)".*/\1/p' "$RULES_DIR/99-fm-tactile-$1.rules" 2>/dev/null || true)"
  if [ -n "$kept" ]; then
    echo "$kept"
    return 0
  fi
  local -a found=() free=()
  local p taken
  while IFS= read -r p; do [ -n "$p" ] && found+=("$p"); done < <(_ch340_ports)
  taken="$(_pinned_ports_except "$1")"
  for p in "${found[@]+"${found[@]}"}"; do
    grep -qx "$p" <<<"$taken" || free+=("$p")
  done
  if [ "${#free[@]}" = 1 ]; then
    item "detected the $1 glove's CH340 on USB port ${free[0]} — pinning the rule to it" >&2
    echo "${free[0]}"
  elif [ "${#free[@]}" = 0 ]; then
    item "no unpinned CH340 plugged in — writing a vendor/product-only rule for $1 (no port pin)." >&2
    item "  Once the glove sits in its permanent port, re-run to pin it:" >&2
    item "  ./scripts/install/install-tactile-service.sh install $1" >&2
  else
    echo "ERROR: ${#free[@]} unpinned CH340 devices present (${free[*]}) — cannot tell which is" >&2
    echo "       the $1 glove. Re-run with the port named explicitly, e.g.:" >&2
    echo "       FM_TACTILE_USB_PORT=${free[0]} ./scripts/install/install-tactile-service.sh install $1" >&2
    return 1
  fi
}

do_install() {  # side
  local side="$1" port
  _require_linux_systemd || return 0
  if [ ! -d "$OVERLAY/ros2_ws/src/fm_tactile_bridge" ]; then
    echo "WARNING: the tactile overlay is not checked out at $OVERLAY — skipping." >&2
    echo "         Run ./install.sh --recorder first (it clones and builds it)." >&2
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

  # 1. Stable device name. Without it the board lands on whichever /dev/ttyUSB* is
  #    free at boot and the unit points at the wrong device (or a modem, or nothing).
  #    A wrong baked-in port is the known silent-glove-death trap when the host changes.
  port="$(_resolve_port "$side")"
  _write_rule "$side" "$port"

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
  # With the board unplugged the device unit does not exist, so the restart's
  # dependency job fails. That is the normal state on an appliance converge with
  # the glove off the rig; the udev rule starts the instance at plug-in.
  sudo systemctl restart "fm-tactile@$side.service" 2>/dev/null || \
    item "  /dev/fm-tactile-$side is not present — fm-tactile@$side starts when the glove is plugged in"

  cat <<EOF

fm-tactile@$side.service installed and started — it now comes up on every boot.

  status:  systemctl is-active fm-tactile@$side   |  journalctl -u fm-tactile@$side -f
  device:  ls -l /dev/fm-tactile-$side             (re-plug the ESP32 if this is missing)
  stream:  ros2 topic hz /glove_$side/tactile      (expect 38-42 Hz)
  config:  sudo nano $CONFIG_DIR/receiver-$side.yaml  (then: sudo systemctl restart fm-tactile@$side)

$(if [ -n "$port" ]; then
  echo "Keep the $side ESP32 in USB port $port — the CH340 has no serial number, so the stable"
  echo "device name depends on it. Do not open a serial monitor while the service is running."
else
  echo "No port pin yet (no board was plugged in) — once the $side glove sits in its permanent"
  echo "port, re-run 'install $side' to pin it. Do not open a serial monitor while the"
  echo "service is running."
fi)
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
