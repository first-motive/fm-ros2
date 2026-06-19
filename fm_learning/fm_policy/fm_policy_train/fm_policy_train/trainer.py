"""Minimal trainer node stub for fm_policy_train."""

import rclpy
from rclpy.node import Node


class Trainer(Node):
    """Placeholder node — replace with real fm_policy_train logic."""

    def __init__(self):
        super().__init__("trainer")
        self.get_logger().info("fm_policy_train trainer node up")


def main(args=None):
    rclpy.init(args=args)
    node = Trainer()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
