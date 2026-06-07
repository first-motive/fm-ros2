// Unit tests for the G1-D base teleop request logic (no ROS graph needed).
#include <string>

#include <gtest/gtest.h>

#include "fm_control/g1_base_teleop.hpp"

using fm_control::kAgvMoveApiId;
using fm_control::make_move_request;
using fm_control::move_request_json;

TEST(G1BaseTeleop, JsonCarriesVelocityKeys)
{
  // %.6f is deterministic, so assert the exact serialised form.
  EXPECT_EQ(
    move_request_json(0.3, -0.1, 0.2),
    "{\"vx\":0.300000,\"vy\":-0.100000,\"vyaw\":0.200000}");
}

TEST(G1BaseTeleop, RequestUsesMoveApiId)
{
  const auto req = make_move_request(0.0, 0.0, 0.0);
  EXPECT_EQ(req.header.identity.api_id, kAgvMoveApiId);
  EXPECT_EQ(kAgvMoveApiId, 1001);
}

TEST(G1BaseTeleop, RequestParameterMatchesJson)
{
  const auto req = make_move_request(0.5, 0.0, -0.4);
  EXPECT_EQ(req.parameter, move_request_json(0.5, 0.0, -0.4));
}
