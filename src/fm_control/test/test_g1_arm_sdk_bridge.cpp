// Unit tests for the G1-D arm_sdk bridge command logic (no ROS graph needed).
#include <array>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "fm_control/g1_arm_sdk_bridge.hpp"

using fm_control::apply_trajectory_point;
using fm_control::kRightArm;
using fm_control::kWeightMotorIndex;
using fm_control::make_low_cmd;
using fm_control::ramp_weight;

namespace
{
std::array<double, kRightArm.size()> zero_targets()
{
  std::array<double, kRightArm.size()> t{};
  t.fill(0.0);
  return t;
}
}  // namespace

TEST(G1ArmSdkBridge, MapsJointsByNameToMotorIndices)
{
  auto cmd = make_low_cmd(
    {0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7}, /*weight=*/1.0, /*kp=*/60.0, /*kd=*/1.5);
  // shoulder_pitch -> 22 ... wrist_yaw -> 28, in chain order.
  EXPECT_FLOAT_EQ(cmd.motor_cmd[22].q, 0.1F);
  EXPECT_FLOAT_EQ(cmd.motor_cmd[25].q, 0.4F);  // right_elbow_joint
  EXPECT_FLOAT_EQ(cmd.motor_cmd[28].q, 0.7F);  // right_wrist_yaw_joint
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
  auto cmd = make_low_cmd(zero_targets(), /*weight=*/0.42, 60.0, 1.5);
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
  // index 3 = right_elbow_joint, index 6 = right_wrist_yaw_joint in kRightArm order.
  EXPECT_DOUBLE_EQ(targets[3], 0.5);
  EXPECT_DOUBLE_EQ(targets[6], -0.3);
  // Untouched joints stay at zero.
  EXPECT_DOUBLE_EQ(targets[0], 0.0);
}

TEST(G1ArmSdkBridge, TrajectoryIgnoresUnknownJoints)
{
  auto targets = zero_targets();
  apply_trajectory_point(targets, {"left_elbow_joint", "waist_yaw_joint"}, {1.0, 2.0});
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
