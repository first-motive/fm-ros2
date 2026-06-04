# Copyright 2026 First Motive
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

r"""
View any supported robot URDF as a robot_description from one launch file.

This unifies the former per-robot views (G1, SO101, OpenArm) behind a single
inline ROBOTS registry. Each registry entry owns its quirks: where the
description comes from, how meshes are rewritten, and any foxglove_bridge tweaks.
Select an entry with the `robot` arg; pick a sub-form with `variant`. Adding a
new robot is one new registry entry — no new launch file.

Mesh resolution: every entry rewrites mesh references to
`package://fm_description/...`. That is the only scheme Foxglove Studio fetches
through the bridge — Studio routes `package://` to the bridge's
resource_retriever (in the container) and resolves every other scheme (file://,
http://) host-side, which cannot see container files. CMakeLists installs each
description into this package's share, so the package:// path resolves. The
bridge's default asset_uri_allowlist already permits package:// for the simple
paths; OpenArm widens it (dotted dir) — see its registry entry.

Each entry exposes:
  - label            short echo string
  - default_variant  used when the `variant` arg is empty
  - build_description (share, variant) -> urdf_xml callable
  - bridge_params    merged into the foxglove_bridge node's parameters
"""

import os
import re

import xacro

from ament_index_python.packages import (
    get_package_share_directory,
    PackageNotFoundError,
)

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

PKG = "fm_description"

# Default foxglove_bridge parameters. Entries may extend (never shrink) these.
_DEFAULT_BRIDGE_PARAMS = {"port": 8765, "address": "0.0.0.0"}

# --- G1 -------------------------------------------------------------------

# The G1 descriptions are installed into this package's share by CMakeLists,
# sourced from the vcs-imported unitree_ros (run import-externals.sh, then build).
# Default is g1_d_description: the wheeled G1-D (AGV base + arms). Switch to the
# bipedal 29 DOF body with variant:=g1_29dof_rev_1_0.
_G1_VARIANT_DIRS = {
    "g1_d": "g1_d_description",
    "g1_29dof_rev_1_0": "g1_description",
}


def _build_g1(share, variant):
    """Load a flat G1 URDF and rewrite relative mesh paths to package://."""
    desc_dir = _G1_VARIANT_DIRS.get(variant)
    if desc_dir is None:
        raise RuntimeError(
            f"Unknown G1 variant: {variant!r}. "
            f"Valid variants: {sorted(_G1_VARIANT_DIRS)}"
        )

    root = os.path.join(share, desc_dir)
    urdf_path = os.path.join(root, f"{variant}.urdf")
    if not os.path.isfile(urdf_path):
        raise RuntimeError(
            f"G1 URDF not found: {urdf_path}\n"
            "Import externals then build: ./scripts/import-externals.sh && colcon build"
        )

    with open(urdf_path, "r") as f:
        robot_description = f.read()

    # Rewrite relative mesh paths to package:// so Foxglove fetches them via the
    # bridge. The meshes live in this package's share (installed by CMakeLists)
    # under a dir named after the variant's description (g1_d_description, ...).
    return robot_description.replace(
        'filename="meshes/', f'filename="package://{PKG}/{desc_dir}/meshes/'
    )


# --- SO101 ----------------------------------------------------------------

# The SO101 description is installed into this package's share by CMakeLists,
# sourced from the vcs-imported SO-ARM100 working copy (run import-externals.sh,
# then build). It is a single flat URDF (so101_new_calib.urdf) plus assets/.


def _build_so101(share, variant):
    """Load the flat SO101 URDF and rewrite relative mesh paths to package://."""
    # SO101 has a single description; the variant arg is ignored.
    root = os.path.join(share, "so101_description")
    urdf_path = os.path.join(root, "so101_new_calib.urdf")
    if not os.path.isfile(urdf_path):
        raise RuntimeError(
            f"SO101 URDF not found: {urdf_path}\n"
            "Import externals then build: ./scripts/import-externals.sh && colcon build"
        )

    with open(urdf_path, "r") as f:
        robot_description = f.read()

    # Rewrite relative mesh paths to package:// so Foxglove fetches them via the
    # bridge. The meshes live in this package's share (installed by CMakeLists)
    # under so101_description/assets/.
    return robot_description.replace(
        'filename="assets/', f'filename="package://{PKG}/so101_description/assets/'
    )


# --- OpenArm --------------------------------------------------------------

# OpenArm differs from the G1 and SO101 views in how the description is sourced.
# The G1/SO101 paths vendor flat URDF files into this package's share and rewrite
# relative mesh paths to package://fm_description/... at launch. OpenArm instead
# ships as a real, built ament_cmake ROS package (enactic/openarm_description):
# import-externals.sh leaves it OUT of COLCON_IGNORE, so colcon build compiles it
# into the workspace. We therefore process its xacro at launch.
#
# Visual mesh up-axis baking. The upstream visual meshes are COLLADA (.dae) with
# inconsistent declared up-axes (arm and pinch gripper Y_UP, body Z_UP). RViz
# honours each file's up_axis, so it renders upright; Foxglove Studio ignores
# per-file up_axis and applies one global mesh-up setting, so the raw .dae meshes
# render mis-rotated. fm_description's build converts every OpenArm visual mesh to
# STL with assimp, which bakes each file's up_axis into the geometry — yielding the
# orientation RViz already presents, with no extra rotation (see CMakeLists.txt).
# We rewrite each visual reference from package://openarm_description/<rel>.dae to
# package://fm_description/openarm_meshes/<rel>.stl. Collision meshes are already
# STL, are not rendered by default, and are left pointing at openarm_description.

# Relative path to the xacro entry point inside the built openarm_description
# share. The package is an upstream ament_cmake package, not vendored here.
_OPENARM_XACRO_REL = "assets/robot/openarm_v2.0/urdf/openarm_v20.urdf.xacro"

# Rewrite visual COLLADA mesh references onto the Z-up STL set vendored into this
# package's share at build (see CMakeLists.txt). Only visual meshes are .dae, so
# matching the .dae suffix targets them without touching collision STL refs.
_VISUAL_MESH_RE = re.compile(r"package://openarm_description/([^\"']+?)\.dae")
_VISUAL_MESH_SUB = r"package://fm_description/openarm_meshes/\1.stl"


def _build_openarm(share, variant):
    """Process the OpenArm xacro for a preset and rewrite .dae visuals to STL."""
    # Locate the built openarm_description package. It must be imported (without
    # COLCON_IGNORE) and built into the workspace before this launch can run.
    try:
        openarm_share = get_package_share_directory("openarm_description")
    except PackageNotFoundError as exc:
        raise RuntimeError(
            "openarm_description not found. It is a built ament_cmake package, "
            "not vendored into fm_description. Import and build it:\n"
            "  ./scripts/import-externals.sh   # imports openarm_description "
            "without COLCON_IGNORE\n"
            "  colcon build --symlink-install"
        ) from exc

    xacro_path = os.path.join(openarm_share, _OPENARM_XACRO_REL)
    if not os.path.isfile(xacro_path):
        raise RuntimeError(
            f"OpenArm xacro not found: {xacro_path}\n"
            "Import externals then build: "
            "./scripts/import-externals.sh && colcon build --symlink-install"
        )

    # The v2.0 xacro selects links through robot_preset (string). This is the
    # only model arg upstream display_openarm.launch.py passes for v2.0; the
    # ros2_control include runs with fake hardware and needs no disable flag.
    mappings = {"robot_preset": variant}

    try:
        doc = xacro.process_file(xacro_path, mappings=mappings)
        robot_description = doc.toxml()
        # Point visual meshes at the Z-up STL set in this package's share.
        robot_description = _VISUAL_MESH_RE.sub(_VISUAL_MESH_SUB, robot_description)
    except Exception as exc:
        raise RuntimeError(
            f"Failed to process OpenArm xacro: {xacro_path}\n"
            f"mappings={mappings}\n"
            "Valid robot_preset values: default_bimanual, right_arm, left_arm, "
            "right_arm_with_pinch_gripper, left_arm_with_pinch_gripper. See "
            "upstream display_openarm.launch.py for the reference mappings."
        ) from exc

    return robot_description


# OpenArm's bridge params extend the default. Its package:// paths run through a
# dotted directory (openarm_v2.0), and foxglove_bridge's default
# asset_uri_allowlist regex permits only [\w-] in path segments — so it rejects
# every mesh with "Asset URI not allowed", and nothing renders. [-\w.] permits the
# dot. send_buffer_limit is raised above its 10 MB default because the
# default_bimanual preset includes a ~10.8 MB body mesh (body_link0.dae) that
# exceeds it, which silently drops that asset (and resets the asset channel, so
# sibling meshes fail too). 128 MB covers every preset with headroom.
_OPENARM_BRIDGE_PARAMS = {
    **_DEFAULT_BRIDGE_PARAMS,
    "send_buffer_limit": 134217728,
    "asset_uri_allowlist": [
        r"^package://(?:[-\w.]+/)*[-\w.]+"
        r"\.(?:dae|stl|obj|glb|gltf|mtl|png|jpe?g|tiff?)$"
    ],
}


# --- Registry -------------------------------------------------------------

ROBOTS = {
    "g1_d": {
        "label": "Unitree G1 (G1-D)",
        "default_variant": "g1_d",
        "build_description": _build_g1,
        "bridge_params": _DEFAULT_BRIDGE_PARAMS,
    },
    "so101": {
        "label": "LeRobot SO101",
        "default_variant": "so101",
        "build_description": _build_so101,
        "bridge_params": _DEFAULT_BRIDGE_PARAMS,
    },
    "openarm": {
        "label": "Enactic OpenArm",
        "default_variant": "right_arm",
        "build_description": _build_openarm,
        "bridge_params": _OPENARM_BRIDGE_PARAMS,
    },
}


def _launch_setup(context, *args, **kwargs):
    robot = LaunchConfiguration("robot").perform(context)
    variant = LaunchConfiguration("variant").perform(context)
    use_foxglove = LaunchConfiguration("use_foxglove").perform(context) == "true"
    use_rviz = LaunchConfiguration("use_rviz")
    use_jsp = LaunchConfiguration("use_jsp")

    entry = ROBOTS.get(robot)
    if entry is None:
        raise RuntimeError(
            f"Unknown robot: {robot!r}. Valid robots: {sorted(ROBOTS)}"
        )

    if not variant:
        variant = entry["default_variant"]

    share = get_package_share_directory(PKG)
    robot_description = entry["build_description"](share, variant)

    nodes = [
        Node(
            package="robot_state_publisher",
            executable="robot_state_publisher",
            name="robot_state_publisher",
            output="screen",
            parameters=[{"robot_description": robot_description}],
        ),
        Node(
            package="joint_state_publisher",
            executable="joint_state_publisher",
            name="joint_state_publisher",
            output="screen",
            condition=IfCondition(use_jsp),
            parameters=[{"robot_description": robot_description}],
        ),
        Node(
            package="rviz2",
            executable="rviz2",
            name="rviz2",
            output="screen",
            condition=IfCondition(use_rviz),
        ),
    ]

    if use_foxglove:
        nodes.append(
            Node(
                package="foxglove_bridge",
                executable="foxglove_bridge",
                name="foxglove_bridge",
                output="screen",
                parameters=[entry["bridge_params"]],
            )
        )

    return nodes


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "robot",
                default_value="g1_d",
                description=(
                    "Registry key selecting the robot: g1_d, so101, openarm."
                ),
            ),
            DeclareLaunchArgument(
                "variant",
                default_value="",
                description=(
                    "Robot sub-form (empty uses the entry's default): G1 URDF "
                    "basename (g1_d, g1_29dof_rev_1_0) or OpenArm robot_preset "
                    "(right_arm, left_arm, default_bimanual, *_with_pinch_gripper). "
                    "Ignored for so101."
                ),
            ),
            DeclareLaunchArgument(
                "use_foxglove",
                default_value="true",
                description="Start foxglove_bridge on ws://0.0.0.0:8765.",
            ),
            DeclareLaunchArgument(
                "use_rviz",
                default_value="false",
                description="Start RViz (needs an X display; Foxglove is the macOS path).",
            ),
            DeclareLaunchArgument(
                "use_jsp",
                default_value="true",
                description="Start joint_state_publisher so non-fixed joints get TF.",
            ),
            OpaqueFunction(function=_launch_setup),
        ]
    )
