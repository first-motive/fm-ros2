"""Minimal server node stub for fm_vlta_serve."""

import rclpy
from rclpy.node import Node


class Server(Node):
    """Placeholder node — replace with real fm_vlta_serve logic."""

    def __init__(self):
        super().__init__("server")
        self.get_logger().info("fm_vlta_serve server node up")


def main(args=None):
    rclpy.init(args=args)
    node = Server()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
