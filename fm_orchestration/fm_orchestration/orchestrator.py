"""Minimal orchestrator node stub for fm_orchestration."""

import rclpy
from rclpy.node import Node


class Orchestrator(Node):
    """Placeholder node — replace with real fm_orchestration logic."""

    def __init__(self):
        super().__init__("orchestrator")
        self.get_logger().info("fm_orchestration orchestrator node up")


def main(args=None):
    rclpy.init(args=args)
    node = Orchestrator()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
