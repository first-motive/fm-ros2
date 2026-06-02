"""Minimal bringup node stub for fm_bringup."""

import rclpy
from rclpy.node import Node


class Bringup(Node):
    """Placeholder node — replace with real fm_bringup logic."""

    def __init__(self):
        super().__init__("bringup")
        self.get_logger().info("fm_bringup bringup node up")


def main(args=None):
    rclpy.init(args=args)
    node = Bringup()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
