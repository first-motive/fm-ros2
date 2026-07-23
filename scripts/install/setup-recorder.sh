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

# 1. Camera drivers + compressed transport + build tooling (apt). usb_cam drives the
#    two USB wrist cameras (fm_data_sensors cameras.launch.py prefers it on Linux).
item "installing apt packages (RealSense + USB camera drivers, compressed transport, colcon, rosdep) ..."
sudo apt-get update -qq
sudo apt-get install -y \
  ros-humble-realsense2-camera ros-humble-usb-cam \
  ros-humble-compressed-image-transport \
  ros-humble-rosbag2-storage-mcap v4l-utils \
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
# MediaPipe pulls numpy 2.x, but the system matplotlib (a MediaPipe import dep) is built for
# numpy 1.x ("_ARRAY_API not found" / "numpy.core.multiarray failed to import"). Pin numpy < 2.
pip3 install --user "numpy<2"
bash src/fm_teleop/fm_teleop_vision/scripts/download_model.sh

# 4. Data engine — clone the private data-engine repo (the recorder + sensors live there)
#    into src/fm_data if absent. Needs first-motive org access (gh auth login, or an SSH
#    key). The repo slug is held base64-encoded so the public tree does not name it
#    (repo-hygiene scan).
if [ ! -d src/fm_data/.git ]; then
  _data_repo="$(printf '%s' 'Zm0tZGF0YQ==' | base64 -d)"
  item "cloning the private data engine (needs first-motive org access) ..."
  git clone --depth 1 "https://github.com/first-motive/${_data_repo}.git" src/fm_data || {
    echo "ERROR: could not clone the private data engine (the recorder lives there). Ensure" >&2
    echo "       git can reach the private first-motive org (gh auth login, or an SSH key)," >&2
    echo "       then re-run." >&2
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
# colcon --symlink-install builds ament_python via `setup.py develop --editable`; the pip installs
# above can pull a too-new user setuptools that dropped that flag ("option --editable not
# recognized"). Pin the Humble-compatible setuptools (Ubuntu 22.04's system version).
item "pinning setuptools for the colcon ament_python build ..."
pip3 install --user "setuptools==59.6.0" 2>/dev/null || pip3 install --user "setuptools<64"
# The fm_data checkout has a top-level metapackage package.xml, so colcon's recursive discovery
# stops there and never sees the nested fm_data_record / fm_data_sensors. List their dirs
# explicitly as base-paths (mirrors the data engine's own README), alongside src/fm_teleop for
# the tracker + its deps.
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

# 6. Boot service (opt-in via install.sh --recorder --service -> FM_INSTALL_SERVICE=1).
#    Installs a systemd unit so this host comes up as a headless recorder appliance:
#    camera + tracker + recorder (armed, idle) + foxglove bridge on boot, driven
#    remotely from a Mac. A plain --recorder just builds; the appliance is opt-in.
if [ "${FM_INSTALL_SERVICE:-0}" = 1 ]; then
  item "installing the recorder boot service (fm-recorder.service) ..."
  ./scripts/install/install-recorder-service.sh
  # An appliance keeps itself current: fetch every ~15 min, converge on merged
  # updates (a take in flight is never interrupted; see appliance-update.sh).
  item "installing the auto-update timer (fm-update-recorder.timer) ..."
  ./scripts/install/install-update-timer.sh recorder
else
  item "boot service not installed — add it anytime with:"
  item "  ./scripts/install/install-recorder-service.sh   (or reinstall with --service)"
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
  # Bags land under ~/recordings (output_dir in egocentric_head.yaml); fm_data_package ships them onward.

  # Installed the boot service (--service)? Then the stack above already runs on boot —
  # just drive REC/STOP from a Mac and watch the service:
  #   open src/fm_app/fm_viewer/webgui/index.html?ws=ws://<this-host-ip>:8765
  #   systemctl status fm-recorder    |    journalctl -u fm-recorder -f
EOF
