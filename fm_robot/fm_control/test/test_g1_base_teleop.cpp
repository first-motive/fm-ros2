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
// Unit tests for the G1-D base teleop request logic (no ROS graph needed).
#include <gtest/gtest.h>

#include <string>

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
