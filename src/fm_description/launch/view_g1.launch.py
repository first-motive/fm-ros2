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
View the Unitree G1 (G1-D reference) URDF as a robot_description.

Loads a flat G1 URDF and publishes it via robot_state_publisher, then starts a
foxglove_bridge so Foxglove Studio on the macOS host can render it with meshes.

Mesh resolution: the G1 URDFs reference meshes as relative `meshes/foo.STL`. We
rewrite them to `package://fm_description/g1_description/meshes/foo.STL`. That is
the only scheme Foxglove Studio fetches through the bridge — Studio routes
`package://` to the bridge's resource_retriever (in the container) and resolves
every other scheme (file://, http://) host-side, which cannot see container
files. CMakeLists installs the G1 description into this package's share, so the
package:// path resolves. The bridge's default asset_uri_allowlist already
permits package://, so no allowlist override is needed.

Variant is a launch arg because the G1-D hand is not yet locked (Inspire U6
leading). Swap with `variant:=g1_29dof_rev_1_0_with_inspire_hand_FTP`, etc.

Caveat: every upstream G1 URDF is bipedal; no wheeled-base G1 description exists.
This renders the closest reference body, not the G1-D wheeled platform.
"""

import os

from ament_index_python.packages import get_package_share_directory

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

PKG = "fm_description"

# The G1 description is installed into this package's share by CMakeLists,
# sourced from the vcs-imported unitree_ros (run import-externals.sh, then build).
DEFAULT_G1_ROOT = os.path.join(get_package_share_directory(PKG), "g1_description")


def _launch_setup(context, *args, **kwargs):
    variant = LaunchConfiguration("variant").perform(context)
    g1_root = LaunchConfiguration("g1_root").perform(context)
    use_foxglove = LaunchConfiguration("use_foxglove").perform(context) == "true"
    use_rviz = LaunchConfiguration("use_rviz")
    use_jsp = LaunchConfiguration("use_jsp")

    urdf_path = os.path.join(g1_root, f"{variant}.urdf")
    if not os.path.isfile(urdf_path):
        raise RuntimeError(
            f"G1 URDF not found: {urdf_path}\n"
            "Import externals then build: ./scripts/import-externals.sh && colcon build"
        )

    with open(urdf_path, "r") as f:
        robot_description = f.read()

    # Rewrite relative mesh paths to package:// so Foxglove fetches them via the
    # bridge. The meshes live in this package's share (installed by CMakeLists).
    robot_description = robot_description.replace(
        'filename="meshes/', f'filename="package://{PKG}/g1_description/meshes/'
    )

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
                "variant",
                default_value="g1_29dof_rev_1_0",
                description="G1 URDF basename in g1_root (no .urdf suffix).",
            ),
            DeclareLaunchArgument(
                "g1_root",
                default_value=DEFAULT_G1_ROOT,
                description="Dir holding the URDF + meshes/ (default: this package's share).",
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
