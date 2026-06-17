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
// First Motive G1-D base teleop.
//
// Drives the wheeled G1-D base from a Twist, separate from MoveIt Servo (which jogs
// only the arm). Each Twist becomes a Unitree AGV "Move" RPC:
//
//   /cmd_vel (geometry_msgs/Twist)
//        -> vx = linear.x, vy = linear.y, vyaw = angular.z
//        -> unitree_api/Request (api_id 1001, JSON {vx, vy, vyaw})
//        -> rt/api/agv/request
//
// Mirrors unitree_sdk2 example/g1/g1d/g1_agv_client_example.cpp (AgvClient.Move). The
// base + arm-mount geometry already lives in the vendored g1_d URDF (AGV_link root ->
// torso_link -> arms), so this step adds only the command path. Reaching the real base
// needs the Unitree CycloneDDS RMW so rt/api/agv/request maps to the AGV service.
// Plumbed but UNTESTED — no hardware yet.
//
// The request-building logic lives in include/fm_control/g1_base_teleop.hpp so it can
// be unit-tested without a running ROS graph; this file is the node shell.

#include <memory>
#include <string>

#include <geometry_msgs/msg/twist.hpp>
#include <rclcpp/rclcpp.hpp>
#include <unitree_api/msg/request.hpp>

#include "fm_control/g1_base_teleop.hpp"

namespace fm_control
{

class G1BaseTeleop : public rclcpp::Node
{
public:
  G1BaseTeleop()
  : Node("g1_base_teleop")
  {
    input_topic_ = declare_parameter<std::string>("input_topic", "/cmd_vel");
    output_topic_ = declare_parameter<std::string>("output_topic", "rt/api/agv/request");

    req_pub_ = create_publisher<unitree_api::msg::Request>(output_topic_, 10);
    twist_sub_ = create_subscription<geometry_msgs::msg::Twist>(
      input_topic_, 10,
      [this](const geometry_msgs::msg::Twist & msg) {
        req_pub_->publish(make_move_request(msg.linear.x, msg.linear.y, msg.angular.z));
      });

    RCLCPP_INFO(
      get_logger(), "g1_base_teleop: %s -> %s (AGV Move; UNTESTED on hardware)",
      input_topic_.c_str(), output_topic_.c_str());
  }

private:
  std::string input_topic_;
  std::string output_topic_;
  rclcpp::Publisher<unitree_api::msg::Request>::SharedPtr req_pub_;
  rclcpp::Subscription<geometry_msgs::msg::Twist>::SharedPtr twist_sub_;
};

}  // namespace fm_control

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<fm_control::G1BaseTeleop>());
  rclcpp::shutdown();
  return 0;
}
