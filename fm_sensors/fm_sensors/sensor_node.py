"""Minimal sensor node stub for fm_sensors."""

import rclpy
from rclpy.node import Node


class SensorNode(Node):
    """Placeholder node — replace with real multi-sensor capture logic."""

    def __init__(self):
        super().__init__("sensor_node")
        self.get_logger().info("fm_sensors sensor node up (capture placeholder)")


def main(args=None):
    rclpy.init(args=args)
    node = SensorNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
