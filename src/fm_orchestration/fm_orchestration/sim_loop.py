"""Headless MuJoCo sim loop for control / orchestration dev.

Runs native arm64 on M5 (CPU, no GPU). Steps a MuJoCo model and publishes
sensor_msgs/JointState so the rest of the graph (and Foxglove) sees sim joints.
Falls back to a built-in 1-DOF model when no MJCF path is given.
"""

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import JointState

# A minimal MJCF so the loop runs with zero assets — replace via the `model_path` param.
_DEFAULT_MJCF = """
<mujoco>
  <worldbody>
    <body name="link" pos="0 0 0">
      <joint name="joint0" type="hinge" axis="0 0 1"/>
      <geom type="capsule" size="0.02 0.1"/>
    </body>
  </worldbody>
</mujoco>
"""


class SimLoop(Node):
    """Step MuJoCo and publish joint states at a fixed rate."""

    def __init__(self):
        super().__init__("sim_loop")
        self.declare_parameter("model_path", "")
        self.declare_parameter("rate_hz", 100.0)

        import mujoco  # imported lazily so the package loads without mujoco installed

        path = self.get_parameter("model_path").get_parameter_value().string_value
        if path:
            self.model = mujoco.MjModel.from_xml_path(path)
        else:
            self.model = mujoco.MjModel.from_xml_string(_DEFAULT_MJCF)
        self.data = mujoco.MjData(self.model)
        self._mujoco = mujoco

        self.pub = self.create_publisher(JointState, "joint_states", 10)
        rate = self.get_parameter("rate_hz").get_parameter_value().double_value
        self.timer = self.create_timer(1.0 / rate, self._step)
        self.joint_names = [
            mujoco.mj_id2name(self.model, mujoco.mjtObj.mjOBJ_JOINT, i)
            for i in range(self.model.njnt)
        ]
        self.get_logger().info(f"sim_loop up: {self.model.njnt} joints @ {rate} Hz")

    def _step(self):
        self._mujoco.mj_step(self.model, self.data)
        msg = JointState()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.name = self.joint_names
        msg.position = list(self.data.qpos)
        msg.velocity = list(self.data.qvel)
        self.pub.publish(msg)


def main(args=None):
    rclpy.init(args=args)
    node = SimLoop()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
