#!/usr/bin/env bash
# setup-recorder.sh — provision a native Linux host (Ubuntu 22.04 + ROS 2 Humble) as the First
# Motive "recorder": it drives the RealSense depth camera, runs the hand tracker (with metric
# depth Z), records RGB-D episodes locally, and streams the small results to any Mac over DDS.
#
# The camera stays on this machine; laptops consume the stream. macOS cannot drive the RealSense
# (see docs/REALSENSE.md), so this native-Linux role is where the camera lives.
#
# Invoked by:  ./install.sh --recorder   (or run standalone from a checkout).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/lib.sh"          # item(), spin()
cd "$ROOT"

MEDIAPIPE_VERSION="0.10.14"

# 0. Require ROS 2 Humble — installing ROS itself is out of scope (distro-specific, heavy).
if [ ! -f /opt/ros/humble/setup.bash ]; then
  echo "ERROR: ROS 2 Humble not found at /opt/ros/humble." >&2
  echo "       Install it first: https://docs.ros.org/en/humble/Installation.html" >&2
  exit 1
fi
# ROS setup scripts reference unset AMENT_* vars, which `set -u` treats as an error — drop
# nounset just around the source, then restore it.
# shellcheck disable=SC1091
set +u; source /opt/ros/humble/setup.bash; set -u

# 1. Camera driver + compressed transport + build tooling (apt).
item "installing apt packages (RealSense driver, compressed transport, colcon, rosdep) ..."
sudo apt-get update -qq
sudo apt-get install -y \
  ros-humble-realsense2-camera ros-humble-compressed-image-transport \
  ros-humble-rosbag2-storage-mcap \
  python3-colcon-common-extensions python3-vcstool python3-rosdep python3-pip \
  python3-opencv git curl

# 2. RealSense udev rules — required for the IMU (else it fails with Permission denied) and for
#    non-root device access. Re-plug the camera after this.
item "installing RealSense udev rules (re-plug the camera afterwards) ..."
sudo curl -fsSL \
  https://raw.githubusercontent.com/IntelRealSense/librealsense/master/config/99-realsense-libusb.rules \
  -o /etc/udev/rules.d/99-realsense-libusb.rules
sudo udevadm control --reload-rules && sudo udevadm trigger

# 3. MediaPipe + hand model (the tracker's perception). Download the model BEFORE the build so it
#    is installed into the package share dir.
item "installing MediaPipe==$MEDIAPIPE_VERSION + downloading the hand model ..."
pip3 install --user "mediapipe==$MEDIAPIPE_VERSION"
bash src/fm_teleop/fm_teleop_vision/scripts/download_model.sh

# 4. Data engine — clone the private fm-data (the recorder + sensors live there) if absent.
#    Needs first-motive org access (gh auth login, or an SSH key).
if [ ! -d src/fm_data/.git ]; then
  item "cloning fm-data (private data engine — needs first-motive org access) ..."
  git clone --depth 1 https://github.com/first-motive/fm-data.git src/fm_data || {
    echo "ERROR: could not clone fm-data (the recorder lives there). Ensure git can reach the" >&2
    echo "       private first-motive org (gh auth login, or an SSH key), then re-run." >&2
    exit 1
  }
fi

# 5. Build the tracker + the recorder/sensors only — no sim / robot-control / MoveIt / dataset
#    engine. rosdep resolves system deps; failures there are non-fatal (the apt deps above cover
#    the core path), so the build still proceeds.
item "resolving deps + building tracker + recorder (fm_teleop_vision, fm_data_record, fm_data_sensors) ..."
sudo rosdep init 2>/dev/null || true
rosdep update 2>/dev/null || true
rosdep install --from-paths src/fm_teleop src/fm_data/fm_data_record src/fm_data/fm_data_sensors \
  --ignore-src -y --rosdistro humble 2>/dev/null || \
  item "rosdep install skipped/partial — continuing (apt deps above cover the core path)"
# fm-data has a top-level metapackage package.xml, so colcon's recursive discovery stops there and
# never sees the nested fm_data_record / fm_data_sensors. List their dirs explicitly as base-paths
# (mirrors fm-data's own README), alongside src/fm_teleop for the tracker + its deps.
colcon build --symlink-install \
  --base-paths src/fm_teleop src/fm_data/fm_data_record src/fm_data/fm_data_sensors \
  --packages-up-to fm_teleop_vision fm_data_record fm_data_sensors

# 4b. --symlink-install can leave the model files in the package share dir as dangling symlinks;
#     copy the real .task files in so hand_tracker (which resolves them from share) finds them.
_share_models="install/fm_teleop_vision/share/fm_teleop_vision/models"
if [ -d "$_share_models" ]; then
  cp -f src/fm_teleop/fm_teleop_vision/models/*.task "$_share_models"/ 2>/dev/null || true
fi

# 5. DDS LAN networking — pin FastDDS to the LAN interface so a Mac actually receives the stream
#    (extra NICs otherwise break delivery). Auto-source it in every shell.
item "wiring DDS LAN networking into ~/.bashrc ..."
if ! grep -q 'scripts/run/dds-lan.sh' "$HOME/.bashrc" 2>/dev/null; then
  {
    echo ""
    echo "# fm_ros2 recorder: pin DDS to the LAN so laptops receive the camera stream"
    echo "source \"$ROOT/scripts/run/dds-lan.sh\""
  } >> "$HOME/.bashrc"
fi

item "recorder provisioned at $ROOT"
cat <<EOF

Next — plug the RealSense into a USB3 port, open a NEW terminal, then:

  source /opt/ros/humble/setup.bash
  source "$ROOT/install/setup.bash"          # the built tracker + recorder
  source "$ROOT/scripts/run/dds-lan.sh"      # DDS on the LAN (auto in new shells via ~/.bashrc)

  # Camera (/head RealSense) + hand tracker (metric depth Z) + recorder — one command:
  ros2 launch fm_data_record egocentric_record.launch.py
  #   camera-only (no tracker):  ros2 launch fm_data_record egocentric_record.launch.py tracker:=off

  # Record an episode — the recorder is marker-bounded (MCAP). Start / stop a take with:
  ros2 topic pub --once /fm_data_record/episode_marker std_msgs/msg/String "data: '{\\"event\\": \\"start\\"}'"
  #   ... do the task ...
  ros2 topic pub --once /fm_data_record/episode_marker std_msgs/msg/String "data: '{\\"event\\": \\"end\\"}'"
  # Bags land under ./recordings (output_dir in egocentric_head.yaml); fm_data_package ships them onward.
EOF
