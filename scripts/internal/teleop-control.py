#!/usr/bin/env python3
"""Read and control the teleoperation topics owned by the assembled rig.

The engage and reset owners expose command topics only.  A successful publish
therefore means *dispatched*, not *completed*.  Wrist swap has a real owner
state topic, so it can report an observed state, without request correlation. Glove testing is
the same local peak observer as Desktop and does not publish a new command.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time

DOMAIN = "teleop-control"
VISION_ENGAGE_TOPIC = "/vision/engage"
VISION_RESET_TOPIC = "/vision/reset"
WRIST_SWAP_TOPIC = "/camera/wrist_swap"
WRIST_SWAP_STATE_TOPIC = "/camera/wrist_swap_state"
TRACKING_TOPIC = "/vision/tracking_active"
GLOVE_TOPICS = {"left": "/glove_left/tactile", "right": "/glove_right/tactile"}
BOOL_TYPE = "std_msgs/msg/Bool"
TACTILE_TYPE = "fm_tactile_msgs/msg/TactileSample"
PRESS_THRESHOLD = 100
MAX_TIMEOUT = 120.0
MAX_GLOVE_DURATION = 60.0
GLOVE_CHANNELS = 5
ACTION_ALIASES = {
    "wrist-swap": "swap",
    "wristswap": "swap",
    "glove": "gloves",
    "press-test": "gloves",
    "glove-test": "gloves",
    "glove-press-test": "gloves",
    "glovepresstest": "gloves",
}


def _bool_text(value: str, parser: argparse.ArgumentParser) -> bool:
    values = {"true": True, "false": False, "on": True, "off": False,
              "yes": True, "no": False, "1": True, "0": False}
    result = values.get(value.strip().lower())
    if result is None:
        parser.error("boolean value must be true or false")
    return result


def _selected_bool(args: argparse.Namespace, parser: argparse.ArgumentParser) -> bool:
    if args.value is not None and args.flag_value is not None:
        parser.error("provide the engage or swap Bool once")
    raw = args.value if args.value is not None else args.flag_value
    if raw is None:
        parser.error(args.action + " requires a Boolean value")
    return _bool_text(raw, parser)


def _validate(args: argparse.Namespace, parser: argparse.ArgumentParser) -> None:
    if not math.isfinite(args.timeout) or args.timeout <= 0 or args.timeout > MAX_TIMEOUT:
        parser.error(f"--timeout must be finite, positive, and at most {MAX_TIMEOUT:g} seconds")
    if not math.isfinite(args.duration) or args.duration <= 0 or args.duration > MAX_GLOVE_DURATION:
        parser.error(
            f"--duration must be finite, positive, and at most {MAX_GLOVE_DURATION:g} seconds"
        )

    write_actions = {"engage", "reset", "swap"}
    glove_actions = {"gloves", "glove", "press-test", "glove-test"}
    if args.action in write_actions and not args.confirm:
        parser.error(args.action + " changes live hardware and requires --confirm")
    if args.action in {"engage", "swap"}:
        _selected_bool(args, parser)
        if args.reset_local_peaks:
            parser.error("--reset-local-peaks applies only to gloves")
        if args.duration != 5.0:
            parser.error("--duration applies only to gloves")
    elif args.action == "reset":
        if args.value is not None or args.flag_value is not None:
            parser.error("reset always publishes true and does not accept a Bool value")
        if args.reset_local_peaks:
            parser.error("--reset-local-peaks applies only to gloves")
        if args.duration != 5.0:
            parser.error("--duration applies only to gloves")
    elif args.action == "status":
        if args.value is not None or args.flag_value is not None or args.reset_local_peaks:
            parser.error("status is read-only and accepts no control values")
        if args.duration != 5.0:
            parser.error("--duration applies only to gloves")
        if args.confirm:
            parser.error("status is read-only and does not accept --confirm")
    elif args.action in glove_actions:
        if args.value is not None or args.flag_value is not None:
            parser.error("gloves is read-only and accepts no control value")
        if args.confirm:
            parser.error("gloves is read-only and does not accept --confirm")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Engage and reset have no owner acknowledgement. Inspect the same rig before retrying.",
    )
    parser.add_argument("domain", choices=[DOMAIN])
    parser.add_argument(
        "action",
        choices=["status", "engage", "reset", "swap", "wrist-swap", "wristswap",
                 "gloves", "glove", "press-test", "glove-test", "glove-press-test",
                 "glovepresstest"],
        help="status, engage, reset, swap, or the read-only gloves press observer",
    )
    parser.add_argument("value", nargs="?", help="engage/swap desired Bool: true or false")
    parser.add_argument("--value", "--state", dest="flag_value",
                        help="engage/swap desired Bool: true or false")
    parser.add_argument("--confirm", action="store_true",
                        help="confirm the selected live engage, reset, or wrist swap")
    parser.add_argument("--duration", type=float, default=5.0,
                        help="seconds to observe both gloves (default: 5)")
    parser.add_argument("--reset-local-peaks", "--reset-peaks", "--reset",
                        dest="reset_local_peaks", action="store_true",
                        help="clear the local glove peaks before observing")
    parser.add_argument("--timeout", type=float, default=20.0,
                        help="bounded owner discovery/result wait in seconds (default: 20)")
    parser.add_argument("--json", action="store_true", help="print compact JSON")
    parser.add_argument("--dry-run", action="store_true",
                        help="show the topic contract without connecting to ROS")
    return parser


def _print(value: dict, args: argparse.Namespace) -> None:
    print(json.dumps(value, indent=None if args.json else 2, sort_keys=True))


def _contract(args: argparse.Namespace, parser: argparse.ArgumentParser) -> dict:
    action = args.action
    if action == "engage":
        return {
            "action": action,
            "command_topic": VISION_ENGAGE_TOPIC,
            "message_type": BOOL_TYPE,
            "payload": {"data": _selected_bool(args, parser)},
            "requires_confirm": True,
            "outcome": "dispatched/unknown",
        }
    if action == "reset":
        return {
            "action": action,
            "command_topic": VISION_RESET_TOPIC,
            "message_type": BOOL_TYPE,
            "payload": {"data": True},
            "requires_confirm": True,
            "outcome": "dispatched/unknown",
        }
    if action == "swap":
        return {
            "action": action,
            "command_topic": WRIST_SWAP_TOPIC,
            "result_topics": [WRIST_SWAP_STATE_TOPIC],
            "message_type": BOOL_TYPE,
            "payload": {"data": _selected_bool(args, parser)},
            "requires_confirm": True,
            "outcome": "observed/unknown",
        }
    if action == "status":
        return {
            "action": action,
            "command_topic": None,
            "result_topics": [WRIST_SWAP_STATE_TOPIC, TRACKING_TOPIC],
            "read_only": True,
        }
    return {
        "action": "gloves",
        "result_topics": list(GLOVE_TOPICS.values()),
        "message_type": TACTILE_TYPE,
        "duration": args.duration,
        "reset_local_peaks": args.reset_local_peaks,
        "threshold": PRESS_THRESHOLD,
        "read_only": True,
    }


def _ros_qos(*, latched: bool = False):
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy

    return QoSProfile(
        depth=1 if latched else 100,
        reliability=ReliabilityPolicy.RELIABLE,
        durability=(DurabilityPolicy.TRANSIENT_LOCAL
                     if latched else DurabilityPolicy.VOLATILE),
    )


def _spin(rclpy, node, deadline: float, done) -> bool:
    while not done() and time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=min(0.1, max(0.0, deadline - time.monotonic())))
    return done()


def _finish(rclpy, node) -> None:
    node.destroy_node()
    if rclpy.ok():
        rclpy.shutdown()


def _run_bool_command(args: argparse.Namespace, topic: str, value: bool) -> int:
    try:
        import rclpy
        from std_msgs.msg import Bool
    except ImportError as exc:
        _print({"ok": False, "state": "unavailable", "error": f"ROS runtime unavailable: {exc}"}, args)
        return 3

    rclpy.init()
    node = rclpy.create_node("fm_teleop_control_cli")
    publisher = node.create_publisher(Bool, topic, _ros_qos())
    sent = False
    try:
        deadline = time.monotonic() + args.timeout
        if not _spin(rclpy, node, deadline,
                     lambda: publisher.get_subscription_count() > 0):
            _print({"ok": False, "state": "unavailable", "dispatched": False,
                    "command_topic": topic, "message_type": BOOL_TYPE,
                    "error": "No owner subscribed before the timeout; no request was sent."}, args)
            return 3
        publisher.publish(Bool(data=value))
        sent = True
        _print({"ok": None, "state": "dispatched", "outcome": "unknown",
                "dispatched": sent, "command_topic": topic,
                "message_type": BOOL_TYPE, "payload": {"data": value},
                "detail": "The owner has no acknowledgement topic; inspect the rig before retrying."}, args)
        return 3
    except KeyboardInterrupt:
        print("Stopped waiting. The command may have been dispatched; inspect the rig.", file=sys.stderr)
        return 130
    finally:
        _finish(rclpy, node)


def _run_swap(args: argparse.Namespace, desired: bool) -> int:
    try:
        import rclpy
        from std_msgs.msg import Bool
    except ImportError as exc:
        _print({"ok": False, "state": "unavailable", "error": f"ROS runtime unavailable: {exc}"}, args)
        return 3

    rclpy.init()
    node = rclpy.create_node("fm_teleop_control_cli")
    state = {"published": False, "after": None}

    def receive(message):
        if state["published"]:
            state["after"] = bool(message.data)

    subscription = node.create_subscription(Bool, WRIST_SWAP_STATE_TOPIC, receive,
                                             _ros_qos(latched=True))
    publisher = node.create_publisher(Bool, WRIST_SWAP_TOPIC, _ros_qos())
    try:
        deadline = time.monotonic() + args.timeout
        ready = lambda: (publisher.get_subscription_count() > 0
                         and node.count_publishers(WRIST_SWAP_STATE_TOPIC) > 0)
        if not _spin(rclpy, node, deadline, ready):
            _print({"ok": False, "state": "unavailable", "dispatched": False,
                    "command_topic": WRIST_SWAP_TOPIC, "result_topic": WRIST_SWAP_STATE_TOPIC,
                    "error": "The wrist supervisor or its state topic was unavailable; no request was sent."}, args)
            return 3
        publisher.publish(Bool(data=desired))
        state["published"] = True
        matched = _spin(rclpy, node, deadline,
                        lambda: state["after"] == desired)
        actual = state["after"]
        if not matched:
            _print({"ok": None, "state": "dispatched", "outcome": "unknown",
                    "dispatched": True, "desired": desired,
                    "command_topic": WRIST_SWAP_TOPIC, "result_topic": WRIST_SWAP_STATE_TOPIC,
                    "observed_state": actual,
                    "detail": "The desired owner state was not observed. The topic has no request identity; inspect the rig before retrying."}, args)
            return 3
        _print({"ok": True, "state": "observed", "outcome": "observed",
                "dispatched": True, "desired": desired, "applied": actual,
                "command_topic": WRIST_SWAP_TOPIC, "result_topic": WRIST_SWAP_STATE_TOPIC,
                "detail": "The owner state matches. This is an observation, not a receipt for this command."}, args)
        return 0
    except KeyboardInterrupt:
        print("Stopped waiting. The swap may have been dispatched; inspect the rig.", file=sys.stderr)
        return 130
    finally:
        node.destroy_subscription(subscription)
        _finish(rclpy, node)


def _run_status(args: argparse.Namespace) -> int:
    try:
        import rclpy
        from std_msgs.msg import Bool
    except ImportError as exc:
        _print({"ok": False, "state": "unavailable", "error": f"ROS runtime unavailable: {exc}"}, args)
        return 3

    rclpy.init()
    node = rclpy.create_node("fm_teleop_control_cli")
    state = {"wrist_swapped": None, "tracking_active": None}

    def receive_swap(message):
        state["wrist_swapped"] = bool(message.data)

    def receive_tracking(message):
        state["tracking_active"] = bool(message.data)

    subscriptions = [
        node.create_subscription(Bool, WRIST_SWAP_STATE_TOPIC, receive_swap, _ros_qos(latched=True)),
        node.create_subscription(Bool, TRACKING_TOPIC, receive_tracking, _ros_qos()),
    ]
    try:
        deadline = time.monotonic() + args.timeout
        _spin(rclpy, node, deadline,
              lambda: state["wrist_swapped"] is not None and state["tracking_active"] is not None)
        observed = state["wrist_swapped"] is not None or state["tracking_active"] is not None
        _print({"ok": True if observed else None,
                "state": "observed" if observed else "unknown",
                "engaged": None,
                "tracking_active": state["tracking_active"],
                "wrist_swapped": state["wrist_swapped"],
                "detail": "Engage has no owner state topic; engaged is unknown."}, args)
        return 0 if observed else 3
    except KeyboardInterrupt:
        print("Stopped waiting. Status is unknown.", file=sys.stderr)
        return 130
    finally:
        for subscription in subscriptions:
            node.destroy_subscription(subscription)
        _finish(rclpy, node)


def _run_gloves(args: argparse.Namespace) -> int:
    try:
        import rclpy
        from fm_tactile_msgs.msg import TactileSample
    except ImportError as exc:
        _print({"ok": False, "state": "unavailable", "error": f"ROS tactile runtime unavailable: {exc}"}, args)
        return 3

    rclpy.init()
    node = rclpy.create_node("fm_teleop_glove_test_cli")
    peaks = {hand: [0] * GLOVE_CHANNELS for hand in GLOVE_TOPICS}
    samples = {hand: 0 for hand in GLOVE_TOPICS}
    last = {hand: None for hand in GLOVE_TOPICS}

    def receive(hand, message):
        values = list(message.raw)
        if len(values) != GLOVE_CHANNELS or any(value < 0 or value > 4095 for value in values):
            return
        samples[hand] += 1
        peaks[hand] = [max(old, int(value)) for old, value in zip(peaks[hand], values)]
        last[hand] = time.monotonic()

    subscriptions = [
        node.create_subscription(TactileSample, topic,
                                 lambda message, hand=hand: receive(hand, message),
                                 _ros_qos())
        for hand, topic in GLOVE_TOPICS.items()
    ]
    try:
        deadline = time.monotonic() + args.duration
        while time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=min(0.1, max(0.0, deadline - time.monotonic())))
        hands = {}
        for hand, topic in GLOVE_TOPICS.items():
            answers = [peak > PRESS_THRESHOLD for peak in peaks[hand]]
            hands[hand] = {
                "topic": topic,
                "samples": samples[hand],
                "live": last[hand] is not None and time.monotonic() - last[hand] <= 1.0,
                "peaks": peaks[hand],
                "answered": answers,
                "answered_count": sum(answers),
            }
        answered_count = sum(item["answered_count"] for item in hands.values())
        total = len(GLOVE_TOPICS) * GLOVE_CHANNELS
        if answered_count == total:
            outcome = "complete"
        elif sum(samples.values()) == 0:
            outcome = "unknown"
        else:
            outcome = "incomplete"
        _print({"ok": True if sum(samples.values()) else None,
                "state": "observed" if sum(samples.values()) else "unknown",
                "outcome": outcome, "duration": args.duration,
                "reset_local_peaks": args.reset_local_peaks,
                "threshold": PRESS_THRESHOLD, "answered_count": answered_count,
                "total_pads": total, "hands": hands}, args)
        return 0 if sum(samples.values()) else 3
    except KeyboardInterrupt:
        print("Stopped observing gloves; local peaks are incomplete.", file=sys.stderr)
        return 130
    finally:
        for subscription in subscriptions:
            node.destroy_subscription(subscription)
        _finish(rclpy, node)


def main(argv=None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    args.action = ACTION_ALIASES.get(args.action, args.action)
    _validate(args, parser)
    if args.dry_run:
        _print(_contract(args, parser), args)
        return 0

    if args.action == "engage":
        return _run_bool_command(args, VISION_ENGAGE_TOPIC, _selected_bool(args, parser))
    if args.action == "reset":
        return _run_bool_command(args, VISION_RESET_TOPIC, True)
    if args.action == "swap":
        return _run_swap(args, _selected_bool(args, parser))
    if args.action == "status":
        return _run_status(args)
    return _run_gloves(args)


if __name__ == "__main__":
    raise SystemExit(main())
