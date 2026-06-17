// Copyright 2026 First Motive
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// First Motive G1-D Dex3 hand bridge.
//
// The G1 has no upstream ros2_control hardware interface for the Dex3 hands, so the
// `real` backend drives them out-of-band: this node consumes the JointTrajectory streams
// the hand JTCs would receive and republishes each hand as a Unitree Dex3 command — a
// unitree_hg/HandCmd at 50 Hz on rt/dex3/{left,right}/cmd.
//
//   /g1_left_hand_controller/joint_trajectory  -> left-hand targets  -> rt/dex3/left/cmd
//   /g1_right_hand_controller/joint_trajectory -> right-hand targets -> rt/dex3/right/cmd
//        -> latest target position per finger joint
//        -> HandCmd.motor_cmd[0..6] (q + kp/kd, mode = packed id|status), at 50 Hz
//
// Mirrors unitree_ros2 example/src/src/g1/dex3/g1_dex3_example.cpp: 7 motors per hand,
// the mode byte packs the motor id + an enable status (see hand_motor_mode), gains follow
// the example's grip values (kp=1.5 / kd=0.1). Each hand is a separate HandCmd on its own
// topic, so the node owns two publishers. Reaching the real hands needs the Unitree
// CycloneDDS RMW so rt/dex3/* map to the Dex3 DDS topics; with the default RMW this
// publishes ordinary ROS2 topics. Plumbed but UNTESTED — no hardware yet.
//
// The command-building logic lives in include/fm_control/g1_hand_sdk_bridge.hpp so it can
// be unit-tested without a running ROS graph; this file is the node shell.

#include <chrono>
#include <memory>
#include <string>

#include <rclcpp/rclcpp.hpp>
#include <trajectory_msgs/msg/joint_trajectory.hpp>
#include <unitree_hg/msg/hand_cmd.hpp>

#include "fm_control/g1_hand_sdk_bridge.hpp"

namespace fm_control
{

class G1HandSdkBridge : public rclcpp::Node
{
public:
  G1HandSdkBridge()
  : Node("g1_hand_sdk_bridge")
  {
    left_input_topic_ = declare_parameter<std::string>(
      "left_input_topic", "/g1_left_hand_controller/joint_trajectory");
    right_input_topic_ = declare_parameter<std::string>(
      "right_input_topic", "/g1_right_hand_controller/joint_trajectory");
    // Default Dex3 topics for the real hands; point elsewhere to drive a sim/test sink.
    left_output_topic_ = declare_parameter<std::string>("left_output_topic", "rt/dex3/left/cmd");
    right_output_topic_ =
      declare_parameter<std::string>("right_output_topic", "rt/dex3/right/cmd");
    rate_hz_ = declare_parameter<double>("rate_hz", 50.0);
    kp_ = declare_parameter<double>("kp", 1.5);
    kd_ = declare_parameter<double>("kd", 0.1);

    left_targets_.fill(0.0);
    right_targets_.fill(0.0);

    left_cmd_pub_ = create_publisher<unitree_hg::msg::HandCmd>(left_output_topic_, 10);
    right_cmd_pub_ = create_publisher<unitree_hg::msg::HandCmd>(right_output_topic_, 10);

    left_traj_sub_ = create_subscription<trajectory_msgs::msg::JointTrajectory>(
      left_input_topic_, 10,
      [this](const trajectory_msgs::msg::JointTrajectory & msg) {
        on_trajectory(msg, kLeftHand, left_targets_, left_engaged_);
      });
    right_traj_sub_ = create_subscription<trajectory_msgs::msg::JointTrajectory>(
      right_input_topic_, 10,
      [this](const trajectory_msgs::msg::JointTrajectory & msg) {
        on_trajectory(msg, kRightHand, right_targets_, right_engaged_);
      });

    const auto period = std::chrono::duration<double>(1.0 / rate_hz_);
    timer_ = create_wall_timer(
      std::chrono::duration_cast<std::chrono::nanoseconds>(period),
      [this]() {on_timer();});

    RCLCPP_INFO(
      get_logger(), "g1_hand_sdk_bridge: %s + %s -> %s + %s at %.0f Hz (UNTESTED on hardware)",
      left_input_topic_.c_str(), right_input_topic_.c_str(), left_output_topic_.c_str(),
      right_output_topic_.c_str(), rate_hz_);
  }

private:
  void on_trajectory(
    const trajectory_msgs::msg::JointTrajectory & msg,
    const std::array<HandJoint, kHandMotorCount> & table,
    std::array<double, kHandMotorCount> & targets, bool & engaged)
  {
    if (msg.points.empty()) {
      return;
    }
    apply_hand_trajectory_point(targets, table, msg.joint_names, msg.points.back().positions);
    engaged = true;
  }

  void on_timer()
  {
    // Stay silent per hand until its first command, so a hand is not grabbed early.
    if (left_engaged_) {
      left_cmd_pub_->publish(make_hand_cmd(left_targets_, kp_, kd_));
    }
    if (right_engaged_) {
      right_cmd_pub_->publish(make_hand_cmd(right_targets_, kp_, kd_));
    }
  }

  std::string left_input_topic_;
  std::string right_input_topic_;
  std::string left_output_topic_;
  std::string right_output_topic_;
  double rate_hz_{50.0};
  double kp_{1.5};
  double kd_{0.1};

  std::array<double, kHandMotorCount> left_targets_{};
  std::array<double, kHandMotorCount> right_targets_{};
  bool left_engaged_{false};
  bool right_engaged_{false};

  rclcpp::Publisher<unitree_hg::msg::HandCmd>::SharedPtr left_cmd_pub_;
  rclcpp::Publisher<unitree_hg::msg::HandCmd>::SharedPtr right_cmd_pub_;
  rclcpp::Subscription<trajectory_msgs::msg::JointTrajectory>::SharedPtr left_traj_sub_;
  rclcpp::Subscription<trajectory_msgs::msg::JointTrajectory>::SharedPtr right_traj_sub_;
  rclcpp::TimerBase::SharedPtr timer_;
};

}  // namespace fm_control

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<fm_control::G1HandSdkBridge>());
  rclcpp::shutdown();
  return 0;
}
