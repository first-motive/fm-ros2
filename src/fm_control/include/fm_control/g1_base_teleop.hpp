// Pure logic for the G1-D base teleop node, split out so it can be unit-tested
// without a running ROS graph. Builds the Unitree AGV "Move" RPC request from a
// commanded base velocity.
//
// The G1-D wheeled base is driven through Unitree's AGV service (unitree_sdk2
// AgvClient.Move(vx, vy, vyaw)), an RPC over a unitree_api/Request: api_id 1001 with a
// JSON {vx, vy, vyaw} parameter, sent to rt/api/agv/request. This path is separate
// from MoveIt Servo (which drives only the arm). Plumbed but UNTESTED — no hardware.
#ifndef FM_CONTROL__G1_BASE_TELEOP_HPP_
#define FM_CONTROL__G1_BASE_TELEOP_HPP_

#include <cstdint>
#include <cstdio>
#include <string>

#include <unitree_api/msg/request.hpp>

namespace fm_control
{

constexpr std::int64_t kAgvMoveApiId = 1001;  // ROBOT_API_ID_AGV_MOVE (g1_agv_api.hpp)

// JSON parameter for the AGV Move RPC, keyed exactly as unitree_sdk2's MoveParameter
// (vx, vy, vyaw) so the service deserialises it.
inline std::string move_request_json(double vx, double vy, double vyaw)
{
  char buf[128];
  std::snprintf(
    buf, sizeof(buf), "{\"vx\":%.6f,\"vy\":%.6f,\"vyaw\":%.6f}", vx, vy, vyaw);
  return std::string(buf);
}

// Build the AGV Move request: api_id 1001, the velocity as the JSON parameter.
inline unitree_api::msg::Request make_move_request(double vx, double vy, double vyaw)
{
  unitree_api::msg::Request req;
  req.header.identity.api_id = kAgvMoveApiId;
  req.parameter = move_request_json(vx, vy, vyaw);
  return req;
}

}  // namespace fm_control

#endif  // FM_CONTROL__G1_BASE_TELEOP_HPP_
