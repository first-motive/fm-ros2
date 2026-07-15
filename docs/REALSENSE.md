# RealSense D435i — Linux camera host

The D435i egocentric camera runs on a Linux machine (Ubuntu 22.04 + ROS 2 Humble).
macOS can't drive it, so the Mac consumes the stream over ROS 2 instead.

## Install (once)

```bash
# driver + SDK
sudo apt install -y ros-humble-realsense2-camera

# compressed image transports (small bags, network streaming)
sudo apt install -y ros-humble-compressed-image-transport ros-humble-compressed-depth-image-transport

# udev rules — required for the IMU
sudo curl -fsSL https://raw.githubusercontent.com/IntelRealSense/librealsense/master/config/99-realsense-libusb.rules \
  -o /etc/udev/rules.d/99-realsense-libusb.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

After the udev rules, **unplug and replug** the camera. Plug it into a **USB3** port — a passive
extension throttles it to USB2; use an active USB3 extension if you need reach.

## Turn on the camera

```bash
source /opt/ros/humble/setup.bash
ros2 launch realsense2_camera rs_launch.py camera_name:=head_cam \
  align_depth.enable:=true enable_gyro:=true enable_accel:=true unite_imu_method:=2
```

Streams publish under `/camera/head_cam/*` (color, aligned depth, IMU).

## Verify

```bash
timeout 6 ros2 topic hz /camera/head_cam/color/image_raw   # ~30 Hz color
timeout 6 ros2 topic hz /camera/head_cam/imu               # ~200 Hz IMU
```

## Record

```bash
ros2 bag record -o ~/episodes/$(date +%F_%H%M%S) \
  /camera/head_cam/color/image_raw/compressed \
  /camera/head_cam/color/camera_info \
  /camera/head_cam/aligned_depth_to_color/image_raw \
  /camera/head_cam/imu
# verify depth captured (Count > 0): ros2 bag info ~/episodes/<dir>
```

Color records **compressed** (small); depth records **raw** — `compressedDepth` delivers no
frames, so don't use it. Raw depth is ~24 MB/s, fine for short episodes on local disk.

**Record RGB-D episodes here, on the Linux machine** (depth is local + full-rate). Depth does not
stream well over the network — record it where the camera is, then `rsync` bags to the Mac.

## Stream to the Mac

The Mac consumes over ROS 2 DDS — no librealsense on the Mac. Both machines: same LAN, same
`ROS_DOMAIN_ID`, default FastDDS.

Multiple NICs (Docker bridges on the Mac, Tailscale on Linux) break DDS delivery — discovery
works but no data arrives, because FastDDS announces unreachable addresses. Fix: pin FastDDS to
the LAN interface on **both** machines. `scripts/run/dds-lan.sh` does this — it auto-detects the
LAN IP, writes a FastDDS whitelist profile, and exports the env. **Source it in every ROS
terminal on both machines** (Linux: before `ros2 launch`; Mac: inside `pixi shell`):

```bash
source scripts/run/dds-lan.sh     # or: FM_LAN_IP=192.168.1.x source scripts/run/dds-lan.sh
```

To make it automatic, add that line to `~/.bashrc` (Linux) / your pixi shell init (Mac).

Verify on the Mac (native pixi, **not** the container — its NAT can't reach the LAN):

```bash
ros2 topic list | grep head_cam
ros2 topic echo --once --qos-reliability best_effort --field format /camera/head_cam/color/image_raw/compressed
```

Compressed **color + IMU** stream to the Mac cleanly. **Depth does not** — record it on the Linux
machine (above) and sync the bags.
