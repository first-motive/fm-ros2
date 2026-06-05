"""MoveIt Servo for the OpenArm — Cartesian + joint jogging of the right arm.

Brings up servo_node with the MoveIt context it needs: the robot_description (built
from the fm_control backend-selectable xacro), the vendored bimanual SRDF +
kinematics + joint limits, and servo.yaml. Servo subscribes /joint_states, turns
delta twist / joint commands into a streamed JointTrajectory, and publishes it to the
right arm's JTC.

Reuses openarm_bimanual_moveit_config so no SRDF is hand-authored. Teleop inputs
publish onto servo_node/delta_twist_cmds and servo_node/delta_joint_cmds (see
teleop.launch.py). Started automatically via the start_servo trigger below.
"""

import os

import xacro
import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, OpaqueFunction, TimerAction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

# The vendored MoveIt config is bimanual v2.0; Servo drives its right_arm group.
_MOVEIT_PKG = "openarm_bimanual_moveit_config"
_MOVEIT_CFG = os.path.join("config", "openarm_v2.0")
_SERVO_VARIANT = "default_bimanual"


def _load_yaml(abs_path):
    with open(abs_path, "r") as handle:
        return yaml.safe_load(handle)


def _moveit_file(name):
    return os.path.join(get_package_share_directory(_MOVEIT_PKG), _MOVEIT_CFG, name)


def _launch_setup(context, *args, **kwargs):
    sim_backend = LaunchConfiguration("sim_backend").perform(context)

    # Description for the planning scene. The <ros2_control> plugin is irrelevant to
    # Servo; only links/joints/collisions matter, so any backend parses fine.
    xacro_path = os.path.join(
        get_package_share_directory("fm_control"), "urdf", "openarm.sim.urdf.xacro"
    )
    robot_description = xacro.process_file(
        xacro_path, mappings={"robot_preset": _SERVO_VARIANT, "sim_backend": sim_backend}
    ).toxml()

    with open(_moveit_file("openarm_bimanual.srdf"), "r") as handle:
        robot_description_semantic = handle.read()

    kinematics = _load_yaml(_moveit_file("kinematics.yaml"))
    joint_limits = _load_yaml(_moveit_file("joint_limits.yaml"))
    servo_yaml = _load_yaml(
        os.path.join(
            get_package_share_directory("fm_bringup"),
            "config",
            "openarm",
            "servo.yaml",
        )
    )

    servo_node = Node(
        package="moveit_servo",
        executable="servo_node_main",
        output="screen",
        parameters=[
            {"moveit_servo": servo_yaml["moveit_servo"]},
            {"robot_description": robot_description},
            {"robot_description_semantic": robot_description_semantic},
            {"robot_description_kinematics": kinematics},
            {"robot_description_planning": joint_limits},
        ],
    )

    # servo_node starts paused; trigger it once it is up.
    start_servo = TimerAction(
        period=3.0,
        actions=[
            ExecuteProcess(
                cmd=[
                    "ros2",
                    "service",
                    "call",
                    "/servo_node/start_servo",
                    "std_srvs/srv/Trigger",
                    "{}",
                ],
                output="screen",
            )
        ],
    )

    return [servo_node, start_servo]


def generate_launch_description():
    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "sim_backend",
                default_value="mujoco",
                description="Backend the description is built for (parses under any).",
            ),
            OpaqueFunction(function=_launch_setup),
        ]
    )
