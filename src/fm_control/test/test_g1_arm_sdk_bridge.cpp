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
// Unit tests for the G1-D arm_sdk bridge command logic (no ROS graph needed).
#include <gtest/gtest.h>

#include <array>
#include <string>
#include <vector>

#include "fm_control/g1_arm_sdk_bridge.hpp"

using fm_control::apply_trajectory_point;
using fm_control::kArms;
using fm_control::kWeightMotorIndex;
using fm_control::make_low_cmd;
using fm_control::ramp_weight;

namespace
{
std::array<double, kArms.size()> zero_targets()
{
  std::array<double, kArms.size()> t{};
  t.fill(0.0);
  return t;
}
}  // namespace

TEST(G1ArmSdkBridge, MapsRightArmJointsByNameToMotorIndices)
{
  // kArms order: right arm in slots 0..6, values land on motors 22..28.
  auto t = zero_targets();
  t[0] = 0.1;  // right_shoulder_pitch
  t[3] = 0.4;  // right_elbow
  t[6] = 0.7;  // right_wrist_yaw
  auto cmd = make_low_cmd(t, /*weight=*/ 1.0, /*kp=*/ 60.0, /*kd=*/ 1.5);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[22].q, 0.1F);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[25].q, 0.4F);  // right_elbow_joint
  EXPECT_FLOAT_EQ(cmd.motor_cmd[28].q, 0.7F);  // right_wrist_yaw_joint
}

TEST(G1ArmSdkBridge, MapsLeftArmJointsByNameToMotorIndices)
{
  // kArms order: left arm in slots 7..13, values land on motors 15..21.
  auto t = zero_targets();
  t[7] = 0.1;   // left_shoulder_pitch
  t[10] = 0.4;  // left_elbow
  t[13] = 0.7;  // left_wrist_yaw
  auto cmd = make_low_cmd(t, /*weight=*/ 1.0, 60.0, 1.5);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[15].q, 0.1F);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[18].q, 0.4F);  // left_elbow_joint
  EXPECT_FLOAT_EQ(cmd.motor_cmd[21].q, 0.7F);  // left_wrist_yaw_joint
}

TEST(G1ArmSdkBridge, AppliesGainsAndEnableMode)
{
  auto cmd = make_low_cmd(zero_targets(), 1.0, 60.0, 1.5);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[22].kp, 60.0F);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[22].kd, 1.5F);
  EXPECT_EQ(cmd.motor_cmd[22].mode, fm_control::kMotorModeEnable);
}

TEST(G1ArmSdkBridge, WeightRidesMotor29AndUntouchedMotorsStayZero)
{
  auto cmd = make_low_cmd(zero_targets(), /*weight=*/ 0.42, 60.0, 1.5);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[kWeightMotorIndex].q, 0.42F);
  // A non-arm motor (left leg) is never commanded.
  EXPECT_FLOAT_EQ(cmd.motor_cmd[0].q, 0.0F);
  EXPECT_EQ(cmd.motor_cmd[0].mode, 0);
  EXPECT_EQ(cmd.crc, 0U);
}

TEST(G1ArmSdkBridge, TrajectoryMatchedByNameNotOrder)
{
  auto targets = zero_targets();
  // Reversed + partial: only elbow + wrist_yaw, out of chain order.
  apply_trajectory_point(
    targets, {"right_wrist_yaw_joint", "right_elbow_joint"}, {-0.3, 0.5});
  // index 3 = right_elbow_joint, index 6 = right_wrist_yaw_joint in kArms order.
  EXPECT_DOUBLE_EQ(targets[3], 0.5);
  EXPECT_DOUBLE_EQ(targets[6], -0.3);
  // Untouched joints stay at zero.
  EXPECT_DOUBLE_EQ(targets[0], 0.0);
}

TEST(G1ArmSdkBridge, OneArmTrajectoryLeavesTheOtherArmUntouched)
{
  // A left-arm trajectory updates only the left slice (slots 7..13); the right slice
  // (slots 0..6) stays zero — the two arms' streams do not interfere.
  auto targets = zero_targets();
  apply_trajectory_point(targets, {"left_elbow_joint"}, {0.9});
  EXPECT_DOUBLE_EQ(targets[10], 0.9);  // left_elbow
  for (std::size_t i = 0; i < 7; ++i) {
    EXPECT_DOUBLE_EQ(targets[i], 0.0);  // right arm untouched
  }
}

TEST(G1ArmSdkBridge, TrajectoryIgnoresUnknownJoints)
{
  auto targets = zero_targets();
  // Neither a leg nor a waist joint is in the arm table.
  apply_trajectory_point(targets, {"waist_yaw_joint", "left_hip_pitch_joint"}, {1.0, 2.0});
  for (double t : targets) {
    EXPECT_DOUBLE_EQ(t, 0.0);
  }
}

TEST(G1ArmSdkBridge, WeightRampClampsAtOne)
{
  EXPECT_DOUBLE_EQ(ramp_weight(0.0, 0.25), 0.25);
  EXPECT_DOUBLE_EQ(ramp_weight(0.9, 0.25), 1.0);  // clamped
  EXPECT_DOUBLE_EQ(ramp_weight(1.0, 0.25), 1.0);
}
