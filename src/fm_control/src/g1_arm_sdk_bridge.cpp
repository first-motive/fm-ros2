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
// First Motive G1-D Servo -> arm_sdk bridge.
//
// The G1 has no upstream ros2_control hardware interface, so the `real` backend does
// not run a controller_manager. Instead this node replaces the controller + hardware:
// it consumes the JointTrajectory MoveIt Servo streams for the right arm and republishes
// it as the Unitree arm_sdk command — a unitree_hg/LowCmd at 50 Hz on rt/arm_sdk.
//
//   /g1_right_arm_controller/joint_trajectory (Servo)
//        -> latest target position per right-arm joint
//        -> LowCmd.motor_cmd[22..28] (q + kp/kd), at 50 Hz
//        -> engagement weight ramped 0->1 on motor_cmd[29].q
//        -> rt/arm_sdk
//
// Mirrors unitree_sdk2 example/g1/high_level/g1_arm7_sdk_dds_example.cpp: the 7 right-arm
// joints map to motor_cmd indices 22..28, the engagement weight rides motor_cmd[29]
// (kNotUsedJoint), the loop runs at 50 Hz, gains are kp=60 / kd=1.5. Like that example,
// no CRC is set: the arm_sdk service does not require it (only the raw rt/lowcmd path
// does), and a CRC over the ROS2 message would be meaningless once the RMW re-serializes.
//
// Reaching the real robot needs the Unitree CycloneDDS RMW so rt/arm_sdk maps to the
// arm_sdk DDS topic; with the default RMW this publishes an ordinary ROS2 topic, which
// is what the build + the unitree_mujoco loop see. Plumbed but UNTESTED — no hardware yet.
//
// The command-building logic lives in include/fm_control/g1_arm_sdk_bridge.hpp so it can
// be unit-tested without a running ROS graph; this file is the node shell.

#include <chrono>
#include <memory>
#include <string>

#include <rclcpp/rclcpp.hpp>
#include <trajectory_msgs/msg/joint_trajectory.hpp>
#include <unitree_hg/msg/low_cmd.hpp>

#include "fm_control/g1_arm_sdk_bridge.hpp"

namespace fm_control
{

class G1ArmSdkBridge : public rclcpp::Node
{
public:
  G1ArmSdkBridge()
  : Node("g1_arm_sdk_bridge")
  {
    input_topic_ = declare_parameter<std::string>(
      "input_topic", "/g1_right_arm_controller/joint_trajectory");
    // Default arm_sdk topic for the real arm; point at rt/lowcmd to drive unitree_mujoco.
    output_topic_ = declare_parameter<std::string>("output_topic", "rt/arm_sdk");
    rate_hz_ = declare_parameter<double>("rate_hz", 50.0);
    kp_ = declare_parameter<double>("kp", 60.0);
    kd_ = declare_parameter<double>("kd", 1.5);
    // Weight ramps 0->1 over ~weight_ramp_seconds once commands start flowing, engaging
    // the arm gradually rather than snapping it to the first target.
    weight_ramp_seconds_ = declare_parameter<double>("weight_ramp_seconds", 1.0);

    targets_.fill(0.0);

    cmd_pub_ = create_publisher<unitree_hg::msg::LowCmd>(output_topic_, 10);
    traj_sub_ = create_subscription<trajectory_msgs::msg::JointTrajectory>(
      input_topic_, 10,
      [this](const trajectory_msgs::msg::JointTrajectory & msg) {on_trajectory(msg);});

    const auto period = std::chrono::duration<double>(1.0 / rate_hz_);
    timer_ = create_wall_timer(
      std::chrono::duration_cast<std::chrono::nanoseconds>(period),
      [this]() {on_timer();});

    RCLCPP_INFO(
      get_logger(), "g1_arm_sdk_bridge: %s -> %s at %.0f Hz (UNTESTED on hardware)",
      input_topic_.c_str(), output_topic_.c_str(), rate_hz_);
  }

private:
  void on_trajectory(const trajectory_msgs::msg::JointTrajectory & msg)
  {
    if (msg.points.empty()) {
      return;
    }
    const auto & point = msg.points.back();
    apply_trajectory_point(targets_, msg.joint_names, point.positions);
    engaged_ = true;
  }

  void on_timer()
  {
    if (!engaged_) {
      return;  // stay silent until the first command, so the arm is not grabbed early
    }
    weight_ = ramp_weight(weight_, weight_step());
    cmd_pub_->publish(make_low_cmd(targets_, weight_, kp_, kd_));
  }

  double weight_step() const
  {
    if (weight_ramp_seconds_ <= 0.0) {
      return 1.0;  // engage immediately
    }
    return 1.0 / (weight_ramp_seconds_ * rate_hz_);
  }

  std::string input_topic_;
  std::string output_topic_;
  double rate_hz_{50.0};
  double kp_{60.0};
  double kd_{1.5};
  double weight_ramp_seconds_{1.0};

  std::array<double, kRightArm.size()> targets_{};
  double weight_{0.0};
  bool engaged_{false};

  rclcpp::Publisher<unitree_hg::msg::LowCmd>::SharedPtr cmd_pub_;
  rclcpp::Subscription<trajectory_msgs::msg::JointTrajectory>::SharedPtr traj_sub_;
  rclcpp::TimerBase::SharedPtr timer_;
};

}  // namespace fm_control

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<fm_control::G1ArmSdkBridge>());
  rclcpp::shutdown();
  return 0;
}
