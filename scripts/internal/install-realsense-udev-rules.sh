#!/usr/bin/env bash
# Install the RealSense device permissions without making every converge depend
# on GitHub. A complete existing rule is authoritative for an already-provisioned
# appliance; fresh hosts download a pinned upstream revision into a temporary file
# and only install it after the bounded retry succeeds.
set -euo pipefail

RULES_FILE="${FM_REALSENSE_UDEV_RULES_FILE:-/etc/udev/rules.d/99-realsense-libusb.rules}"
RULES_URL="https://raw.githubusercontent.com/IntelRealSense/librealsense/7c3ee3fb7c640e9f315e663907208cb56c4febfd/config/99-realsense-libusb.rules"
RULES_SHA256="${FM_REALSENSE_UDEV_RULES_SHA256:-be1e04b5d0f3505e0f15605c52074b3d7070aa76d8ef66c6b7cd49aa73634b57}"

if [ -f "$RULES_FILE" ] && \
   [ "$(sha256sum "$RULES_FILE" | cut -d' ' -f1)" = "$RULES_SHA256" ]; then
  echo "RealSense udev rules already installed — keeping $RULES_FILE"
else
  rules_tmp="$(mktemp)"
  trap 'rm -f "$rules_tmp"' EXIT
  curl --retry 4 --retry-all-errors --retry-delay 2 -fsSL \
    "$RULES_URL" -o "$rules_tmp"
  if [ "$(sha256sum "$rules_tmp" | cut -d' ' -f1)" != "$RULES_SHA256" ]; then
    echo "ERROR: downloaded RealSense udev rules failed checksum verification" >&2
    exit 1
  fi
  sudo install -m 0644 "$rules_tmp" "$RULES_FILE"
  rm -f "$rules_tmp"
  trap - EXIT
fi

sudo udevadm control --reload-rules
sudo udevadm trigger
