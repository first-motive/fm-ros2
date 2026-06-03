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
`package://openarm_description/...` throughout — once the package is built and
sourced, foxglove_bridge's resource_retriever resolves those package:// URIs
directly. No mesh rewrite is needed.

Xacro entry point (relative to the built openarm_description share):
    assets/robot/openarm_v2.0/urdf/openarm_v20.urdf.xacro

The xacro pulls in a ros2_control include that errors during view-only
processing, so we pass a mapping that disables ros2_control. The default view is
a single right arm (arm_type:=right_arm). Other presets: left_arm,
default_bimanual, and the *_with_pinch_gripper variants.
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
    arm_type = LaunchConfiguration("arm_type").perform(context)
    preset = LaunchConfiguration("preset").perform(context)
    ros2_control = LaunchConfiguration("ros2_control").perform(context)
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

    # Mappings passed into the xacro. All values must be strings.
    #
    # The `ros2_control` key disables the ros2_control include for view-only
    # processing. This key name mirrors upstream display_openarm.launch.py; if
    # the upstream xacro names the flag differently, adjust it once the package
    # is imported on disk.
    mappings = {
        "arm_type": arm_type,
        "ros2_control": ros2_control,
    }
    # `preset` is an optional override; only forward it when set, so an empty
    # default does not clobber the xacro's own preset handling.
    if preset:
        mappings["preset"] = preset

    try:
        doc = xacro.process_file(xacro_path, mappings=mappings)
        robot_description = doc.toxml()
    except Exception as exc:
        raise RuntimeError(
            f"Failed to process OpenArm xacro: {xacro_path}\n"
            f"mappings={mappings}\n"
            "If a ros2_control include errors during view-only processing, "
            "ensure ros2_control is disabled (ros2_control:=false). See upstream "
            "display_openarm.launch.py for the reference xacro mappings."
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
                parameters=[{"port": 8765, "address": "0.0.0.0"}],
            )
        )

    return nodes


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "arm_type",
                default_value="right_arm",
                description=(
                    "Which arm/preset: right_arm, left_arm, default_bimanual, "
                    "*_with_pinch_gripper."
                ),
            ),
            DeclareLaunchArgument(
                "preset",
                default_value="",
                description="Optional preset override; forwarded to xacro only when non-empty.",
            ),
            DeclareLaunchArgument(
                "ros2_control",
                default_value="false",
                description="Enable the ros2_control xacro include (disabled for view-only).",
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
