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
# shellcheck disable=SC1091
. "$ROOT/scripts/env/bridge.sh"
cd "$ROOT"

MEDIAPIPE_VERSION="0.10.14"
# Pinned ref for the tactile-glove overlay (fm_tactile_msgs + fm_tactile_bridge).
# Override with FM_TACTILE_REF to test a branch before it is tagged.
TACTILE_REF="${FM_TACTILE_REF:-v0.1.0}"
# Snake-case checkout dir, matching src/fm_data and the external/ vendored sources:
# the kebab repo slug is private and is never written into the tree in plaintext.
TACTILE_DIR="src/external/fm_tactile"

# 0. ROS 2 Humble. A fresh appliance host (a Jetson just flashed with Canonical's
#    preinstalled Ubuntu 22.04 tegra image — see docs/JETSON.md) arrives without
#    it, so install it here when the host is Ubuntu 22.04, the one distro Humble
#    binaries target. Any other host keeps the hard requirement: picking a ROS
#    build for arbitrary distros stays out of scope.
if [ ! -f /opt/ros/humble/setup.bash ]; then
  _os_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
  _os_ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
  if [ "$_os_id" = ubuntu ] && [ "$_os_ver" = 22.04 ]; then
    item "installing ROS 2 Humble (ros-base + dev tools) ..."
    sudo apt-get update -qq
    sudo apt-get install -y software-properties-common curl
    sudo add-apt-repository -y universe >/dev/null
    sudo curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
      -o /usr/share/keyrings/ros-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu jammy main" \
      | sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y ros-humble-ros-base ros-dev-tools
  else
    echo "ERROR: ROS 2 Humble not found at /opt/ros/humble, and this host is not" >&2
    echo "       Ubuntu 22.04 (the one distro its binaries target). Install it first:" >&2
    echo "       https://docs.ros.org/en/humble/Installation.html" >&2
    exit 1
  fi
fi
# ROS setup scripts reference unset AMENT_* vars, which `set -u` treats as an error — drop
# nounset just around the source, then restore it.
# shellcheck disable=SC1091
set +u; source /opt/ros/humble/setup.bash; set -u

# 1. Camera drivers + compressed transport + build tooling (apt). usb_cam drives the
#    two USB wrist cameras (fm_data_sensors cameras.launch.py prefers it on Linux).
#    python3-serial is the tactile bridge's link to the ESP32, and foxglove-bridge is
#    the operator surface the launch runs on :8765 — both are declared by packages,
#    but the rosdep step below is best-effort, so pin them here where they cannot be
#    missed (foxglove_bridge missing kept the first fresh Jetson's launch in a
#    restart loop with the app seeing no streams, 2026-08-13).
item "installing apt packages (RealSense + USB camera drivers, compressed transport, colcon, rosdep, serial) ..."
sudo apt-get update -qq
sudo apt-get install -y \
  ros-humble-realsense2-camera ros-humble-usb-cam \
  ros-humble-compressed-image-transport \
  ros-humble-rosbag2-storage-mcap v4l-utils \
  python3-colcon-common-extensions python3-vcstool python3-rosdep python3-pip \
  python3-opencv git curl cmake build-essential \
  python3-serial \
  ros-humble-foxglove-bridge

# 2. RealSense udev rules — required for the IMU (else it fails with Permission denied) and for
#    non-root device access. Re-plug the camera after this.
item "installing RealSense udev rules (re-plug the camera afterwards) ..."
bash "$ROOT/scripts/internal/install-realsense-udev-rules.sh"

# 3. MediaPipe + hand model (the tracker's perception). Download the model BEFORE the build so it
#    is installed into the package share dir.
item "installing MediaPipe==$MEDIAPIPE_VERSION + downloading the hand model ..."
pip3 install --user "mediapipe==$MEDIAPIPE_VERSION"
# MediaPipe pulls numpy 2.x, but the system matplotlib (a MediaPipe import dep) is built for
# numpy 1.x ("_ARRAY_API not found" / "numpy.core.multiarray failed to import"). Pin numpy < 2.
pip3 install --user "numpy<2"
bash src/fm_data/fm_data_perception/scripts/download_model.sh

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

# 4c. Tactile glove overlay — the ESP32 receiver (fm_tactile_bridge) and its message package
#     (fm_tactile_msgs) live in their own private repo. Cloned under src/ so colcon discovers
#     it in the same workspace overlay the recorder builds into; src/ is gitignored here, so
#     the checkout stays out of this repo's index (same shape as src/fm_data above).
#
#     Pinned to a tag, not a moving branch: the receiver owns a serial device and a systemd
#     unit on a shared capture host, so an unattended auto-update must never change it silently.
#     Partial clone — the repo also carries board gerbers, renders, and firmware archives that
#     a recorder host has no use for.
if [ ! -d "$TACTILE_DIR/.git" ]; then
  _tactile_repo="$(printf '%s' 'Zm0tdGFjdGlsZQ==' | base64 -d)"
  item "cloning the tactile glove overlay at $TACTILE_REF (needs first-motive org access) ..."
  mkdir -p "$(dirname "$TACTILE_DIR")"
  git clone --depth 1 --branch "$TACTILE_REF" --filter=blob:none \
    "https://github.com/first-motive/${_tactile_repo}.git" "$TACTILE_DIR" || {
    echo "ERROR: could not clone the tactile glove overlay at ref '$TACTILE_REF'. Ensure git" >&2
    echo "       can reach the private first-motive org (gh auth login, or an SSH key) and" >&2
    echo "       that the ref exists, then re-run." >&2
    exit 1
  }
fi

# 4d. Appliance release channel (--service): pin the role repos to their newest
#     release tag, so the box starts where the auto-updater will keep it (the
#     updater converges tag-to-tag; see appliance-update.sh). A repo with no v*
#     tag yet, or with local changes, is left where it is. A plain --recorder
#     (a dev checkout) is never moved.
if [ "${FM_INSTALL_SERVICE:-0}" = 1 ]; then
  pin_release src/fm_data
  pin_release src/fm_teleop
fi

# 5. Build the tracker + the recorder/sensors only — no sim / robot-control / MoveIt / dataset
#    engine. rosdep resolves system deps; failures there are non-fatal (the apt deps above cover
#    the core path), so the build still proceeds.
item "resolving deps + building tracker + recorder + tactile bridge ..."
sudo rosdep init 2>/dev/null || true
rosdep update 2>/dev/null || true
rosdep install --from-paths src/fm_data/fm_data_perception src/fm_data/fm_data_record \
  src/fm_data/fm_data_sensors \
  src/fm_data/fm_data_watchdog src/fm_data/fm_data_episode_qa \
  src/fm_teleop/fm_teleop_core src/fm_teleop/fm_teleop_msgs \
  "$TACTILE_DIR/ros2_ws/src" \
  --ignore-src -y --rosdistro humble 2>/dev/null || \
  item "rosdep install skipped/partial — continuing (apt deps above cover the core path)"
# colcon --symlink-install builds ament_python via `setup.py develop --editable`; the pip installs
# above can pull a too-new user setuptools that dropped that flag ("option --editable not
# recognized"). Pin the Humble-compatible setuptools (Ubuntu 22.04's system version).
item "pinning setuptools for the colcon ament_python build ..."
pip3 install --user "setuptools==59.6.0" 2>/dev/null || pip3 install --user "setuptools<64"
# The fm_data checkout has a top-level metapackage package.xml, so colcon's recursive discovery
# stops there and never sees the nested fm_data_record / fm_data_sensors / fm_data_perception.
# List their dirs explicitly as base-paths (mirrors the data engine's own README).
# The tracker lives in fm_data_perception; the only teleop packages the rig builds are the
# two dependency-free ones it publishes and filters with — fm_teleop_msgs (the perception
# interfaces) and fm_teleop_core (the One-Euro filters). No MediaPipe-bearing teleop node,
# no vision stack: a teleop refactor cannot break recording.
# fm_tactile_bridge pulls fm_tactile_msgs transitively; the recorder needs that message
# package on its PYTHONPATH too, or get_message() cannot import the type and it drops
# /glove_left/tactile with a warning every tick.
# fm_data_watchdog + fm_data_episode_qa are the rig monitors. They are built here
# but launched by their own units (fm-watchdog / fm-episode-qa), NOT by the
# recorder launch: a monitor that can crash-loop the recorder is a bad monitor,
# which this appliance demonstrated on 2026-08-11 when a launch entry for an
# unbuilt package took the rig down. Building them is inert on its own — nothing
# starts until a unit does.
colcon build --symlink-install \
  --base-paths src/fm_data/fm_data_perception src/fm_data/fm_data_record \
  src/fm_data/fm_data_sensors \
  src/fm_data/fm_data_watchdog src/fm_data/fm_data_episode_qa \
  src/fm_teleop/fm_teleop_core src/fm_teleop/fm_teleop_msgs \
  "$TACTILE_DIR/ros2_ws/src" \
  --packages-up-to fm_data_perception fm_data_record fm_data_sensors fm_tactile_bridge \
  fm_data_watchdog fm_data_episode_qa

# 4b. --symlink-install can leave the model files in the package share dir as dangling symlinks;
#     copy the real .task files in so hand_tracker (which resolves them from share) finds them.
_share_models="install/fm_data_perception/share/fm_data_perception/models"
if [ -d "$_share_models" ]; then
  cp -f src/fm_data/fm_data_perception/models/*.task "$_share_models"/ 2>/dev/null || true
fi

# 4c. Livox MID-360S chest LiDAR stack (best-effort — an optional sensor must never
#     cost the camera-host role). The vendor driver builds in its OWN overlay
#     workspace (~/ws_livox) against the system-installed Livox SDK2, both pinned to
#     the upstream commits that added MID-360S support. recorder-boot.sh runs the
#     LiDAR exactly when that overlay exists (FM_RECORDER_LIDAR=auto), and the
#     driver loads the rig's network identity from fm_data_sensors'
#     livox_mid360s.json (lidar 192.168.1.131 <- host 192.168.1.10 on the dedicated
#     second NIC — set that up as a persistent /32 profile, never a live /24;
#     see the fm-lidar NetworkManager profile).
item "provisioning the Livox MID-360S stack (best-effort) ..."
(
  set -e
  _livox_sdk_ref=f5d9375   # Support Mid-360S (upstream Livox-SDK2)
  _livox_drv_ref=13eb05e   # support Mid-360s Lidar (upstream livox_ros_driver2)
  # The vendor driver find_package()s PCL, which ros-base does not carry — a
  # fresh host fails the build without the dev headers (first Jetson, 2026-08-13).
  sudo apt-get install -y libpcl-dev ros-humble-pcl-conversions >/dev/null
  if [ ! -f /usr/local/lib/liblivox_lidar_sdk_shared.so ]; then
    [ -d "$HOME/Livox-SDK2" ] || \
      git clone https://github.com/Livox-SDK/Livox-SDK2.git "$HOME/Livox-SDK2"
    git -C "$HOME/Livox-SDK2" checkout -q "$_livox_sdk_ref" 2>/dev/null || true
    cmake -S "$HOME/Livox-SDK2" -B "$HOME/Livox-SDK2/build" >/dev/null
    cmake --build "$HOME/Livox-SDK2/build" -j"$(nproc)" >/dev/null
    sudo cmake --install "$HOME/Livox-SDK2/build" >/dev/null
    sudo ldconfig
  fi
  # Completeness = the built driver node, not install/setup.sh: colcon writes the
  # setup scripts before a failed build finishes, and that half-built overlay left
  # the first Jetson's launch in a "package not found" loop (2026-08-13). Probing
  # the node also makes a re-run (or the auto-updater's next tick) retry the build.
  if [ ! -x "$HOME/ws_livox/install/livox_ros_driver2/lib/livox_ros_driver2/livox_ros_driver2_node" ]; then
    mkdir -p "$HOME/ws_livox/src"
    [ -d "$HOME/ws_livox/src/livox_ros_driver2" ] || \
      git clone https://github.com/Livox-SDK/livox_ros_driver2.git \
        "$HOME/ws_livox/src/livox_ros_driver2"
    git -C "$HOME/ws_livox/src/livox_ros_driver2" checkout -q "$_livox_drv_ref" 2>/dev/null || true
    # The vendor build script selects the ROS2 package.xml and colcon-builds the
    # overlay workspace (run from the repo dir, per the vendor README).
    ( cd "$HOME/ws_livox/src/livox_ros_driver2" && ./build.sh humble >/dev/null )
  fi
) || item "WARNING: Livox stack provisioning failed — the LiDAR stays off (FM_RECORDER_LIDAR=auto); fix and re-run anytime"

# 5. Comms profile — the default (foxglove) pins FastDDS to the LAN interface so a Mac
#    actually receives the stream (extra NICs otherwise break delivery). Auto-source it
#    in every shell. A rig on another profile sets FM_COMMS or the .fm_ros2.json key.
item "wiring the comms profile into ~/.bashrc ..."
if ! grep -Fq 'scripts/env/comms.sh' "$HOME/.bashrc" 2>/dev/null; then
  # Drop the pre-comms.sh line a rig provisioned earlier still carries — comms.sh
  # sources dds-lan.sh itself for the foxglove profile, so keeping both would pin
  # DDS before the profile gets to choose.
  sed -i '\#scripts/run/dds-lan.sh#d' "$HOME/.bashrc" 2>/dev/null || true
  # Drop the line written before the profiles moved to scripts/env/. A rig
  # provisioned then still sources scripts/run/comms.sh, which no longer exists.
  sed -i '\#scripts/run/comms.sh#d' "$HOME/.bashrc" 2>/dev/null || true
  {
    echo ""
    echo "# fm_ros2 recorder: the comms profile (default foxglove = DDS on the LAN)"
    echo "source \"$ROOT/scripts/env/comms.sh\""
  } >> "$HOME/.bashrc"
fi

# 6. Boot service (opt-in via install.sh --recorder --service -> FM_INSTALL_SERVICE=1).
#    Installs a systemd unit so this host comes up as a headless recorder appliance:
#    camera + tracker + recorder (armed, idle) plus either the default embedded
#    bridge or the persisted standalone owner, driven remotely from a Mac. A plain
#    --recorder just builds; the appliance is opt-in.
if [ "${FM_INSTALL_SERVICE:-0}" = 1 ]; then
  # The auto-update timer below re-runs this installer unattended, and its
  # apt/systemd/udev steps are all sudo — grant the appliance user passwordless
  # sudo first (FM_NO_SUDOERS=1 opts out; updates then need a manual re-run).
  item "granting passwordless sudo for unattended updates (FM_NO_SUDOERS=1 skips) ..."
  ./scripts/install/install-appliance-sudoers.sh
  item "installing the recorder boot service (fm-recorder.service) ..."
  ./scripts/install/install-recorder-service.sh

  # A tower can reserve 8765 for Axol and keep the First Motive bridge on a
  # different persisted port. The standalone installer is opt-in on first
  # provisioning (FM_INSTALL_FOXGLOVE_SERVICE=1), then becomes self-preserving:
  # every later updater run sees FM_BRIDGE_OWNER=standalone and reinstalls it.
  if [ "$FM_BRIDGE_OWNER" = standalone ] || [ "${FM_INSTALL_FOXGLOVE_SERVICE:-0}" = 1 ]; then
    item "installing the standalone Foxglove bridge (fm-foxglove.service) ..."
    ./scripts/install/install-foxglove-service.sh --port "$FM_BRIDGE_PORT"
    # Reload the file in case the standalone installer created it on this run.
    # shellcheck disable=SC1091
    . "$ROOT/scripts/env/bridge.sh"
  fi
  # The tactile receiver is its own unit, not part of the recorder launch: it owns a
  # serial port exclusively and must keep streaming (and keep its clock fit warm)
  # while the recorder sits idle between takes.
  #
  # Guarded, for the same reason the monitor install below is: this script runs
  # under `set -e` from the auto-updater, and the update TIMER is installed last.
  # So any service install that fails here stops the timer being reinstalled and
  # silently ends convergence — the appliance keeps looking healthy while merged
  # work never arrives. Observed on fmtower 2026-08-11: a host running the
  # templated fm-tactile@left / fm-tactile@right instances fails to start the
  # single-glove fm-tactile.service (the instances already hold the device), and
  # that one failure had been blocking every update.
  #
  # A receiver that will not install is worth a loud warning, not a dead
  # appliance. The already-running instances keep streaming either way.
  item "installing the tactile glove receiver (fm-tactile.service) ..."
  ./scripts/install/install-tactile-service.sh || \
    item "WARNING: tactile receiver failed to install — check whether this host \
runs the fm-tactile@<side> instances instead; convergence continues"
  # The rig monitors get their OWN units, not entries in the recorder launch: a
  # monitor composed into egocentric_record.launch.py shares the recorder's fate,
  # and on 2026-08-11 exactly that took capture down to add health monitoring.
  #
  # `|| item ...` is deliberate and load-bearing. This script runs under `set -e`
  # via the auto-updater, so an un-guarded failure here would abort the recorder's
  # own install mid-converge. Health monitoring must never be able to break
  # capture — not when it runs, and not when it installs.
  item "installing the rig monitor services (fm-watchdog, fm-episode-qa) ..."
  ./scripts/install/install-monitors-service.sh || \
    item "WARNING: monitor services failed to install — capture is unaffected; \
re-run ./scripts/install/install-monitors-service.sh to retry"
  # An appliance keeps itself current: fetch every ~15 min, converge on merged
  # updates (a take in flight is never interrupted; see appliance-update.sh).
  item "installing the auto-update timer (fm-update-recorder.timer) ..."
  ./scripts/install/install-update-timer.sh recorder
  # Make the box discoverable: advertise the recorder role over mDNS so the
  # desktop app's Settings offers this rig instead of a typed IP.
  item "advertising the recorder on the local network (mDNS) ..."
  ./scripts/install/install-avahi-advert.sh recorder
else
  item "boot service not installed — add it anytime with:"
  item "  ./scripts/install/install-recorder-service.sh   (or reinstall with --service)"
fi

item "recorder provisioned at $ROOT"
cat <<EOF

Next — plug the RealSense into a USB3 port, open a NEW terminal, then:

  source /opt/ros/humble/setup.bash
  source "$ROOT/install/setup.bash"          # the built tracker + recorder
  source "$ROOT/scripts/env/comms.sh"        # comms profile (auto in new shells via ~/.bashrc)

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
  #   open src/fm_app/fm_viewer/webgui/index.html?ws=ws://<this-host-ip>:$FM_BRIDGE_PORT
  #   systemctl status fm-recorder    |    journalctl -u fm-recorder -f
EOF
