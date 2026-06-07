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
// Pure logic for the G1-D Servo -> arm_sdk bridge, split from the node so it can be
// unit-tested without spinning ROS. The node (src/g1_arm_sdk_bridge.cpp) owns the
// subscription, timer, and parameters; everything here is free functions over plain
// data + the unitree_hg/LowCmd message.
#ifndef FM_CONTROL__G1_ARM_SDK_BRIDGE_HPP_
#define FM_CONTROL__G1_ARM_SDK_BRIDGE_HPP_

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include <unitree_hg/msg/low_cmd.hpp>

namespace fm_control
{

// Right-arm joint -> arm_sdk motor_cmd index (unitree_sdk2 JointIndex enum).
struct ArmJoint
{
  const char * name;
  std::size_t motor_index;
};

constexpr std::array<ArmJoint, 7> kRightArm{{
  {"right_shoulder_pitch_joint", 22},
  {"right_shoulder_roll_joint", 23},
  {"right_shoulder_yaw_joint", 24},
  {"right_elbow_joint", 25},
  {"right_wrist_roll_joint", 26},
  {"right_wrist_pitch_joint", 27},
  {"right_wrist_yaw_joint", 28},
}};

constexpr std::size_t kWeightMotorIndex = 29;  // kNotUsedJoint: engagement weight
constexpr std::size_t kMotorCount = 35;        // LowCmd.motor_cmd is fixed at 35
constexpr std::uint8_t kMotorModeEnable = 1;   // PMSM enable

static_assert(kWeightMotorIndex < kMotorCount, "weight motor index out of range");

// Update per-arm targets from a (possibly reordered or partial) trajectory point,
// matched by joint name so each value lands on the right motor regardless of order.
inline void apply_trajectory_point(
  std::array<double, kRightArm.size()> & targets,
  const std::vector<std::string> & joint_names,
  const std::vector<double> & positions)
{
  for (std::size_t i = 0; i < joint_names.size() && i < positions.size(); ++i) {
    for (std::size_t a = 0; a < kRightArm.size(); ++a) {
      if (joint_names[i] == kRightArm[a].name) {
        targets[a] = positions[i];
        break;
      }
    }
  }
}

// One step of the engagement-weight ramp, clamped to [0, 1].
inline double ramp_weight(double current, double step)
{
  return std::min(1.0, current + step);
}

// Build the arm_sdk LowCmd: arm targets on motor_cmd[22..28] with the given gains,
// the engagement weight on motor_cmd[29]. Untouched motors stay zero (mode 0). No CRC
// — the arm_sdk path does not use it (see the node header).
inline unitree_hg::msg::LowCmd make_low_cmd(
  const std::array<double, kRightArm.size()> & targets, double weight, double kp, double kd)
{
  unitree_hg::msg::LowCmd cmd;  // motor_cmd is a fixed std::array<MotorCmd, 35>
  for (std::size_t a = 0; a < kRightArm.size(); ++a) {
    auto & m = cmd.motor_cmd[kRightArm[a].motor_index];
    m.mode = kMotorModeEnable;
    m.q = static_cast<float>(targets[a]);
    m.dq = 0.0F;
    m.tau = 0.0F;
    m.kp = static_cast<float>(kp);
    m.kd = static_cast<float>(kd);
  }
  cmd.motor_cmd[kWeightMotorIndex].q = static_cast<float>(weight);
  cmd.crc = 0;
  return cmd;
}

}  // namespace fm_control

#endif  // FM_CONTROL__G1_ARM_SDK_BRIDGE_HPP_
