"""Interactive teleop for the OpenArm — MoveIt Servo plus a selected input.

    input (foxglove | joy | spacenav)
        -> Servo (servo.launch.py)
        -> input source publishing TwistStamped/JointJog onto Servo's delta topics

Assumes the sim (or real) target is already up — run scripts/sim.sh in another
terminal first — so Servo has /joint_states and the arm's joint_trajectory_controller
to stream to.

    foxglove   no extra node: the browser panel publishes via foxglove_bridge (the
               primary, fleet-scalable input).
    joy        joy_node (Linux /dev/input, or a Mac host-side HID->Joy bridge)
               + joy_to_servo.
    spacenav   spacenav_node (USB, Linux only) + spacenav_to_servo.
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

_VALID_INPUTS = ("foxglove", "joy", "spacenav")


def _launch_setup(context, *args, **kwargs):
    sim_backend = LaunchConfiguration("sim_backend").perform(context)
    teleop_input = LaunchConfiguration("input").perform(context)
    variant = LaunchConfiguration("variant").perform(context) or "right_arm"

    if teleop_input not in _VALID_INPUTS:
        raise RuntimeError(
            f"Unknown input '{teleop_input}'. One of: {', '.join(_VALID_INPUTS)}."
        )

    nodes = [
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(
                os.path.join(
                    get_package_share_directory("fm_bringup"),
                    "launch",
                    "servo.launch.py",
                )
            ),
            launch_arguments={
                "sim_backend": sim_backend,
                "variant": variant,
            }.items(),
        )
    ]

    if teleop_input == "joy":
        nodes += [
            Node(package="joy", executable="joy_node", output="screen"),
            Node(package="fm_bringup", executable="joy_to_servo", output="screen"),
        ]
    elif teleop_input == "spacenav":
        nodes += [
            Node(package="spacenav", executable="spacenav_node", output="screen"),
            Node(package="fm_bringup", executable="spacenav_to_servo", output="screen"),
        ]
    # foxglove: the browser panel is the publisher; no ROS-side input node.

    return nodes


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "robot",
                default_value="openarm",
                description="Robot to teleop (openarm only for now).",
            ),
            DeclareLaunchArgument(
                "variant",
                default_value="right_arm",
                description="Preset; must match the running sim. Servo's SRDF + "
                "description follow it (right_arm or default_bimanual).",
            ),
            DeclareLaunchArgument(
                "sim_backend",
                default_value="mujoco",
                description="Backend the running target uses (parses the description).",
            ),
            DeclareLaunchArgument(
                "input",
                default_value="foxglove",
                description="foxglove | joy | spacenav.",
            ),
            OpaqueFunction(function=_launch_setup),
        ]
    )
