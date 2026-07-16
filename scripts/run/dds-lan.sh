#!/usr/bin/env bash
# dds-lan.sh — pin FastDDS to the LAN interface so ROS 2 works across the
# Mac <-> Linux camera link.
#
# Why: both machines have extra network interfaces (Docker/OrbStack bridges on the
# Mac, Tailscale + IPv6 on Linux). FastDDS announces ALL of them as locators, so a
# remote peer tries to deliver data to an unreachable address — discovery succeeds
# but no data ever arrives. Restricting FastDDS to the real LAN interface fixes it.
#
# Usage — SOURCE this in every ROS terminal on BOTH machines (before ros2 ...):
#     source scripts/run/dds-lan.sh
# Override auto-detection if it picks the wrong IP:
#     FM_LAN_IP=192.168.1.42 source scripts/run/dds-lan.sh

_fm_lan_ip() {
  if [ -n "${FM_LAN_IP:-}" ]; then echo "$FM_LAN_IP"; return; fi
  if [ "$(uname)" = "Darwin" ]; then
    local i ip
    for i in en0 en1 en2; do
      ip=$(ipconfig getifaddr "$i" 2>/dev/null) && [ -n "$ip" ] && { echo "$ip"; return; }
    done
  else
    # Prefer a private-LAN address; skip Tailscale (100.64/10) and Docker (172.17).
    local pat ip
    for pat in '^192\.168\.' '^10\.' '^172\.(1[6-9]|2[0-9]|3[01])\.'; do
      ip=$(hostname -I | tr ' ' '\n' | grep -E "$pat" | grep -vE '^(100\.|172\.17\.)' | head -1)
      [ -n "$ip" ] && { echo "$ip"; return; }
    done
  fi
}

_fm_ip="$(_fm_lan_ip)"
if [ -z "$_fm_ip" ]; then
  echo "dds-lan: could not detect a LAN IP — set FM_LAN_IP=<ip> and re-source." >&2
else
  mkdir -p "$HOME/.ros"
  _fm_prof="$HOME/.ros/fm_fastdds_lan.xml"
  cat > "$_fm_prof" <<XML
<?xml version="1.0" encoding="UTF-8" ?>
<dds xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
  <profiles>
    <transport_descriptors>
      <transport_descriptor>
        <transport_id>lan_only</transport_id>
        <type>UDPv4</type>
        <!-- ${_fm_ip}: cross-host (Mac <-> rig). 127.0.0.1: same-host best_effort
             delivery, which the single-NIC whitelist otherwise drops (camera ->
             tracker -> recorder on the rig; sim <-> mirror_source on the Mac). -->
        <interfaceWhiteList><address>${_fm_ip}</address><address>127.0.0.1</address></interfaceWhiteList>
      </transport_descriptor>
    </transport_descriptors>
    <participant profile_name="default_participant" is_default_profile="true">
      <rtps>
        <userTransports><transport_id>lan_only</transport_id></userTransports>
        <useBuiltinTransports>false</useBuiltinTransports>
      </rtps>
    </participant>
  </profiles>
</dds>
XML
  export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
  export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
  export FASTRTPS_DEFAULT_PROFILES_FILE="$_fm_prof"
  echo "dds-lan: FastDDS pinned to ${_fm_ip} (domain ${ROS_DOMAIN_ID})"
fi
unset _fm_ip _fm_prof
