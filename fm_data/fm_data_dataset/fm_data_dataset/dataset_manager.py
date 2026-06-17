"""Minimal dataset_manager node stub for fm_data_dataset."""

import rclpy
from rclpy.node import Node


class DatasetManager(Node):
    """Placeholder node — replace with real fm_data_dataset logic."""

    def __init__(self):
        super().__init__("dataset_manager")
        self.get_logger().info("fm_data_dataset dataset_manager node up")


def main(args=None):
    rclpy.init(args=args)
    node = DatasetManager()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
