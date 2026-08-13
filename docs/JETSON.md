# Jetson Recorder Bring-Up

From a boxed Jetson Orin Nano dev kit to a recording-ready appliance the
desktop app discovers on its own — flashed from a Mac, headless from the first
SSH login. The recorder role's end state has always been a screenless companion
computer (see [REALSENSE.md](REALSENSE.md)); this is that move.

Two layers, two repos, in order:

| layer | repo | installs |
| --- | --- | --- |
| machine | [`fm-setup`](https://github.com/first-motive/fm-setup) | ROS 2 Humble, sensor udev permissions, DDS kernel buffers, Tailscale |
| appliance | this repo | the recorder workspace, its services, auto-update, the mDNS advert |

The host runs **Ubuntu Server 22.04** (Canonical's Jetson image), not JetPack.
JetPack is also 22.04 and works, but it carries a desktop and NVIDIA's
multimedia stack this rig never uses — every sensor here is USB or Ethernet,
and the appliance has no screen.

## What You Need

- Jetson Orin Nano dev kit + its power supply.
- Storage: a 64 GB+ microSD (V30/A2 or better — RGB-D MCAP recording is
  write-heavy). An NVMe SSD is the eventual home; the SD is fine to start.
- A Mac (or any machine) to flash the SD, with balenaEtcher or Raspberry Pi
  Imager.
- A monitor + keyboard for roughly five minutes of first boot. Everything after
  is SSH.
- Network to the rig LAN: Ethernet, on the **same subnet as the operator Mac**
  — mDNS discovery does not cross subnets.
- A GitHub account with `first-motive` org access.
- The sensors: RealSense head camera, the two Sonix wrist cameras, the tactile
  glove (ESP32/CH340), and optionally the Livox MID-360 with a USB 3 Ethernet
  adapter (it needs its own interface — see below).

## 1. Flash Ubuntu Server From the Mac

Download Canonical's Jetson image:

```bash
curl -fLO https://cdimage.ubuntu.com/releases/jammy/release/nvidia-tegra/ubuntu-22.04-preinstalled-server-arm64+tegra-jetson.img.xz
```

Write it to the microSD with **balenaEtcher** (point it at the `.img.xz`
directly) or **Raspberry Pi Imager** (Choose OS → Use custom). From a terminal
instead:

```bash
# diskutil list          — find the SD card's disk number first. This command
# overwrites that disk entirely; a wrong number destroys the wrong disk.
xzcat ubuntu-22.04-preinstalled-server-arm64+tegra-jetson.img.xz \
  | sudo dd of=/dev/rdiskN bs=16m status=progress
```

### Firmware, Once

Canonical's image needs the JetPack-6-era UEFI firmware (L4T r36.x). The boot
splash shows the version top-left for a few seconds.

- **Orin Nano Super dev kits** (anything bought recently) ship with it — skip
  ahead.
- **36.x already on the module** — skip ahead.
- **Older (35.x)**: write NVIDIA's JetPack 6 SD image to a card, boot it once,
  and let it update the firmware (it reboots itself when done). Then swap in
  the Ubuntu Server card.
- **Ancient (pre-35, kits from before 2024)**: boot a JetPack 5.1.3 SD card
  first to reach 35.x, then the JetPack 6 step above. Two boots, one-time.

With a Linux x86 host instead (the GPU PC, before its wipe), NVIDIA's L4T
tools can flash the firmware directly over USB-C recovery — faster if the
machines share a desk.

## 2. First Boot — the Five Attended Minutes

Insert the SD, connect monitor, keyboard, and Ethernet, and power on. Log in as
`ubuntu` / `ubuntu`; the system forces a password change. Then:

```bash
sudo hostnamectl set-hostname fm-jetson   # the name the app discovers and dials
ip -brief addr                            # confirm the LAN lease; note the IP
```

The monitor's job is done. SSH in from the Mac and unplug it:

```bash
ssh ubuntu@<the-ip>        # or ubuntu@fm-jetson.local once avahi is up (step 4)
```

## 3. Machine Layer — fm-setup

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.5/install.sh \
  | bash -s -- --jetson --skip docker
```

This installs ROS 2 Humble, the sensor udev permission rules, the CycloneDDS
kernel receive buffers, and Tailscale, and clones fm-setup to
`~/.first-motive/fm-setup` so the machine can re-check itself later
(`./install.sh --check`). `--skip docker` keeps the SD lean — the recorder runs
native; drop the flag when the box moves to an SSD and containers become
interesting.

When the Tailscale step prompts, authenticate — that is the remote-admin path
once the box lives on the rig:

```bash
sudo tailscale up --ssh
```

The rule from here on: no system-level change outside an fm-setup step or one
of this repo's installers. `apt install` typed into a terminal is invisible to
the next rebuild.

## 4. Org Auth

The role installer clones private repos and the auto-updater keeps fetching
them, so put durable credentials on the box:

```bash
sudo apt-get install -y gh
gh auth login          # the org member account, HTTPS
gh auth setup-git      # persists the credential helper for git
```

## 5. The One-Liner

From the home directory — the workspace lands at `~/fm_ros2`, the same place it
lives on every other First Motive machine, so the `fm` CLI's workspace
detection holds here too:

```bash
cd ~
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-ros2/main/install.sh \
  | bash -s -- --recorder --service
```

On a machine provisioned by step 3 this skips its own ROS bootstrap (Humble is
already at `/opt/ros/humble`) and installs the rest: the camera drivers,
MediaPipe (arm64 wheels exist for the pinned version), the private data engine
and tactile overlay pinned to their newest release tags, the targeted colcon
build, and the appliance layer — `fm-recorder.service`, `fm-tactile.service`,
the release-channel auto-update timer, the mDNS advert (release baked into its
TXT records), and passwordless sudo for unattended updates (`FM_NO_SUDOERS=1`
opts out).

If the LiDAR is not wired yet, keep it off until step 8:

```bash
echo 'FM_RECORDER_LIDAR=off' | sudo tee -a /etc/fm-recorder.env
sudo systemctl restart fm-recorder
```

## 6. Plug the Sensors, Reboot

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
cd ~/fm_ros2 && ./scripts/install/install-tactile-service.sh
```

(fm-setup's generic sensor rules grant device permissions only; this installer
owns the stable `/dev/fm-tactile-*` names.)

## 7. Find It in the App

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

### SD Card Housekeeping

Episodes are large and the card is 64 GB. `df -h ~` before a session; the
two-box sync (step 10) is what drains the card — once episodes land on the
processor they can be deleted here. Move to an NVMe SSD when recording becomes
routine.

## 8. LiDAR (Livox MID-360)

The LiDAR (192.168.1.131) needs the host at 192.168.1.10 on a **dedicated
interface** — never add a second 192.168.1.x/24 to the live LAN NIC (the
return-path blackhole only a reboot heals). On the Jetson that dedicated
interface is a USB 3 Ethernet adapter, configured through fm-setup's netplan
verb (Ubuntu Server has no NetworkManager, so `nmcli` recipes do not apply
here):

```bash
cd ~/.first-motive/fm-setup
./run.sh lidar-net <adapter-if>       # ip -brief link lists the candidates
ping -c2 192.168.1.131
```

The installer already built the vendor driver overlay (`~/ws_livox`), so
restore the default `FM_RECORDER_LIDAR=auto` in `/etc/fm-recorder.env` (or
delete the `off` line) and `sudo systemctl restart fm-recorder`.

## 9. Updates Ride Release Tags

The box fetches tags every ~15 minutes and moves **only when a newer `v*`
release tag exists** on the workspace or role repos — cutting a release rolls
the fleet within one tick; merged-but-untagged main never moves a box. After a
converge it rebuilds, restarts, and re-bakes the advert, so Settings shows the
new release without any manual step. A take in flight is never interrupted.

```bash
systemctl list-timers fm-update-recorder.timer
journalctl -u fm-update-recorder -n 20
```

## 10. The Two-Box Split

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
- **Recording stutters on the SD card**: the card is the bottleneck — check
  its class (V30/A2 minimum), and plan the NVMe move.
