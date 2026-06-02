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

Loads a flat G1 URDF from the vcs-imported `unitree_ros` working copy
(`src/external/`, gitignored), rewrites its relative mesh paths to absolute
`file://` URIs, and publishes it via robot_state_publisher. A foxglove_bridge is
started so Foxglove Studio on the macOS host can render the model with meshes.

Mesh resolution: the G1 URDFs reference meshes as relative `meshes/foo.STL`,
which neither RViz nor Foxglove can resolve on their own. We rewrite them to
`file://<g1_root>/meshes/foo.STL`. foxglove_bridge reads those files inside the
container and streams the bytes to Studio, so the host never needs the files.
The bridge blocks file:// by default, so we widen `asset_uri_allowlist` to the
mesh directory.

Variant is a launch arg because the G1-D hand is not yet locked (Inspire U6
leading). Swap with `variant:=g1_29dof_rev_1_0_with_inspire_hand_FTP`, etc.

Caveat: every upstream G1 URDF is bipedal; no wheeled-base G1 description exists.
This renders the closest reference body, not the G1-D wheeled platform.
"""

import os
import re

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

# Default vcs-import location of g1_description inside the container (/ws is the
# workspace mount). The external/external nesting is the current vcs layout: the
# repos keys carry an `external/` prefix and import into `src/external`. Override
# with g1_root:= when running elsewhere.
DEFAULT_G1_ROOT = "/ws/src/external/external/unitree_ros/robots/g1_description"

# Mesh extensions foxglove_bridge is allowed to serve over file://.
MESH_EXTS = "STL|stl|dae|obj|glb|gltf"


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
            "Did you import externals? Run ./scripts/import-externals.sh"
        )

    with open(urdf_path, "r") as f:
        robot_description = f.read()

    # Rewrite relative mesh paths to absolute file:// URIs the bridge can serve.
    robot_description = robot_description.replace(
        'filename="meshes/', f'filename="file://{g1_root}/meshes/'
    )

    # Anchor the bridge allowlist to this mesh dir only (keep package:// too).
    mesh_allow = f"^file://{re.escape(g1_root)}/meshes/.*\\.({MESH_EXTS})$"

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
                parameters=[
                    {
                        "port": 8765,
                        "address": "0.0.0.0",
                        "asset_uri_allowlist": [mesh_allow, "^package://.*"],
                    }
                ],
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
                description="Path to the g1_description dir holding the URDF + meshes/.",
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
