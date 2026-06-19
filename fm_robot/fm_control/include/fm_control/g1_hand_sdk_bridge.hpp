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
// Pure logic for the G1-D Dex3 hand bridge, split from the node so it can be unit-tested
// without spinning ROS. The node (src/g1_hand_sdk_bridge.cpp) owns the subscriptions (one
// per hand), timer, and parameters; everything here is free functions over plain data +
// the unitree_hg/HandCmd message. Each hand has its own HandCmd on its own DDS topic
// (rt/dex3/{left,right}/cmd), 7 finger motors each.
#ifndef FM_CONTROL__G1_HAND_SDK_BRIDGE_HPP_
#define FM_CONTROL__G1_HAND_SDK_BRIDGE_HPP_

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include <unitree_hg/msg/hand_cmd.hpp>

namespace fm_control
{

// Dex3 finger joint -> HandCmd motor_cmd index. Each hand has its own HandCmd, so the
// motor indices restart at 0 per hand. The order matches the Dex3 motor index order used
// by g1_dex3_example + the JTC joint order + the vendored URDF: thumb 0..2, middle 0..1,
// index 0..1.
struct HandJoint
{
  const char * name;
  std::size_t motor_index;
};

constexpr std::size_t kHandMotorCount = 7;

constexpr std::array<HandJoint, kHandMotorCount> kLeftHand{{
  {"left_hand_thumb_0_joint", 0},
  {"left_hand_thumb_1_joint", 1},
  {"left_hand_thumb_2_joint", 2},
  {"left_hand_middle_0_joint", 3},
  {"left_hand_middle_1_joint", 4},
  {"left_hand_index_0_joint", 5},
  {"left_hand_index_1_joint", 6},
}};

constexpr std::array<HandJoint, kHandMotorCount> kRightHand{{
  {"right_hand_thumb_0_joint", 0},
  {"right_hand_thumb_1_joint", 1},
  {"right_hand_thumb_2_joint", 2},
  {"right_hand_middle_0_joint", 3},
  {"right_hand_middle_1_joint", 4},
  {"right_hand_index_0_joint", 5},
  {"right_hand_index_1_joint", 6},
}};

constexpr std::uint8_t kHandStatusEnable = 0x01;  // RisMode status: enable

// Dex3 packs the motor id + status + timeout into the mode byte (see g1_dex3_example):
// bits 0-3 = motor id, bits 4-6 = status, bit 7 = timeout. We enable each motor with its
// own id and no timeout.
inline std::uint8_t hand_motor_mode(std::size_t motor_index)
{
  return static_cast<std::uint8_t>(
    (motor_index & 0x0F) | ((kHandStatusEnable & 0x07) << 4));
}

// Update one hand's targets from a (possibly reordered or partial) trajectory point,
// matched by joint name against that hand's table so each value lands on the right motor.
// Unknown names (the other hand, the arms) are ignored.
inline void apply_hand_trajectory_point(
  std::array<double, kHandMotorCount> & targets,
  const std::array<HandJoint, kHandMotorCount> & table,
  const std::vector<std::string> & joint_names,
  const std::vector<double> & positions)
{
  for (std::size_t i = 0; i < joint_names.size() && i < positions.size(); ++i) {
    for (std::size_t m = 0; m < kHandMotorCount; ++m) {
      if (joint_names[i] == table[m].name) {
        targets[table[m].motor_index] = positions[i];
        break;
      }
    }
  }
}

// Build one hand's HandCmd: the 7 finger targets on motor_cmd[0..6] with the given gains,
// each motor enabled via its packed mode byte. dq/tau are zero (position hold).
inline unitree_hg::msg::HandCmd make_hand_cmd(
  const std::array<double, kHandMotorCount> & targets, double kp, double kd)
{
  unitree_hg::msg::HandCmd cmd;
  cmd.motor_cmd.resize(kHandMotorCount);  // HandCmd.motor_cmd is a dynamic vector
  for (std::size_t m = 0; m < kHandMotorCount; ++m) {
    auto & mc = cmd.motor_cmd[m];
    mc.mode = hand_motor_mode(m);
    mc.q = static_cast<float>(targets[m]);
    mc.dq = 0.0F;
    mc.tau = 0.0F;
    mc.kp = static_cast<float>(kp);
    mc.kd = static_cast<float>(kd);
  }
  return cmd;
}

}  // namespace fm_control

#endif  // FM_CONTROL__G1_HAND_SDK_BRIDGE_HPP_
