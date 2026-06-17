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
// Unit tests for the G1-D Dex3 hand bridge command logic (no ROS graph needed).
#include <gtest/gtest.h>

#include <array>
#include <string>
#include <vector>

#include "fm_control/g1_hand_sdk_bridge.hpp"

using fm_control::apply_hand_trajectory_point;
using fm_control::hand_motor_mode;
using fm_control::kHandMotorCount;
using fm_control::kLeftHand;
using fm_control::kRightHand;
using fm_control::make_hand_cmd;

namespace
{
std::array<double, kHandMotorCount> zero_targets()
{
  std::array<double, kHandMotorCount> t{};
  t.fill(0.0);
  return t;
}
}  // namespace

TEST(G1HandSdkBridge, MapsTargetsToMotorIndices)
{
  // 7 finger targets land on motor_cmd[0..6] in order.
  auto cmd = make_hand_cmd({0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7}, /*kp=*/ 1.5, /*kd=*/ 0.1);
  ASSERT_EQ(cmd.motor_cmd.size(), kHandMotorCount);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[0].q, 0.1F);  // thumb_0
  EXPECT_FLOAT_EQ(cmd.motor_cmd[2].q, 0.3F);  // thumb_2
  EXPECT_FLOAT_EQ(cmd.motor_cmd[6].q, 0.7F);  // index_1
}

TEST(G1HandSdkBridge, AppliesGainsToEveryMotor)
{
  auto cmd = make_hand_cmd(zero_targets(), 1.5, 0.1);
  for (std::size_t m = 0; m < kHandMotorCount; ++m) {
    EXPECT_FLOAT_EQ(cmd.motor_cmd[m].kp, 1.5F);
    EXPECT_FLOAT_EQ(cmd.motor_cmd[m].kd, 0.1F);
  }
}

TEST(G1HandSdkBridge, ModeBytePacksIdAndEnableStatus)
{
  // bits 0-3 = motor id, bits 4-6 = status (0x01 enable): mode = id | (1 << 4).
  EXPECT_EQ(hand_motor_mode(0), 0x10);
  EXPECT_EQ(hand_motor_mode(3), 0x13);
  EXPECT_EQ(hand_motor_mode(6), 0x16);
  // The built command carries the same packed mode per motor.
  auto cmd = make_hand_cmd(zero_targets(), 1.5, 0.1);
  EXPECT_EQ(cmd.motor_cmd[5].mode, hand_motor_mode(5));
}

TEST(G1HandSdkBridge, LeftTrajectoryMatchedByNameNotOrder)
{
  auto targets = zero_targets();
  // Reversed + partial: index_0 (motor 5) + thumb_2 (motor 2), out of order.
  apply_hand_trajectory_point(
    targets, kLeftHand, {"left_hand_index_0_joint", "left_hand_thumb_2_joint"}, {0.4, 0.9});
  EXPECT_DOUBLE_EQ(targets[5], 0.4);  // left_hand_index_0_joint
  EXPECT_DOUBLE_EQ(targets[2], 0.9);  // left_hand_thumb_2_joint
  EXPECT_DOUBLE_EQ(targets[0], 0.0);  // untouched
}

TEST(G1HandSdkBridge, RightTrajectoryMapsToOwnTable)
{
  auto targets = zero_targets();
  apply_hand_trajectory_point(
    targets, kRightHand, {"right_hand_middle_1_joint"}, {0.5});
  EXPECT_DOUBLE_EQ(targets[4], 0.5);  // right_hand_middle_1_joint
}

TEST(G1HandSdkBridge, OtherHandAndArmJointsIgnored)
{
  // A left-hand trajectory does not disturb the right-hand targets, and arm joints
  // are not in either table.
  auto targets = zero_targets();
  apply_hand_trajectory_point(
    targets, kRightHand,
    {"left_hand_thumb_0_joint", "right_elbow_joint"}, {1.0, 2.0});
  for (double t : targets) {
    EXPECT_DOUBLE_EQ(t, 0.0);
  }
}
