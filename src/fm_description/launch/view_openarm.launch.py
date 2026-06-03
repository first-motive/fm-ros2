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

"""
View the Enactic OpenArm URDF as a robot_description.

OpenArm differs from the G1 and SO101 views in how the description is sourced.
The G1/SO101 paths vendor flat URDF files into this package's share and rewrite
relative mesh paths to `package://fm_description/...` at launch. OpenArm instead
ships as a real, built ament_cmake ROS package (enactic/openarm_description):
import-externals.sh leaves it OUT of COLCON_IGNORE, so `colcon build` compiles
it into the workspace. We therefore process its xacro at launch with
`xacro.process_file`, and the meshes already reference
`package://openarm_description/...` throughout, which foxglove_bridge's
resource_retriever resolves in-container — no path rewrite is needed for them.

The meshes do need one bridge tweak. OpenArm's package:// paths run through a
dotted directory (openarm_v2.0), and foxglove_bridge's default asset_uri_allowlist
regex permits only [\\w-] in path segments — so it rejects every mesh with
"Asset URI not allowed", and nothing renders. We widen the allowlist to permit
the dot (see the foxglove_bridge node below). The G1/SO101 paths have no dotted
dirs, so they need no override.

Xacro entry point (relative to the built openarm_description share):
    assets/robot/openarm_v2.0/urdf/openarm_v20.urdf.xacro

The v2.0 xacro selects its links through a `robot_preset` arg (the upstream
display_openarm.launch.py is the reference). The default here is `right_arm`: a
single right arm with the body and left arm disabled. Other presets:
`default_bimanual`, `left_arm`, and the `*_with_pinch_gripper` variants. The
preset's ros2_control include runs with fake hardware and is harmless for a
view, so no disable flag is needed.

foxglove_bridge's `send_buffer_limit` is raised above its 10 MB default: the
`default_bimanual` preset includes a ~10.8 MB body mesh (body_link0.dae) that
exceeds the default, which silently drops that asset (and resets the asset
channel, so sibling meshes fail too). `right_arm` stays well under the default,
but the raised limit lets every preset render.
"""

import os

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

# Relative path to the xacro entry point inside the built openarm_description
# share. The package is an upstream ament_cmake package, not vendored here.
OPENARM_XACRO_REL = "assets/robot/openarm_v2.0/urdf/openarm_v20.urdf.xacro"


def _launch_setup(context, *args, **kwargs):
    robot_preset = LaunchConfiguration("robot_preset").perform(context)
    use_foxglove = LaunchConfiguration("use_foxglove").perform(context) == "true"
    use_rviz = LaunchConfiguration("use_rviz")
    use_jsp = LaunchConfiguration("use_jsp")

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

    xacro_path = os.path.join(openarm_share, OPENARM_XACRO_REL)
    if not os.path.isfile(xacro_path):
        raise RuntimeError(
            f"OpenArm xacro not found: {xacro_path}\n"
            "Import externals then build: "
            "./scripts/import-externals.sh && colcon build --symlink-install"
        )

    # The v2.0 xacro selects links through robot_preset (string). This is the
    # only model arg upstream display_openarm.launch.py passes for v2.0; the
    # ros2_control include runs with fake hardware and needs no disable flag.
    mappings = {"robot_preset": robot_preset}

    try:
        doc = xacro.process_file(xacro_path, mappings=mappings)
        robot_description = doc.toxml()
    except Exception as exc:
        raise RuntimeError(
            f"Failed to process OpenArm xacro: {xacro_path}\n"
            f"mappings={mappings}\n"
            "Valid robot_preset values: default_bimanual, right_arm, left_arm, "
            "right_arm_with_pinch_gripper, left_arm_with_pinch_gripper. See "
            "upstream display_openarm.launch.py for the reference mappings."
        ) from exc

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
                # asset_uri_allowlist widened from the default: OpenArm mesh paths
                # contain a dotted directory (openarm_v2.0), and the bridge's
                # default regex allows only [\w-] in path segments, so it rejects
                # every mesh ("Asset URI not allowed"). [-\w.] permits the dot. The
                # G1/SO101 paths have no dotted dirs, so the default suffices there.
                #
                # send_buffer_limit raised from the 10 MB default so the
                # default_bimanual preset's ~10.8 MB body mesh (body_link0.dae)
                # serves. 128 MB covers every preset with headroom.
                parameters=[
                    {
                        "port": 8765,
                        "address": "0.0.0.0",
                        "send_buffer_limit": 134217728,
                        "asset_uri_allowlist": [
                            r"^package://(?:[-\w.]+/)*[-\w.]+"
                            r"\.(?:dae|stl|obj|glb|gltf|mtl|png|jpe?g|tiff?)$"
                        ],
                    }
                ],
            )
        )

    return nodes


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "robot_preset",
                default_value="right_arm",
                description=(
                    "OpenArm v2.0 preset: right_arm (default), left_arm, "
                    "default_bimanual, right_arm_with_pinch_gripper, "
                    "left_arm_with_pinch_gripper."
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
