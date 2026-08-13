# Jetson Recorder Bring-Up

From a boxed Jetson Orin Nano dev kit to a recording-ready appliance the
desktop app discovers on its own: one flash, one login, one command. The
recorder role's end state has always been a screenless companion computer (see
[REALSENSE.md](REALSENSE.md)); this is that move.

## What You Need

- Jetson Orin Nano dev kit + its power supply.
- Storage: an NVMe SSD (recommended — RGB-D MCAP recording is write-heavy) or
  a 64 GB+ microSD.
- A monitor + keyboard for the first-boot wizard (removed afterwards).
- Network to the rig LAN: the dev kit's Ethernet or its Wi-Fi module, on the
  **same subnet as the operator Mac** — mDNS discovery does not cross subnets.
- A GitHub account with `first-motive` org access.
- The sensors: RealSense head camera, the two Sonix wrist cameras, the tactile
  glove (ESP32/CH340), and optionally the Livox MID-360 with a USB 3
  Ethernet adapter (it needs its own interface — see below).

## 1. Flash JetPack 6

Ubuntu 22.04 is required (it is what JetPack 6 ships), so flash JetPack 6.x:

- **microSD**: download the JetPack 6 SD-card image from NVIDIA's JetPack
  page, write it with Balena Etcher, insert, power on.
- **NVMe (recommended)**: flash from a Linux host over USB-C with NVIDIA SDK
  Manager, targeting the SSD.

In the first-boot wizard: create the appliance user, set a meaningful hostname
(e.g. `fm-jetson` — it becomes the name in the app's Settings and the `.local`
address the app dials), and join the rig LAN. Confirm the base:

```bash
lsb_release -rs        # 22.04
```

## 2. Basics + Org Auth

The role installer clones private repos and the auto-updater keeps fetching
them, so put durable credentials on the box first:

```bash
sudo apt-get update && sudo apt-get install -y git curl gh
gh auth login          # the org member account, HTTPS
gh auth setup-git      # persists the credential helper for git
```

## 3. The One-Liner

```bash
mkdir -p ~/jetson && cd ~/jetson
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh \
  | bash -s -- --recorder --service
```

On a fresh Jetson this installs everything: ROS 2 Humble itself, the camera
drivers, MediaPipe (arm64 wheels exist for the pinned version), the private
data engine and tactile overlay pinned to their newest release tags, the
targeted colcon build, and the appliance layer — `fm-recorder.service`,
`fm-tactile.service`, the release-channel auto-update timer, the mDNS advert
(release baked into its TXT records), and passwordless sudo for unattended
updates (`FM_NO_SUDOERS=1` opts out).

If the LiDAR is not wired yet, keep it off until step 6:

```bash
echo 'FM_RECORDER_LIDAR=off' | sudo tee -a /etc/fm-recorder.env
sudo systemctl restart fm-recorder
```

## 4. Plug the Sensors, Reboot

Power off. Plug the RealSense into a USB 3 port, the two wrist cameras, and
the glove's ESP32 into the port it will keep. Power on — the stack boots
armed + idle, and keeps retrying anything not yet present, so plugging after
installing is fine.

Glove check (the one sensor with a port-pinned udev rule):

```bash
ls -l /dev/fm-tactile-left
```

Missing? The installer ran before the board was plugged, so the rule has no
port pin yet. Re-run it with the board in place — it detects the CH340's port
and pins it:

```bash
cd ~/jetson/fm_ros2 && ./scripts/install/install-tactile-service.sh
```

## 5. Find It in the App

From the Mac (same network):

```bash
dns-sd -B _fm-rig._tcp local.        # lists "fm-jetson recorder"
```

Open the desktop app → Settings. The rig appears in the discovered list with
its release (e.g. `v0.1.0 · data v0.1.0 · teleop v0.1.0`). Assign it
RECORDER, then smoke-test: REC, a short take, STOP — the episode lands in
`~/recordings` on the Jetson.

On the Jetson, the service view of the same story:

```bash
systemctl status fm-recorder fm-tactile
journalctl -u fm-recorder -f
```

## 6. LiDAR (Livox MID-360)

The LiDAR (192.168.1.131) needs the host at 192.168.1.10 on a **dedicated
interface** — never add a second 192.168.1.x/24 to the live LAN NIC (the
return-path blackhole only a reboot heals). On the Jetson that dedicated
interface is a USB 3 Ethernet adapter:

```bash
nmcli con add type ethernet ifname <adapter-if> con-name fm-lidar \
  ipv4.method manual ipv4.addresses 192.168.1.10/32 \
  ipv4.routes "192.168.1.131/32" ipv4.never-default yes ipv6.method disabled
nmcli con up fm-lidar
```

The installer already built the vendor driver overlay (`~/ws_livox`), so
restore the default `FM_RECORDER_LIDAR=auto` in `/etc/fm-recorder.env` (or
delete the `off` line) and `sudo systemctl restart fm-recorder`.

## 7. Updates Ride Release Tags

The box fetches tags every ~15 minutes and moves **only when a newer `v*`
release tag exists** on the workspace or role repos — cutting a release rolls
the fleet within one tick; merged-but-untagged main never moves a box. After a
converge it rebuilds, restarts, and re-bakes the advert, so Settings shows the
new release without any manual step. A take in flight is never interrupted.

```bash
systemctl list-timers fm-update-recorder.timer
journalctl -u fm-update-recorder -n 20
```

## 8. The Two-Box Split

With the recorder now on its own device, point the processor host's
recordings-sync at it (key-auth ssh, then one env edit):

```bash
# on the processor box, as the user fm-sync runs as:
ssh-copy-id <user>@fm-jetson.local
sudo sed -i 's|^#\?FM_SYNC_SOURCE=.*|FM_SYNC_SOURCE=<user>@fm-jetson.local:~/recordings|' /etc/fm-sync.env
```

The next `fm-sync` tick pulls finalized episodes into the processor's
`~/recordings`, where the app's Process surface reads them. Finally retire the
old box's recorder role (its processor role stays):

```bash
# on the old box, in its recorder workspace:
./scripts/install/install-recorder-service.sh uninstall
./scripts/install/install-tactile-service.sh uninstall
./scripts/install/install-update-timer.sh uninstall recorder
./scripts/install/install-avahi-advert.sh uninstall recorder
```

## Troubleshooting

- **Rig missing from the app**: same subnet? `avahi-browse -art | grep fm-rig`
  on the Jetson proves the advert; guest Wi-Fi networks often block mDNS.
- **No camera**: it must sit on USB 3; `journalctl -u fm-recorder` shows the
  bring-up. The service retries forever, so late plugging is fine.
- **Wrist cameras at half rate**: dim light halves their fps — it is exposure,
  not USB bandwidth.
- **Glove silent, board healthy**: the port pin no longer matches (the cable
  moved) — re-run `install-tactile-service.sh` with the board plugged. A
  charge-only USB cable gives total silence with no kernel log at all.
- **Stream not reaching the Mac**: boot-time interface auto-detection picked
  the wrong IP — pin `FM_LAN_IP=<lan-ip>` in `/etc/fm-recorder.env`.
- **Tracker trouble on arm64**: `FM_RECORDER_TRACKER=off` keeps RGB-D + IMU
  capture while the tracker is investigated.
