#!/usr/bin/env bash
# install-tactile-service.sh — install (or remove) the systemd unit that runs the
# five-channel tactile-glove receiver, plus the udev rule that gives its ESP32 a
# stable device name.
#
# The glove is an ESP32 reading five FSRs, tethered to the recorder host by USB. The
# receiver (fm_tactile_bridge) owns that serial port exclusively: it maps the board's
# monotonic clock onto the tower clock, publishes /glove_left/tactile at 40 Hz, and
# writes an independent CSV audit log under ~/recordings/tactile-raw. It runs as its
# own unit rather than inside the recorder launch, so the glove keeps streaming (and
# keeps its clock fit warm) while the recorder sits idle between takes.
#
# Three things here are not obvious and are load-bearing:
#
#   1. The CH340 USB-serial adapter reports no factory serial number, so udev cannot
#      identify one board from another by identity alone. The rule therefore also
#      matches the physical port path (FM_TACTILE_USB_PORT). Keep the board in that
#      port, or set the variable to the port you use.
#   2. brltty claims any CH340 as a Braille display before a serial reader can open
#      it. Its udev unit is masked here. The brltty package itself is left installed.
#   3. Nothing else may hold the port. An Arduino Serial Monitor or a stray `screen`
#      will take it and the service will restart-loop.
#
# Linux + systemd only, best-effort (warns + returns 0 elsewhere), idempotent. Invoked
# by setup-recorder.sh when install.sh got --service; runnable standalone.
#
# Usage:
#   ./scripts/install/install-tactile-service.sh            # install + enable + start
#   ./scripts/install/install-tactile-service.sh uninstall  # stop + disable + remove
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib.sh"          # item()
cd "$ROOT"

UNIT=/etc/systemd/system/fm-tactile.service
UDEV_RULE=/etc/udev/rules.d/99-fm-tactile-left.rules
DEVICE_LINK=/dev/fm-tactile-left
OVERLAY="$ROOT/src/external/fm_tactile"

# Physical USB port the ESP32 lives on, as udev's KERNELS attribute (`udevadm info -a
# -n /dev/ttyUSB0 | grep KERNELS` on the host reports it). Needed because the CH340
# carries no serial number — but the right port differs per host (3-1 on the first
# tower, something else on a Jetson), so there is no baked default. Resolution order:
#   1. FM_TACTILE_USB_PORT (explicit) — always wins.
#   2. Exactly one CH340 tty plugged in right now — its port is derived and pinned.
#   3. Nothing plugged in — the rule matches vendor/product only (fine while the
#      glove is this host's only CH340); re-run with the board in its permanent
#      port to pin it, mandatory before a second CH340 device ever shares the host.
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

# Run the service as the human who installed it, not root — the audit CSVs land beside
# the recorder's bags in that user's ~/recordings, and dialout group access is theirs.
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$SERVICE_HOME" ] || SERVICE_HOME="$HOME"
CONFIG_DIR="$SERVICE_HOME/.config/fm-tactile"
CONFIG_FILE="$CONFIG_DIR/receiver.yaml"

usage() {
  cat <<'EOF'
install-tactile-service.sh — install/remove the fm-tactile glove receiver (Linux)

  (no args)    write the udev rule + unit, enable for boot, start now
  uninstall    stop + disable + remove the unit, the udev rule, and the config
  -h, --help   show this help

Environment:
  FM_TACTILE_USB_PORT      physical USB port for the ESP32 (udev KERNELS). Unset:
                           auto-detected from a plugged-in CH340; with none
                           plugged, the rule matches vendor/product only
  FM_TACTILE_USB_VENDOR    USB idVendor,  default 1a86 (CH340)
  FM_TACTILE_USB_PRODUCT   USB idProduct, default 7523 (CH340)

The service publishes /glove_left/tactile at 40 Hz and writes a CSV audit log to
~/recordings/tactile-raw. Tune it via ~/.config/fm-tactile/receiver.yaml, then:
sudo systemctl restart fm-tactile.
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

do_install() {
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

  # 1. Stable device name. Without it the board lands on whichever /dev/ttyUSB* is
  #    free at boot and the unit points at the wrong device (or a modem, or nothing).
  #    Resolve the port pin per the order documented at USB_PORT above — a wrong
  #    baked-in port is the known silent-glove-death trap when the host changes.
  if [ -z "$USB_PORT" ]; then
    local -a found=()
    while IFS= read -r _p; do [ -n "$_p" ] && found+=("$_p"); done < <(_ch340_ports)
    if [ "${#found[@]}" = 1 ]; then
      USB_PORT="${found[0]}"
      item "detected the glove's CH340 on USB port $USB_PORT — pinning the rule to it"
    elif [ "${#found[@]}" = 0 ]; then
      item "no CH340 plugged in — writing a vendor/product-only rule (no port pin)."
      item "  Once the glove sits in its permanent port, re-run this script to pin it:"
      item "  ./scripts/install/install-tactile-service.sh"
    else
      echo "ERROR: ${#found[@]} CH340 devices present (${found[*]}) — cannot tell which is" >&2
      echo "       the glove. Re-run with the port named explicitly, e.g.:" >&2
      echo "       FM_TACTILE_USB_PORT=${found[0]} ./scripts/install/install-tactile-service.sh" >&2
      return 1
    fi
  fi
  local match_port=""
  [ -n "$USB_PORT" ] && match_port=", KERNELS==\"$USB_PORT\""
  item "writing $UDEV_RULE (ESP32 ${USB_PORT:+on USB port $USB_PORT }-> $DEVICE_LINK) ..."
  sudo tee "$UDEV_RULE" >/dev/null <<EOF
# First Motive tactile glove — stable name for the ESP32's USB-serial adapter.
#
# The CH340 on this board reports no factory USB serial number, so identity alone
# cannot tell two boards apart. The installer therefore pins the physical port the
# board is kept in when it can (a plugged-in board, or FM_TACTILE_USB_PORT); a
# rule with no KERNELS pin was written with no board present and matches any
# CH340 — fine for a single-glove host, but re-run the installer with the board
# in its permanent port before a second CH340 device ever shares this host.
# Moving the board to another port needs this rule regenerated the same way.
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", ATTRS{idVendor}=="$USB_VENDOR", ATTRS{idProduct}=="$USB_PRODUCT"$match_port, SYMLINK+="${DEVICE_LINK#/dev/}", GROUP="dialout", MODE="0660"
EOF

  # 2. brltty grabs any CH340 as a Braille display within a second of plug-in, before
  #    the receiver can open the port. Masking its udev unit is the documented fix and
  #    is reversible: sudo systemctl unmask --now brltty-udev.service
  if systemctl list-unit-files brltty-udev.service >/dev/null 2>&1; then
    item "masking brltty-udev.service (it claims the CH340 before the receiver can) ..."
    sudo systemctl mask --now brltty-udev.service 2>/dev/null || true
  fi

  sudo udevadm control --reload-rules && sudo udevadm trigger

  # 3. Receiver config — template only when absent, so a re-install never clobbers a
  #    host's tuned values. Owner-only: the Wi-Fi transport variant carries a token path.
  if [ ! -f "$CONFIG_FILE" ]; then
    item "writing $CONFIG_FILE (receiver config — edit, then restart the service) ..."
    sudo -u "$SERVICE_USER" install -d -m 0700 "$CONFIG_DIR"
    sudo -u "$SERVICE_USER" tee "$CONFIG_FILE" >/dev/null <<EOF
# fm-tactile.service — receiver parameters. Edit, then: sudo systemctl restart fm-tactile
tactile_receiver:
  ros__parameters:
    # "serial" for the USB-tethered board; "tcp" for the Wi-Fi variant (which also
    # needs bind_address, port, and a token_file readable only by this user).
    transport: "serial"
    serial_device: "$DEVICE_LINK"
    serial_baud: 115200
    device_id: "glove_left"
    topic: "/glove_left/tactile"
    # Audit CSVs land beside the recorder's bags. The path must stay exactly
    # <recordings>/tactile-raw: appliance-update.sh prunes that one directory from its
    # busy check, and a nested path would block every auto-update tick instead.
    audit_output_dir: "$SERVICE_HOME/recordings/tactile-raw"
    recorder_status_topic: "/fm_data_record/recorder_status"
    # time_synchronized is reported true only below this clock-fit uncertainty.
    max_sync_uncertainty_ms: 10.0
    ack_interval_frames: 8
    sensor_names: ["S1", "S2", "S3", "S4", "S5"]
EOF
    sudo chmod 0600 "$CONFIG_FILE"
    sudo chown "$SERVICE_USER" "$CONFIG_FILE"
  fi

  # 4. The unit. BindsTo/After the device unit ties its lifetime to the USB link, so a
  #    replug restarts it cleanly instead of leaving it spinning on a dead handle.
  item "writing $UNIT (User=$SERVICE_USER, workspace=$ROOT) ..."
  sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=First Motive tactile glove receiver (ESP32, 5-channel, 40 Hz)
After=dev-fm\x2dtactile\x2dleft.device
BindsTo=dev-fm\x2dtactile\x2dleft.device
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=HOME=$SERVICE_HOME
WorkingDirectory=$ROOT
ExecStart=/bin/bash -lc 'source /opt/ros/humble/setup.bash && source $ROOT/install/setup.bash && source $ROOT/scripts/env/dds-lan.sh && exec ros2 launch fm_tactile_bridge receiver.launch.py config:=$CONFIG_FILE'
Restart=on-failure
RestartSec=2
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

  item "enabling + starting fm-tactile.service ..."
  sudo systemctl daemon-reload
  sudo systemctl enable fm-tactile.service
  sudo systemctl restart fm-tactile.service

  cat <<EOF

fm-tactile.service installed and started — it now comes up on every boot.

  status:  systemctl is-active fm-tactile     |  journalctl -u fm-tactile -f
  device:  ls -l $DEVICE_LINK                  (re-plug the ESP32 if this is missing)
  stream:  ros2 topic hz /glove_left/tactile   (expect 38-42 Hz)
  config:  sudo nano $CONFIG_FILE  (then: sudo systemctl restart fm-tactile)

$(if [ -n "$USB_PORT" ]; then
  echo "Keep the ESP32 in USB port $USB_PORT — the CH340 has no serial number, so the stable"
  echo "device name depends on it. Do not open a serial monitor while the service is running."
else
  echo "No port pin yet (no board was plugged in) — once the glove sits in its permanent"
  echo "port, re-run this script to pin it. Do not open a serial monitor while the"
  echo "service is running."
fi)
EOF
}

do_uninstall() {
  _require_linux_systemd || return 0
  item "stopping + disabling fm-tactile.service (if present) ..."
  sudo systemctl disable --now fm-tactile.service 2>/dev/null || true
  sudo rm -f "$UNIT" "$UDEV_RULE"
  sudo systemctl daemon-reload 2>/dev/null || true
  sudo udevadm control --reload-rules 2>/dev/null || true
  # brltty stays masked: unmasking it would re-break any other CH340 device on the
  # host, and the operator can undo it deliberately if they need Braille support.
  item "fm-tactile.service removed (brltty-udev stays masked; unmask it manually if needed)."
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    uninstall) do_uninstall ;;
    ""|install) do_install ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; return 1 ;;
  esac
}

main "$@"
