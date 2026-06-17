"""Minimal recorder node stub for fm_data_record."""

import rclpy
from rclpy.node import Node


class Recorder(Node):
    """Placeholder node — replace with real fm_data_record logic."""

    def __init__(self):
        super().__init__("recorder")
        self.get_logger().info("fm_data_record recorder node up")


def main(args=None):
    rclpy.init(args=args)
    node = Recorder()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
