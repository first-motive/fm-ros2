// Minimal control_node stub for fm_control.
// Replace with the real ros2_control hardware interface.
#include "rclcpp/rclcpp.hpp"

class ControlNode : public rclcpp::Node
{
public:
  ControlNode() : Node("control_node")
  {
    RCLCPP_INFO(this->get_logger(), "fm_control control_node up");
  }
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<ControlNode>());
  rclcpp::shutdown();
  return 0;
}
