"""Project, dataset, profile, model preparation and release requests over their existing ROS topics."""

import argparse
import json
import math
import re
import sys
import time
import uuid

PROFILE_ACTIONS = {
    "list": "list_profiles", "inspect": "inspect_profile", "validate": "validate_profile",
    "drafts": "list_drafts", "inspect-draft": "inspect_draft", "import": "import_draft",
    "save-draft": "save_draft", "save": "save_profile", "submit": "submit_profile",
    "decide": "decide_profile", "clone": "clone_profile", "candidates": "list_candidates",
    "inspect-candidate": "inspect_candidate",
}
RELEASE_ACTIONS = {"status", "list", "show", "export", "prepare", "approve", "build", "verify", "view", "deliver", "publish", "result"}


def release_request(args, parser):
    if args.action in {"status", "list", "result"}:
        if any((args.target, args.episode, args.pack_id, args.artifact_id, args.delivery_id,
                args.confirmation_identity, args.strict, args.request_stdin, args.confirm)):
            parser.error("release inspection does not accept write options")
        return None
    if not args.target or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.target):
        parser.error("release requires a producer-owned target ID of at most 128 characters")
    options = {}
    required = {"export": "episode", "build": "pack_id", "view": "artifact_id",
                "deliver": "delivery_id", "publish": "confirmation_identity"}
    field = required.get(args.action)
    if field:
        value = getattr(args, field)
        if not value:
            parser.error(args.action + " requires --" + field.replace("_", "-"))
        options["episode_ids" if field == "episode" else field] = value
    if args.action == "verify":
        options["strict"] = args.strict
    if args.action in {"approve", "publish", "deliver"} and not args.confirm:
        parser.error(args.action + " requires a human --confirm for this exact target")
    if args.action == "approve":
        if not args.request_stdin:
            parser.error("approve requires --request-stdin with the exact approval object and its artifact digests")
        try:
            raw = sys.stdin.read(262145)
            if len(raw.encode("utf-8")) > 262144:
                parser.error("approval exceeds 262144 bytes")
            approval = json.loads(raw)
        except (ValueError, RecursionError):
            parser.error("approval must be valid bounded JSON")
        if not isinstance(approval, dict):
            parser.error("approval must be a JSON object")
        options["approval"] = approval
    if args.action == "publish":
        options["confirmed"] = True
    allowed = {field} if field else set()
    for option in ("episode", "pack_id", "artifact_id", "delivery_id", "confirmation_identity"):
        if getattr(args, option) and option not in allowed:
            parser.error("--" + option.replace("_", "-") + " does not apply to " + args.action)
    if args.strict and args.action != "verify":
        parser.error("--strict requires verify")
    if args.request_stdin and args.action != "approve":
        parser.error("release --request-stdin requires approve")
    return {"contract_version": 1, "request_id": str(uuid.uuid4()),
            "operation": "select" if args.action == "show" else args.action,
            "target_id": args.target, "options": options}


def profile_request(args, parser):
    request = {}
    if args.request_stdin:
        try:
            raw = sys.stdin.read(262145)
            if len(raw.encode("utf-8")) > 262144:
                parser.error("profile request exceeds 262144 bytes")
            request = json.loads(raw)
        except (ValueError, RecursionError):
            parser.error("profile request must be valid bounded JSON")
        if not isinstance(request, dict):
            parser.error("profile request must be a JSON object")
    operation = PROFILE_ACTIONS[args.action]
    if request.get("operation", operation) != operation:
        parser.error("profile request operation differs from the selected action")
    for field in ("profile_id", "profile_version"):
        value = getattr(args, field)
        if value is not None:
            if field in request and request[field] != value:
                parser.error(field + " differs between the request and command")
            request[field] = value
    if args.action == "decide" and not args.confirm:
        parser.error("decide records a human judgment and requires --confirm")
    request.update(contract_version=1, request_id=str(uuid.uuid4()), operation=operation)
    return request


def request_for(args, parser):
    """Build inputs only; fm-data owns validation and all catalogue changes."""
    if args.domain == "provision":
        if args.action != "start":
            if args.model:
                parser.error("--model only applies to provision start")
            return None
        return {"target": "qwen", "model": args.model or "qwen2.5-vl-7b",
                "request_id": str(uuid.uuid4())}
    if args.domain == "release":
        return release_request(args, parser)
    if args.domain == "profile":
        return profile_request(args, parser)
    if args.action in {"list", "status", "result"}:
        return None
    fields = {key: value for key, value in vars(args).items()
              if key in {"name", "description", "project_id", "episode_id"} and value is not None}
    request = {"request_id": args.request_id or str(uuid.uuid4()), "operation": args.action}
    if args.domain == "project":
        request.update(contract_version=1, **fields)
        if args.action == "delete" and not args.confirm:
            parser.error("delete requires --confirm for the selected project; recordings are retained")
    else:
        if not args.dataset_id:
            parser.error("catalogue changes require --dataset-id")
        options = {}
        if args.name is not None:
            options["name"] = args.name
        if args.episode:
            options["episode_ids"] = args.episode
        if args.destination is not None:
            options["destination_dataset_id"] = args.destination
        request.update(catalog_schema_version=1, dataset_id=args.dataset_id, options=options)
    return request


def correlated_result(value, expected_id, *, detail_target=None, inspect_release=False, provision=False):
    """Read only the requested outcome; retained evidence must not acknowledge a new write."""
    if not isinstance(value, dict):
        return None
    if provision:
        if expected_id and value.get("request_id") == expected_id and value.get("request_error"):
            return {"request_id": expected_id, "state": "refused", "ok": False,
                    "detail": value["request_error"]}
        snapshot = value.get("provision")
        if not isinstance(snapshot, dict):
            return None
        if expected_id is not None and snapshot.get("request_id") != expected_id:
            return None
        return {**snapshot, "ok": snapshot.get("state") != "failed"}
    if detail_target is not None:
        return value if (value.get("target_id") == detail_target
                         and value.get("request_id") == expected_id) else None
    if expected_id is None:
        return value
    candidates = [value, value.get("last"), value.get("refusal")]
    if inspect_release:
        current = value.get("current")
        if isinstance(current, dict):
            candidates.append({**current, "state": "running"})
        queue = value.get("queue")
        if isinstance(queue, list):
            candidates.extend({**item, "state": "queued"} for item in queue
                              if isinstance(item, dict))
    return next((item for item in candidates
                 if isinstance(item, dict) and item.get("request_id") == expected_id), None)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Use --host SSH_ALIAS through fm to select a remote recorder or processor. "
               "Result lookup reads the service's retained last result; missing history is not success.",
    )
    parser.add_argument("domain", choices=["project", "dataset", "profile", "release", "provision"])
    parser.add_argument("action", help="project: list/create/rename/describe/delete/assign/unassign/result; dataset: list/status/create/rename/add/remove/move/result; profile: " + "/".join(PROFILE_ACTIONS) + "; release: " + "/".join(sorted(RELEASE_ACTIONS)))
    parser.add_argument("--model", choices=["qwen2.5-vl-7b", "qwen3.5-9b"])
    parser.add_argument("--name")
    parser.add_argument("--description")
    parser.add_argument("--project-id")
    parser.add_argument("--episode-id")
    parser.add_argument("--dataset-id")
    parser.add_argument("--episode", action="append", default=[])
    parser.add_argument("--destination")
    parser.add_argument("--profile-id")
    parser.add_argument("--profile-version")
    parser.add_argument("target", nargs="?", help="release candidate or Pack ID")
    parser.add_argument("--pack-id")
    parser.add_argument("--artifact-id")
    parser.add_argument("--delivery-id")
    parser.add_argument("--confirmation-identity")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--request-stdin", action="store_true",
                        help="profiles: read structured fields from stdin; owner validates them; mint a new request ID")
    parser.add_argument("--request-id", help="exact request to inspect with result; never resubmits")
    parser.add_argument("--confirm", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    actions = ({"list", "create", "rename", "describe", "delete", "assign", "unassign", "result"}
               if args.domain == "project" else {"list", "status", "create", "rename", "add", "remove", "move", "result"})
    if args.domain == "profile":
        actions = set(PROFILE_ACTIONS)
    if args.domain == "release":
        actions = RELEASE_ACTIONS
    if args.domain == "provision":
        actions = {"start", "status", "result"}
    if args.action not in actions:
        parser.error("expected one of " + ", ".join(sorted(actions)))
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a finite positive number")
    if args.request_id and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.request_id):
        parser.error("--request-id must be a safe identity of at most 128 characters")
    if args.action == "result" and not args.request_id:
        parser.error("result requires --request-id")
    if args.request_id and args.action != "result":
        parser.error("--request-id is only for result lookup; new writes receive a new identity")
    if args.domain == "project" and (args.dataset_id or args.episode or args.destination):
        parser.error("dataset options cannot be used for projects")
    if args.domain == "dataset" and (args.project_id or args.episode_id or args.description is not None or args.confirm):
        parser.error("project options cannot be used for catalog datasets")
    if args.domain not in {"profile", "release"} and (args.profile_id or args.profile_version or args.request_stdin):
        parser.error("profile options require fm process profiles")
    if args.domain != "release" and any((args.target, args.pack_id, args.artifact_id,
                                         args.delivery_id, args.confirmation_identity, args.strict)):
        parser.error("release options require fm dataset-release")
    if args.domain == "release" and any((args.name, args.description, args.project_id,
                                         args.episode_id, args.dataset_id, args.destination,
                                         args.profile_id, args.profile_version)):
        parser.error("catalogue options cannot be used for releases")
    if args.domain == "profile" and any((args.name, args.description, args.project_id,
                                         args.episode_id, args.dataset_id, args.episode, args.destination)):
        parser.error("project and dataset options cannot be used for profiles")
    if args.domain != "provision" and args.model:
        parser.error("--model requires fm process provision")
    if args.domain == "provision" and any((args.name, args.description, args.project_id,
            args.episode_id, args.dataset_id, args.episode, args.destination, args.confirm)):
        parser.error("catalogue options cannot be used for model preparation")
    request = request_for(args, parser)
    root = "/projects" if args.domain == "project" else "/process/datasets"
    command_topic = root + ("/command" if args.domain == "project" else "/" + args.action)
    result_topic = root + ("/result" if args.domain == "project" else "/status")
    if args.domain == "profile":
        command_topic = "/process/task_profiles/request"
        result_topic = "/process/task_profiles/result"
    if args.domain == "release":
        root = "/release"
        command_topic = root + ("/select" if args.action == "show" else "/" + args.action)
        result_topic = root + ("/detail" if args.action == "show" else "/status")
    if request is None and args.action != "result":
        result_topic = root + ("/index" if args.action == "list" else "/status")
    if args.domain == "provision":
        command_topic = "/process/provision"
        result_topic = "/process/status"
    expected_id = request["request_id"] if request else args.request_id
    if args.dry_run:
        print(json.dumps({"command_topic": command_topic if request else None,
                          "result_topic": result_topic, "request": request}, sort_keys=True))
        return 0

    import rclpy
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
    from std_msgs.msg import String

    rclpy.init()
    node = rclpy.create_node("fm_catalogue_cli")
    result = None

    def receive(message):
        nonlocal result
        try:
            value = json.loads(message.data)
        except ValueError:
            return
        matched = correlated_result(
            value, expected_id,
            detail_target=args.target if args.domain == "release" and args.action == "show" else None,
            inspect_release=args.domain == "release" and args.action == "result",
            provision=args.domain == "provision",
        )
        if matched is not None:
            result = matched

    qos = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                     durability=DurabilityPolicy.TRANSIENT_LOCAL)
    subscription = node.create_subscription(String, result_topic, receive, qos)
    try:
        deadline = time.monotonic() + args.timeout
        if request is not None:
            publisher = node.create_publisher(String, command_topic, 10)
            while (publisher.get_subscription_count() == 0
                   or node.count_publishers(result_topic) == 0):
                if time.monotonic() >= deadline:
                    print("Service unavailable. No request was sent.", file=sys.stderr)
                    return 3
                rclpy.spin_once(node, timeout_sec=0.1)
            print("request " + request["request_id"], file=sys.stderr)
            publisher.publish(String(data=json.dumps(request)))
        while result is None and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
        if result is None:
            print("No result. Inspect the same request before retrying; the outcome is unknown."
                  if request else "No catalogue received.", file=sys.stderr)
            return 3
        print(json.dumps(result, indent=None if args.json else 2, sort_keys=True))
        return 3 if result.get("ok") is False or result.get("issue_code") else 0
    except KeyboardInterrupt:
        print("Stopped waiting. Remote work was not cancelled.", file=sys.stderr)
        return 130
    finally:
        node.destroy_subscription(subscription)
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
