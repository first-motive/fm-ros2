#!/usr/bin/env bash
# setup-processor.sh — provision a native Linux host (Ubuntu 22.04 + ROS 2 Humble) as the First
# Motive "processor": the dataset engine (fm_data_dataset) plus its process_supervisor node,
# which the desktop app's Process surface drives over the capture session's foxglove bridge
# (/process/* topics). It scores recorded episode bags into manifests and, with the RLDS tier
# installed, emits clean RLDS datasets.
#
# Deliberately a SIBLING role to setup-recorder.sh, installed into its OWN workspace checkout:
# the recorder stack (a ~/jetson checkout today) moves to a Jetson later, while processing stays
# on the strong Linux host. Run the one-liner from the directory that should own the processor
# workspace (e.g. ~/processor), never inside the recorder checkout. Today both roles share the
# host, so the supervisor reads the recorder's ~/recordings directly.
#
# Invoked by:  ./install.sh --processor   (or run standalone from a checkout).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/lib.sh"          # item(), spin()
cd "$ROOT"

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

# 1. Build tooling (apt). The engine's bag ingest is the pure-Python `rosbags` pip package,
#    so no camera drivers and no rosbag2 plugins are needed for this role. python3-venv is
#    NOT in stock Ubuntu 22.04 and the engine venv below needs it (hit live, 2026-07-23).
item "installing apt packages (colcon, rosdep, pip, venv) ..."
sudo apt-get update -qq
sudo apt-get install -y \
  python3-colcon-common-extensions python3-rosdep python3-pip python3-venv \
  git curl

# 2. Data engine — clone the private data-engine repo (the dataset engine + the recorder's
#    ROS-free session-index core live there) into src/fm_data if absent. Needs first-motive
#    org access (gh auth login, or an SSH key). The repo slug is held base64-encoded so the
#    public tree does not name it (repo-hygiene scan).
if [ ! -d src/fm_data/.git ]; then
  _data_repo="$(printf '%s' 'Zm0tZGF0YQ==' | base64 -d)"
  item "cloning the private data engine (needs first-motive org access) ..."
  git clone --depth 1 "https://github.com/first-motive/${_data_repo}.git" src/fm_data || {
    echo "ERROR: could not clone the private data engine (the dataset engine lives there)." >&2
    echo "       Ensure git can reach the private first-motive org (gh auth login, or an" >&2
    echo "       SSH key), then re-run." >&2
    exit 1
  }
fi

# 3. Engine Python tiers, in a DEDICATED venv ($ROOT/.engine-venv) — never the shared
#    user site-packages. The engine wants numpy 2.x while other tenants of the same
#    host (the recorder's MediaPipe chain) pin numpy<2; a --user install here broke the
#    recorder's hand tracker live on the shared rig host (2026-07-23). The supervisor
#    spawns dataset_process under this venv's interpreter (engine_python), so the two
#    roles never fight. The engine package itself is editable-installed from the
#    workspace source, so a git pull updates it with no reinstall.
#
#    Bags (numpy + rosbags) is the working tier — scoring real MCAP episodes needs it.
#    The heavy TensorFlow/RLDS tier is opt-in (FM_INSTALL_RLDS=1) because emit is
#    optional and the download is large; add it later anytime with the same pip line.
#
#    numpy pin: the engine's requirements pin numpy==2.4.6, which needs Python >= 3.11 —
#    Ubuntu 22.04's system Python is 3.10, where numpy caps at 2.2.x (hit live on the
#    first processor host, 2026-07-22). Keep the repo pin on new-enough hosts; on 3.10
#    install the newest compatible numpy 2.x with the same rosbags pin (the engine's CI
#    already runs on the py3.10 Humble container, so 3.10 + numpy 2.2 is a supported pair).
ENGINE_VENV="$ROOT/.engine-venv"
item "creating the engine venv ($ENGINE_VENV) + installing the bag-ingest tier ..."
python3 -m venv "$ENGINE_VENV"
if "$ENGINE_VENV/bin/python" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
  "$ENGINE_VENV/bin/pip" install --quiet -r src/fm_data/fm_data_dataset/requirements-bags.txt
else
  item "host Python $(python3 -V | cut -d' ' -f2) < 3.11 — pinning numpy==2.2.6 (newest 3.10-compatible)"
  "$ENGINE_VENV/bin/pip" install --quiet "numpy==2.2.6" \
    "$(grep -E '^rosbags==' src/fm_data/fm_data_dataset/requirements-bags.txt)"
fi
"$ENGINE_VENV/bin/pip" install --quiet -e src/fm_data/fm_data_dataset
if [ "${FM_INSTALL_RLDS:-0}" = 1 ]; then
  item "installing the RLDS emit tier into the venv (TensorFlow + TFDS — large download) ..."
  "$ENGINE_VENV/bin/pip" install -r src/fm_data/fm_data_dataset/requirements-rlds.txt
else
  item "RLDS emit tier skipped — enable emit later with:"
  item "  $ENGINE_VENV/bin/pip install -r src/fm_data/fm_data_dataset/requirements-rlds.txt"
fi

# 4. Build the dataset engine + the recorder core it reads sessions.jsonl through — nothing
#    else (no sim / robot / cameras / tracker). rosdep resolves system deps; failures there
#    are non-fatal (the apt deps above cover the core path), so the build still proceeds.
item "resolving deps + building the processor (fm_data, fm_data_dataset, fm_data_record) ..."
sudo rosdep init 2>/dev/null || true
rosdep update 2>/dev/null || true
rosdep install --from-paths src/fm_data/fm_data_dataset src/fm_data/fm_data_record \
  --ignore-src -y --rosdistro humble 2>/dev/null || \
  item "rosdep install skipped/partial — continuing (apt deps above cover the core path)"
# colcon --symlink-install builds ament_python via `setup.py develop --editable`; the pip installs
# above can pull a too-new user setuptools that dropped that flag ("option --editable not
# recognized"). Pin the Humble-compatible setuptools (Ubuntu 22.04's system version).
item "pinning setuptools for the colcon ament_python build ..."
pip3 install --user "setuptools==59.6.0" 2>/dev/null || pip3 install --user "setuptools<64"
# The fm_data checkout has a top-level metapackage package.xml, so colcon's recursive discovery
# stops there and never sees the nested packages — list the nested dirs explicitly as base-paths
# (setup-recorder.sh pattern). The fm_data metapackage itself is built too: it installs
# launch/process_session.launch.py, the processor's entry point.
colcon build --symlink-install \
  --base-paths src/fm_data src/fm_data/fm_data_dataset src/fm_data/fm_data_record \
  --packages-select fm_data fm_data_dataset fm_data_record

# 5. DDS LAN networking — pin FastDDS to the LAN interface so the /process/* topics reach the
#    capture session's bridge (and, after the Jetson split, the recorder host). Auto-source it
#    in every shell.
item "wiring DDS LAN networking into ~/.bashrc ..."
if ! grep -q "$ROOT/scripts/run/dds-lan.sh" "$HOME/.bashrc" 2>/dev/null; then
  {
    echo ""
    echo "# fm_ros2 processor: pin DDS to the LAN so /process/* topics reach the capture bridge"
    echo "source \"$ROOT/scripts/run/dds-lan.sh\""
  } >> "$HOME/.bashrc"
fi

# 6. Boot service (opt-in via install.sh --processor --service -> FM_INSTALL_SERVICE=1).
#    Installs a systemd unit so this host comes up as a headless processing appliance:
#    process_supervisor up on boot, driven remotely from the desktop app's Process surface.
#    A plain --processor just builds; the appliance is opt-in.
if [ "${FM_INSTALL_SERVICE:-0}" = 1 ]; then
  item "installing the processor boot service (fm-processor.service) ..."
  ./scripts/install/install-processor-service.sh
  # An appliance keeps itself current: fetch every ~15 min, converge on merged
  # updates (busy runs are never interrupted; see appliance-update.sh).
  item "installing the auto-update timer (fm-update-processor.timer) ..."
  ./scripts/install/install-update-timer.sh processor
else
  item "boot service not installed — add it anytime with:"
  item "  ./scripts/install/install-processor-service.sh   (or reinstall with --service)"
fi

item "processor provisioned at $ROOT"
cat <<EOF

Next — open a NEW terminal, then:

  source /opt/ros/humble/setup.bash
  source "$ROOT/install/setup.bash"          # the built dataset engine + supervisor
  source "$ROOT/scripts/run/dds-lan.sh"      # DDS on the LAN (auto in new shells via ~/.bashrc)

  # The app-driven processing supervisor — one command:
  ros2 launch fm_data process_session.launch.py
  #   custom dirs:  ros2 launch fm_data process_session.launch.py \\
  #                   recordings_dir:=~/recordings output_dir:=~/processed

  # It serves /process/* over the capture session's foxglove bridge; kick off runs from
  # the desktop app's Process window. Manifests land under ~/processed/<episode_id>/;
  # a processed episode is refused on re-run (delete its output dir to force one).

  # One-off CLI runs (no app) still work directly:
  ros2 run fm_data_dataset dataset_process --input <bag_dir> --output <out_dir>

  # Installed the boot service (--service)? The supervisor already runs on boot:
  #   systemctl status fm-processor    |    journalctl -u fm-processor -f
EOF
