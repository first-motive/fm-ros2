"""Capture, project, dataset, profile, model preparation and release requests over their existing ROS topics."""

import argparse
import base64
import hashlib
import json
import math
import re
import sys
import time
import uuid
from pathlib import Path

PROFILE_ACTIONS = {
    "list": "list_profiles", "inspect": "inspect_profile", "validate": "validate_profile",
    "drafts": "list_drafts", "inspect-draft": "inspect_draft", "import": "import_draft",
    "save-draft": "save_draft", "save": "save_profile", "submit": "submit_profile",
    "decide": "decide_profile", "clone": "clone_profile", "candidates": "list_candidates",
    "inspect-candidate": "inspect_candidate",
}
RELEASE_ACTIONS = {"status", "list", "show", "export", "prepare", "approve", "build", "verify", "view", "deliver", "publish", "result"}
CAPTURE_ACTIONS = {"start", "stop", "submit", "discard", "sync", "sensors"}
SPECIAL_DOMAINS = {"qa", "review-media", "showcase", "viewer", "review-pin"}
REVIEW_MEDIA_MODES = {"frame", "scrub", "range", "contact_sheet"}
REVIEW_MEDIA_MAX_RANGE = 180
REVIEW_MEDIA_MAX_SEQUENCE = 4096
REVIEW_MEDIA_MAX_TOTAL_BYTES = 64 * 1024 * 1024
SHOWCASE_MAX_CHUNKS = 4096
SHOWCASE_MAX_BYTES = 64 * 1024 * 1024
SHOWCASE_MAX_CHUNK_BYTES = 256 * 1024
VIEWER_ENDPOINTS = {"repositories", "splits", "size", "files", "preview", "rows", "statistics"}
SAFE_REQUEST_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
SAFE_PIN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
SAFE_EPISODE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
LOWER_SHA256 = re.compile(r"[a-f0-9]{64}")


def capture_request(args, parser):
    fields = {"task_id": args.task_id, "instruction": args.instruction,
              "operator_id": args.operator_id, "outcome": args.outcome,
              "sync_state": args.sync_state, "disabled_device": args.disabled_device,
              "confirm": True if args.confirm else None}
    allowed = {"start": {"task_id", "instruction", "operator_id"},
               "submit": {"outcome"}, "discard": {"confirm"},
               "sync": {"sync_state"}, "sensors": {"disabled_device"}}
    if any(value is not None and key not in allowed.get(args.action, set())
           for key, value in fields.items()):
        parser.error("capture options do not apply to " + args.action)
    if args.action in {"list", "status", "result", "sync", "sensors"}:
        if args.episode_id:
            parser.error("--episode-id does not apply to " + args.action)
    elif args.action == "show":
        if not args.episode_id or not args.episode_id.strip() or len(args.episode_id) > 200:
            parser.error("capture show requires --episode-id of at most 200 characters")
    elif (not args.episode_id or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.episode_id)):
        parser.error("capture requires --episode-id with a safe identity of at most 128 characters")
    if args.action in {"list", "status", "result"}:
        return None
    request = {"contract_version": 1, "request_id": str(uuid.uuid4())}
    if args.episode_id:
        request["episode_id"] = args.episode_id
    if args.action == "show":
        return request
    options = {}
    if args.action == "start":
        for key in ("task_id", "instruction", "operator_id"):
            value = fields[key]
            if not value or not value.strip():
                parser.error("start requires --" + key.replace("_", "-"))
            options[key] = value
    elif args.action == "submit":
        if args.outcome is None:
            parser.error("submit requires the operator's --outcome success|failed|unlabeled")
        options["operator_success"] = {"success": True, "failed": False, "unlabeled": None}[args.outcome]
    elif args.action == "discard":
        if not args.confirm:
            parser.error("discard requires --confirm for the exact held take")
        options["confirmed"] = True
    elif args.action == "sync":
        if args.sync_state is None:
            parser.error("sync requires --sync-state synced|pending")
        options["synced"] = args.sync_state == "synced"
    elif args.action == "sensors":
        options["disabled_devices"] = args.disabled_device or []
    request.update(operation=args.action, options=options)
    return request


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
    """Build inputs only; the selected service owns validation and catalogue changes."""
    if args.domain == "capture":
        return capture_request(args, parser)
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
        if args.action == "show":
            if options:
                parser.error("dataset show does not accept write options")
            request["operation"] = "select"
        request.update(catalog_schema_version=1, dataset_id=args.dataset_id, options=options)
    return request


def correlated_result(value, expected_id, *, detail_target=None, detail_key="target_id", inspect_release=False, provision=False):
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
        if value.get(detail_key) == detail_target and value.get("request_id") == expected_id:
            return value
        refusal = value.get("refusal")
        if (detail_key == "dataset_id" and isinstance(refusal, dict)
                and refusal.get("request_id") == expected_id and refusal.get("issue_code")):
            return refusal
        return None
    if expected_id is None:
        return value
    candidates = [value, value.get("last"), value.get("refusal")]
    if isinstance(value.get("results"), list):
        candidates.extend(value["results"][:64])
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


def _special_request_id(args, parser, *, max_length=128):
    request_id = args.request_id or str(uuid.uuid4())
    pattern = rf"[A-Za-z0-9][A-Za-z0-9._:-]{{0,{max_length - 1}}}"
    if not re.fullmatch(pattern, request_id):
        parser.error(f"--request-id must be a safe identity of at most {max_length} characters")
    return request_id


def _special_episode(args, parser):
    episode_id = args.episode_id or args.target
    if args.episode_id and args.target and args.episode_id != args.target:
        parser.error("--episode-id and the positional episode ID differ")
    if not episode_id or not SAFE_EPISODE_ID.fullmatch(episode_id):
        parser.error("the media or showcase request needs a safe episode ID of at most 128 characters")
    return episode_id


def _review_media_request(args, parser):
    if args.action not in {"fetch", "get", "request"}:
        parser.error("review-media expects fetch")
    episode_id = _special_episode(args, parser)
    bundle_sha256 = args.annotation_bundle_sha256
    if not bundle_sha256 or not LOWER_SHA256.fullmatch(bundle_sha256):
        parser.error("review-media needs a lowercase --annotation-bundle-sha256")
    if args.mode not in REVIEW_MEDIA_MODES:
        parser.error("review-media needs --mode frame|scrub|range|contact_sheet")
    request = {
        "episode_id": episode_id,
        "annotation_bundle_sha256": bundle_sha256,
        "mode": args.mode,
        "request_id": _special_request_id(args, parser),
    }
    if args.mode in {"frame", "scrub"}:
        if args.topic_frame_index is None or args.topic_frame_index < 0:
            parser.error("frame and scrub review media need a non-negative --topic-frame-index")
        if args.start_frame is not None or args.end_frame is not None:
            parser.error("--start-frame and --end-frame only apply to range")
        request["topic_frame_index"] = args.topic_frame_index
    elif args.mode == "range":
        if args.start_frame is None or args.end_frame is None:
            parser.error("range review media needs --start-frame and --end-frame")
        if args.start_frame < 0 or args.end_frame < 0 or args.end_frame < args.start_frame:
            parser.error("range frame bounds must be non-negative and ordered")
        if args.end_frame - args.start_frame + 1 > REVIEW_MEDIA_MAX_RANGE:
            parser.error(f"range review media is limited to {REVIEW_MEDIA_MAX_RANGE} frames")
        request.update(start_frame=args.start_frame, end_frame=args.end_frame)
    else:
        if any(value is not None for value in (args.topic_frame_index, args.start_frame, args.end_frame)):
            parser.error("contact_sheet does not accept frame bounds")
    if args.playback_rate is not None:
        if args.playback_rate not in {0.25, 0.5, 1.0}:
            parser.error("--playback-rate must be 0.25, 0.5, or 1.0")
        request["playback_rate"] = args.playback_rate
    if args.max_fps is not None:
        if args.max_fps < 1 or args.max_fps > 30:
            parser.error("--max-fps must be between 1 and 30")
        request["max_fps"] = args.max_fps
    return request


def _showcase_request(args, parser):
    if args.action not in {"fetch", "get", "request"}:
        parser.error("showcase expects fetch")
    return {"episode_id": _special_episode(args, parser),
            "request_id": _special_request_id(args, parser)}


def _canonical_viewer_dataset(value, parser):
    if not value:
        parser.error("this Hugging Face viewer endpoint needs a dataset")
    if "://" in value or value.count("/") != 1:
        parser.error("dataset must be an owner/name identity")
    owner, name = value.split("/", 1)
    if owner == "firstmotive":
        owner = "first-motive"
    if owner != "first-motive" or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", name):
        parser.error("dataset must belong to first-motive")
    return owner + "/" + name


def _viewer_request(args, parser):
    endpoint = args.action
    if endpoint in {"view", "huggingface"}:
        endpoint = args.endpoint
    if endpoint not in VIEWER_ENDPOINTS:
        parser.error("viewer expects repositories, splits, size, files, preview, rows, or statistics")
    request_id = _special_request_id(args, parser)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", request_id):
        parser.error("viewer request IDs must use letters, digits, dot, underscore, and hyphen")
    dataset_arg = args.viewer_dataset or args.target
    if endpoint == "repositories":
        if dataset_arg:
            parser.error("repositories does not accept a dataset")
        author = args.author or "first-motive"
        if author == "firstmotive":
            author = "first-motive"
        if author != "first-motive" or str(args.limit) != "500" or args.full is not True:
            parser.error("repositories is bounded to author=first-motive, limit=500, full=true")
        query = {"author": author, "limit": "500", "full": "true"}
    else:
        dataset = _canonical_viewer_dataset(dataset_arg, parser)
        if endpoint in {"splits", "size", "files"}:
            query = {"dataset": dataset}
        elif endpoint == "preview":
            if not args.file_id or not re.fullmatch(r"[a-f0-9]{32}", args.file_id):
                parser.error("preview needs a 32-character lowercase --file-id")
            query = {"dataset": dataset, "file_id": args.file_id}
        elif endpoint == "rows":
            if args.config != "default" or args.split != "train":
                parser.error("rows is bounded to config=default and split=train")
            if args.offset < 0 or args.length < 1 or args.length > 20:
                parser.error("rows needs offset >= 0 and length between 1 and 20")
            query = {"dataset": dataset, "config": "default", "split": "train",
                     "offset": str(args.offset), "length": str(args.length)}
        else:
            if args.config != "default" or args.split != "train":
                parser.error("statistics is bounded to config=default and split=train")
            query = {"dataset": dataset, "config": "default", "split": "train"}
    return {"contract_version": 1, "endpoint": endpoint, "query": query,
            "request_id": request_id}


def _review_pin_request(args, parser):
    action = {"acquire": "begin", "begin": "begin", "release": "end", "end": "end"}.get(args.action)
    if action is None:
        parser.error("review-pin expects acquire or release")
    target_id = args.target_id or args.target
    if not target_id or "\x00" in target_id or len(target_id) > 512:
        parser.error("review-pin needs a target ID of at most 512 characters without NUL")
    parts = target_id.split("/")
    if len(parts) != 3 or not parts[0] or parts[1] != "annotation" or not parts[2]:
        parser.error("review-pin target must be <episode>/annotation/<annotation-sha>")
    if args.target_id and args.target and args.target_id != args.target:
        parser.error("--target-id and the positional target differ")
    if not args.pin_id or not SAFE_PIN_ID.fullmatch(args.pin_id):
        parser.error("review-pin needs a safe --pin-id of at most 128 characters")
    return {"contract_version": 1, "target_id": target_id, "pin_id": args.pin_id,
            "request_id": _special_request_id(args, parser, max_length=64)}, action


def _qa_request(args, parser):
    if args.action == "show":
        if args.inputfile or args.confirm or args.request_id:
            parser.error("qa show does not accept replacement or request options")
        return None
    if args.action == "result":
        if args.inputfile or args.confirm or not args.request_id:
            parser.error("qa result needs --request-id and accepts no replacement options")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", args.request_id):
            parser.error("--request-id must be a safe identity of at most 128 characters")
        return {"request_id": args.request_id}
    if args.action != "set":
        parser.error("qa expects show, set, or result")
    if not args.inputfile or not args.confirm:
        parser.error("qa set requires --inputfile and --confirm")
    try:
        raw = Path(args.inputfile).read_bytes()
    except OSError as exc:
        parser.error(f"cannot read --inputfile: {exc}")
    if len(raw) > 1_048_576:
        parser.error("QA policy exceeds 1 MiB")
    try:
        policy = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        parser.error("--inputfile must contain valid JSON policy data")
    if isinstance(policy, dict) and set(policy) == {"policy"}:
        policy = policy["policy"]
    if not isinstance(policy, dict):
        parser.error("QA policy must be a JSON object")
    request_id = _special_request_id(args, parser)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", request_id):
        parser.error("QA request IDs must use letters, digits, dot, underscore, and hyphen")
    return {"schema_version": 1, "request_id": request_id,
            "policy": policy}


def special_request(args, parser):
    if args.domain == "qa":
        return _qa_request(args, parser)
    if args.domain == "review-media":
        return _review_media_request(args, parser)
    if args.domain == "showcase":
        return _showcase_request(args, parser)
    if args.domain == "viewer":
        return _viewer_request(args, parser)
    return _review_pin_request(args, parser)[0]


def special_topics(args, request):
    if args.domain == "qa":
        if args.action == "set":
            return "/episode_qa/policy/set", ["/episode_qa/policy"]
        return None, ["/episode_qa/policy"]
    if args.domain == "review-media":
        return "/process/review_media/select", ["/process/review_media/meta", "/process/review_media/image"]
    if args.domain == "showcase":
        return "/process/showcase/select", ["/process/showcase/meta", "/process/showcase/chunk"]
    if args.domain == "viewer":
        return "/release/huggingface/view", ["/release/huggingface/viewer"]
    verb = "begin" if args.action in {"acquire", "begin"} else "end"
    return "/archive/review_pin/" + verb, ["/archive/storage/status"]


def _special_json(value, args):
    print(json.dumps(value, indent=None if args.json else 2, sort_keys=True))


def _special_error(request_id, message, args):
    _special_json({"ok": False, "request_id": request_id, "error": message}, args)
    return 3


def _special_qos():
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
    return QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                      durability=DurabilityPolicy.TRANSIENT_LOCAL)


def _wait_special_publishers(node, publisher, result_topics, deadline):
    while (publisher.get_subscription_count() == 0
           or any(node.count_publishers(topic) == 0 for topic in result_topics)):
        if time.monotonic() >= deadline:
            return False
        import rclpy
        rclpy.spin_once(node, timeout_sec=0.1)
    return True


def _run_string_request(request, command_topic, result_topic, args, validator, node_name, success=None):
    """Publish one String request after subscriptions exist and return one exact reply."""
    import rclpy
    from std_msgs.msg import String

    rclpy.init()
    node = rclpy.create_node(node_name)
    state = {"result": None, "parse_error": None}

    def receive(message):
        try:
            value = json.loads(message.data)
        except (TypeError, ValueError):
            return
        matched = validator(value)
        if matched is not None:
            state["result"] = matched

    qos = _special_qos()
    subscription = node.create_subscription(String, result_topic, receive, qos)
    publisher = node.create_publisher(String, command_topic, 10)
    deadline = time.monotonic() + args.timeout
    sent = False
    try:
        if not _wait_special_publishers(node, publisher, [result_topic], deadline):
            print("Service unavailable. No request was sent.", file=sys.stderr)
            return 3
        publisher.publish(String(data=json.dumps(request, separators=(",", ":"))))
        sent = True
        while state["result"] is None and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
        if state["result"] is None:
            return _special_error(request["request_id"],
                                  "No correlated result arrived within the timeout; inspect the same request before retrying.",
                                  args)
        _special_json(state["result"], args)
        if success is None:
            update = state["result"].get("last_update")
            ok = state["result"].get("ok") is True or (
                isinstance(update, dict) and update.get("ok") is True
            )
        else:
            ok = success(state["result"])
        return 0 if ok else 3
    except KeyboardInterrupt:
        print("Stopped waiting. Remote work was not cancelled.", file=sys.stderr)
        return 130
    finally:
        if sent:
            pass
        node.destroy_subscription(subscription)
        node.destroy_publisher(publisher)
        node.destroy_node()
        rclpy.shutdown()


def _review_pin_result(value, request, verb):
    if not isinstance(value, dict):
        return None
    candidates = [value]
    for key in ("operation", "result", "last"):
        nested = value.get(key)
        if isinstance(nested, dict):
            candidates.append(nested)
    expected_verb = "begin_review_pin" if verb == "begin" else "end_review_pin"
    for candidate in candidates:
        if (candidate.get("request_id") == request["request_id"]
                and candidate.get("target_id") == request["target_id"]
                and candidate.get("pin_id") == request["pin_id"]
                and candidate.get("verb") == expected_verb):
            return value
    return None


def _review_pin_success(value, request, verb):
    expected_verb = "begin_review_pin" if verb == "begin" else "end_review_pin"
    expected_state = "active" if verb == "begin" else "ended"
    candidates = [value]
    for key in ("operation", "result", "last"):
        nested = value.get(key) if isinstance(value, dict) else None
        if isinstance(nested, dict):
            candidates.append(nested)
    for candidate in candidates:
        if (candidate.get("request_id") == request["request_id"]
                and candidate.get("target_id") == request["target_id"]
                and candidate.get("pin_id") == request["pin_id"]
                and candidate.get("verb") == expected_verb):
            if candidate.get("state") != expected_state or candidate.get("ok") is not True:
                return False
            return verb != "begin" or (
                candidate.get("pin_durable") is True
                and candidate.get("lock_state") in (None, "shared")
            )
    return False


def _run_review_pin(request, verb, args):
    return _run_string_request(
        request, "/archive/review_pin/" + verb, "/archive/storage/status", args,
        lambda value: _review_pin_result(value, request, verb), "fm_review_pin_cli",
        success=lambda value: _review_pin_success(value, request, verb),
    )


def _qa_state(value):
    if not isinstance(value, dict) or value.get("command_version") != 1:
        return None
    if not isinstance(value.get("policy"), dict) or not isinstance(value.get("last_update"), dict):
        return None
    return value


def _qa_receipt(value, request_id):
    state = _qa_state(value)
    if state is None:
        return None
    update = state.get("last_update")
    if update.get("request_id") == request_id:
        return update
    return next((item for item in state.get("results") or []
                 if isinstance(item, dict) and item.get("request_id") == request_id), None)


def _qa_correlated_state(value, request_id):
    return value if _qa_receipt(value, request_id) is not None else None


def _run_qa_read(args, request_id=None):
    import rclpy
    from std_msgs.msg import String

    state = {"result": None}
    rclpy.init()
    node = rclpy.create_node("fm_episode_qa_cli")

    def receive(message):
        try:
            value = json.loads(message.data)
        except (TypeError, ValueError):
            return
        state["result"] = (_qa_correlated_state(value, request_id)
                            if request_id is not None else _qa_state(value))

    subscription = node.create_subscription(String, "/episode_qa/policy", receive, _special_qos())
    deadline = time.monotonic() + args.timeout
    try:
        while state["result"] is None and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
        if state["result"] is None:
            return _special_error(request_id or "unknown", "No policy state matched the request within the timeout.", args)
        _special_json(state["result"], args)
        if request_id is None:
            return 0
        receipt = _qa_receipt(state["result"], request_id)
        return 0 if isinstance(receipt, dict) and receipt.get("ok") is True else 3
    except KeyboardInterrupt:
        print("Stopped waiting. Remote work was not cancelled.", file=sys.stderr)
        return 130
    finally:
        node.destroy_subscription(subscription)
        node.destroy_node()
        rclpy.shutdown()


def _run_qa(request, args):
    if args.action == "show":
        return _run_qa_read(args)
    if args.action == "result":
        return _run_qa_read(args, request["request_id"])
    return _run_string_request(
        request, "/episode_qa/policy/set", "/episode_qa/policy", args,
        lambda value: _qa_correlated_state(value, request["request_id"]), "fm_episode_qa_cli",
        success=lambda value: (_qa_receipt(value, request["request_id"]) or {}).get("ok") is True,
    )


def _viewer_result(value, request_id):
    if not isinstance(value, dict):
        return None
    if (value.get("contract_version") != 1 or value.get("request_id") != request_id
            or not isinstance(value.get("ok"), bool) or not isinstance(value.get("status"), int)
            or "body" not in value):
        return None
    return value


def _run_viewer(request, args):
    return _run_string_request(
        request, "/release/huggingface/view", "/release/huggingface/viewer", args,
        lambda value: _viewer_result(value, request["request_id"]), "fm_huggingface_viewer_cli",
    )


def _media_metadata_error(metadata, request):
    if not isinstance(metadata, dict):
        return "review media metadata is not an object"
    if metadata.get("request_id") != request["request_id"]:
        return "review media metadata has the wrong request ID"
    for key in ("episode_id", "annotation_bundle_sha256", "mode"):
        if metadata.get(key) != request[key]:
            return "review media metadata has the wrong " + key
    return None


def _run_review_media(request, args):
    import rclpy
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
    from sensor_msgs.msg import CompressedImage
    from std_msgs.msg import String

    output_dir = Path(args.output_dir or args.output or (Path.home() / "review-media" / request["episode_id"])).expanduser()
    state = {"metadata": {}, "images": {}, "total": None, "error": None, "done": False,
             "complete": False}

    def fail(message):
        if state["error"] is None:
            state["error"] = message

    def maybe_done():
        if state["total"] is None or len(state["images"]) != state["total"]:
            return
        if any(index not in state["metadata"] for index in range(state["total"])):
            return
        if not state["complete"]:
            return
        state["done"] = True

    def metadata_receive(message):
        try:
            metadata = json.loads(message.data)
        except (TypeError, ValueError):
            return
        error = _media_metadata_error(metadata, request)
        if error:
            if isinstance(metadata, dict) and metadata.get("request_id") == request["request_id"]:
                fail(error)
            return
        if metadata.get("ok") is False or metadata.get("status") == "failed":
            fail(str(metadata.get("reason_code") or metadata.get("error") or "review media refused"))
            return
        index = metadata.get("sequence_index")
        total = metadata.get("sequence_total")
        image_sha = metadata.get("image_sha256")
        if (isinstance(index, bool) or not isinstance(index, int) or index < 0
                or isinstance(total, bool) or not isinstance(total, int)
                or total < 1 or total > REVIEW_MEDIA_MAX_SEQUENCE or index >= total
                or not isinstance(image_sha, str) or not LOWER_SHA256.fullmatch(image_sha)):
            fail("review media metadata has invalid sequence or image identity")
            return
        if state["total"] is not None and state["total"] != total:
            fail("review media changed sequence_total")
            return
        state["total"] = total
        previous = state["metadata"].get(index)
        if previous is not None and previous != metadata:
            fail("review media repeated a sequence with different metadata")
            return
        state["metadata"][index] = metadata
        if index == total - 1 and metadata.get("status") == "complete":
            state["complete"] = True
        if index in state["images"]:
            image = state["images"][index]
            if hashlib.sha256(image["data"]).hexdigest() != image_sha:
                fail("review media image hash differs from metadata")
        maybe_done()

    def image_receive(message):
        frame_id = getattr(getattr(message, "header", None), "frame_id", "")
        data = bytes(message.data)
        parts = frame_id.split("/") if isinstance(frame_id, str) else []
        if len(parts) != 4 or parts[0] != "fm-review" or parts[1] != request["request_id"]:
            return
        try:
            index = int(parts[2])
        except ValueError:
            fail("review media image has an invalid sequence index")
            return
        if index < 0 or index >= REVIEW_MEDIA_MAX_SEQUENCE or not LOWER_SHA256.fullmatch(parts[3]):
            fail("review media image has an invalid frame ID")
            return
        digest = hashlib.sha256(data).hexdigest()
        if digest != parts[3]:
            fail("review media image hash differs from its frame ID")
            return
        if not data or len(data) > 1_500_000:
            fail("review media image exceeds the owner byte bound")
            return
        previous = state["images"].get(index)
        if previous is not None and previous["data"] != data:
            fail("review media repeated a sequence with different image data")
            return
        state["images"][index] = {"data": data, "format": getattr(message, "format", "") or ""}
        metadata = state["metadata"].get(index)
        if metadata is not None:
            if metadata.get("image_sha256") != parts[3]:
                fail("review media image identity differs from metadata")
            if metadata.get("request_id") != request["request_id"]:
                fail("review media image metadata is not correlated")
            expected_format = str(metadata.get("image_format") or "").lower()
            actual_format = str(getattr(message, "format", "") or "").lower()
            if expected_format and actual_format and expected_format != actual_format:
                fail("review media image format differs from metadata")
        if sum(len(item["data"]) for item in state["images"].values()) > REVIEW_MEDIA_MAX_TOTAL_BYTES:
            fail("review media exceeds the bounded output size")
        maybe_done()

    qos = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                     durability=DurabilityPolicy.TRANSIENT_LOCAL)
    rclpy.init()
    node = rclpy.create_node("fm_review_media_cli")
    subscriptions = [
        node.create_subscription(String, "/process/review_media/meta", metadata_receive, qos),
        node.create_subscription(CompressedImage, "/process/review_media/image", image_receive, qos),
    ]
    publisher = node.create_publisher(String, "/process/review_media/select", 10)
    deadline = time.monotonic() + args.timeout
    try:
        if not _wait_special_publishers(node, publisher,
                                        ["/process/review_media/meta", "/process/review_media/image"], deadline):
            print("Service unavailable. No request was sent.", file=sys.stderr)
            return 3
        publisher.publish(String(data=json.dumps(request, separators=(",", ":"))))
        while not state["done"] and state["error"] is None and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
        if state["error"]:
            return _special_error(request["request_id"], state["error"], args)
        if not state["done"]:
            return _special_error(request["request_id"],
                                  "No complete correlated review media arrived within the timeout; inspect the same request before retrying.",
                                  args)
        files = []
        output_dir.mkdir(parents=True, exist_ok=True)
        for index in range(state["total"]):
            item = state["images"][index]
            fmt = str(item["format"]).lower()
            extension = "png" if "png" in fmt else "jpg"
            path = output_dir / f"frame-{index:06d}.{extension}"
            temporary = path.with_name(path.name + ".tmp")
            temporary.write_bytes(item["data"])
            temporary.replace(path)
            files.append(str(path))
        _special_json({"ok": True, "request_id": request["request_id"],
                       "episode_id": request["episode_id"], "files": files,
                       "sequence_total": state["total"]}, args)
        return 0
    except KeyboardInterrupt:
        print("Stopped waiting. Remote work was not cancelled.", file=sys.stderr)
        return 130
    finally:
        for subscription in subscriptions:
            node.destroy_subscription(subscription)
        node.destroy_publisher(publisher)
        node.destroy_node()
        rclpy.shutdown()


def _showcase_metadata_error(metadata, request):
    if not isinstance(metadata, dict):
        return "showcase metadata is not an object"
    if metadata.get("request_id") != request["request_id"]:
        return "showcase metadata has the wrong request ID"
    if metadata.get("episode_id") not in (None, request["episode_id"]):
        return "showcase metadata has the wrong episode ID"
    return None


def _run_showcase(request, args):
    import rclpy
    from std_msgs.msg import String

    output = Path(args.output or args.output_dir or (Path.home() / "showcase" / (request["episode_id"] + ".html"))).expanduser()
    state = {"meta": None, "chunks": {}, "error": None, "done": False}

    def fail(message):
        if state["error"] is None:
            state["error"] = message

    def maybe_done():
        meta = state["meta"]
        if not meta or meta.get("status") != "ready":
            return
        count = meta["chunks"]
        if len(state["chunks"]) != count or any(index not in state["chunks"] for index in range(count)):
            return
        data = b"".join(state["chunks"][index] for index in range(count))
        if len(data) != meta["bytes"] or hashlib.sha256(data).hexdigest() != meta["sha256"]:
            fail("showcase content failed its byte or SHA-256 check")
            return
        state["data"] = data
        state["done"] = True

    def metadata_receive(message):
        try:
            metadata = json.loads(message.data)
        except (TypeError, ValueError):
            return
        error = _showcase_metadata_error(metadata, request)
        if error:
            if isinstance(metadata, dict) and metadata.get("request_id") == request["request_id"]:
                fail(error)
            return
        status = metadata.get("status")
        if status == "failed" or metadata.get("ok") is False:
            fail(str(metadata.get("message") or metadata.get("reason_code") or "showcase delivery failed"))
            return
        if status == "working":
            return
        if status != "ready" or metadata.get("ok") is not True:
            fail("showcase metadata did not report working, ready, or failed")
            return
        count, byte_count, digest = metadata.get("chunks"), metadata.get("bytes"), metadata.get("sha256")
        if (isinstance(count, bool) or not isinstance(count, int) or count < 1 or count > SHOWCASE_MAX_CHUNKS
                or isinstance(byte_count, bool) or not isinstance(byte_count, int)
                or byte_count < 0 or byte_count > SHOWCASE_MAX_BYTES
                or not isinstance(digest, str) or not LOWER_SHA256.fullmatch(digest)):
            fail("showcase ready metadata is outside its bounds")
            return
        state["meta"] = {"request_id": request["request_id"], "status": status,
                          "ok": True, "bytes": byte_count, "chunks": count, "sha256": digest}
        maybe_done()

    def chunk_receive(message):
        try:
            chunk = json.loads(message.data)
        except (TypeError, ValueError):
            return
        if not isinstance(chunk, dict) or chunk.get("request_id") != request["request_id"]:
            return
        index, count, encoded = chunk.get("index"), chunk.get("count"), chunk.get("data")
        if (isinstance(index, bool) or not isinstance(index, int)
                or isinstance(count, bool) or not isinstance(count, int)
                or count < 1 or count > SHOWCASE_MAX_CHUNKS or index < 0 or index >= count
                or not isinstance(encoded, str)):
            fail("showcase chunk has invalid bounds")
            return
        meta = state["meta"]
        if meta is not None and count != meta["chunks"]:
            fail("showcase chunk count differs from metadata")
            return
        try:
            data = base64.b64decode(encoded, validate=True)
        except (ValueError, base64.binascii.Error):
            fail("showcase chunk is not valid base64")
            return
        if len(data) > SHOWCASE_MAX_CHUNK_BYTES:
            fail("showcase chunk exceeds its byte bound")
            return
        previous = state["chunks"].get(index)
        if previous is not None and previous != data:
            fail("showcase repeated a chunk index with different data")
            return
        state["chunks"][index] = data
        maybe_done()

    qos = _special_qos()
    rclpy.init()
    node = rclpy.create_node("fm_showcase_cli")
    subscriptions = [
        node.create_subscription(String, "/process/showcase/meta", metadata_receive, qos),
        node.create_subscription(String, "/process/showcase/chunk", chunk_receive, qos),
    ]
    publisher = node.create_publisher(String, "/process/showcase/select", 10)
    deadline = time.monotonic() + args.timeout
    try:
        if not _wait_special_publishers(node, publisher,
                                        ["/process/showcase/meta", "/process/showcase/chunk"], deadline):
            print("Service unavailable. No request was sent.", file=sys.stderr)
            return 3
        publisher.publish(String(data=json.dumps(request, separators=(",", ":"))))
        while not state["done"] and state["error"] is None and time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
        if state["error"]:
            return _special_error(request["request_id"], state["error"], args)
        if not state["done"]:
            return _special_error(request["request_id"],
                                  "No complete correlated showcase arrived within the timeout; inspect the same request before retrying.",
                                  args)
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(output.name + ".tmp")
        temporary.write_bytes(state["data"])
        temporary.replace(output)
        _special_json({"ok": True, "request_id": request["request_id"],
                       "episode_id": request["episode_id"], "bytes": len(state["data"]),
                       "sha256": state["meta"]["sha256"], "output": str(output)}, args)
        return 0
    except KeyboardInterrupt:
        print("Stopped waiting. Remote work was not cancelled.", file=sys.stderr)
        return 130
    finally:
        for subscription in subscriptions:
            node.destroy_subscription(subscription)
        node.destroy_publisher(publisher)
        node.destroy_node()
        rclpy.shutdown()


def special_main(args, parser):
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a finite positive number")
    request = special_request(args, parser)
    command_topic, result_topics = special_topics(args, request)
    if args.dry_run:
        payload = {"command_topic": command_topic, "result_topics": result_topics,
                   "request": request}
        if len(result_topics) == 1:
            payload["result_topic"] = result_topics[0]
        if args.domain in {"review-media", "showcase"}:
            payload["output"] = str(Path(args.output_dir or args.output).expanduser()) if (args.output_dir or args.output) else None
        _special_json(payload, args)
        return 0
    if args.domain == "review-media":
        return _run_review_media(request, args)
    if args.domain == "showcase":
        return _run_showcase(request, args)
    if args.domain == "viewer":
        return _run_viewer(request, args)
    if args.domain == "qa":
        return _run_qa(request, args)
    request, verb = _review_pin_request(args, parser)
    return _run_review_pin(request, verb, args)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Use --host SSH_ALIAS through fm to select a remote recorder or processor. "
               "Result lookup reads the service's retained last result; missing history is not success.",
    )
    parser.add_argument("domain", choices=["capture", "project", "dataset", "profile", "release", "provision"] + sorted(SPECIAL_DOMAINS))
    parser.add_argument("action", help="capture: list/show/status/start/stop/submit/discard/sync/sensors/result; project: list/create/rename/describe/delete/assign/unassign/result; dataset: list/show/status/create/rename/add/remove/move/result; profile: " + "/".join(PROFILE_ACTIONS) + "; release: " + "/".join(sorted(RELEASE_ACTIONS)))
    parser.add_argument("--model", choices=["qwen2.5-vl-7b", "qwen3.5-9b"])
    parser.add_argument("--name")
    parser.add_argument("--description")
    parser.add_argument("--project-id")
    parser.add_argument("--episode-id")
    parser.add_argument("--task-id")
    parser.add_argument("--instruction")
    parser.add_argument("--operator-id")
    parser.add_argument("--outcome", choices=["success", "failed", "unlabeled"])
    parser.add_argument("--sync-state", choices=["synced", "pending"])
    parser.add_argument("--disabled-device", action="append")
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
    parser.add_argument("--annotation-bundle-sha256", "--bundle-sha256", dest="annotation_bundle_sha256")
    parser.add_argument("--mode", choices=sorted(REVIEW_MEDIA_MODES))
    parser.add_argument("--topic-frame-index", type=int)
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--end-frame", type=int)
    parser.add_argument("--playback-rate", type=float)
    parser.add_argument("--max-fps", type=int)
    parser.add_argument("--output")
    parser.add_argument("--output-dir")
    parser.add_argument("--target-id")
    parser.add_argument("--pin-id")
    parser.add_argument("--inputfile")
    parser.add_argument("--endpoint", choices=sorted(VIEWER_ENDPOINTS))
    parser.add_argument("--dataset", dest="viewer_dataset")
    parser.add_argument("--author", default="first-motive")
    parser.add_argument("--limit", default="500")
    parser.add_argument("--full", dest="full", action="store_true", default=True)
    parser.add_argument("--no-full", dest="full", action="store_false")
    parser.add_argument("--file-id")
    parser.add_argument("--config", default="default")
    parser.add_argument("--split", default="train")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--length", type=int, default=20)
    args = parser.parse_args()
    if args.domain in SPECIAL_DOMAINS:
        return special_main(args, parser)
    actions = ({"list", "create", "rename", "describe", "delete", "assign", "unassign", "result"}
               if args.domain == "project" else {"list", "show", "status", "create", "rename", "add", "remove", "move", "result"})
    if args.domain == "capture":
        actions = {"list", "show", "status", "result"} | CAPTURE_ACTIONS
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
    if args.domain == "capture" and any((args.name, args.description, args.project_id,
            args.dataset_id, args.episode, args.destination)):
        parser.error("capture does not accept catalogue write options")
    if args.domain != "capture" and any(value is not None for value in (
            args.task_id, args.instruction, args.operator_id, args.outcome,
            args.sync_state, args.disabled_device)):
        parser.error("capture options require fm episode capture")
    request = request_for(args, parser)
    root = "/projects" if args.domain == "project" else "/process/datasets"
    command_topic = root + ("/command" if args.domain == "project" else "/" + args.action)
    result_topic = root + ("/result" if args.domain == "project" else "/status")
    if args.domain == "dataset" and args.action == "show":
        command_topic = root + "/select"
        result_topic = root + "/detail"
    if args.domain == "profile":
        command_topic = "/process/task_profiles/request"
        result_topic = "/process/task_profiles/result"
    if args.domain == "release":
        root = "/release"
        command_topic = root + ("/select" if args.action == "show" else "/" + args.action)
        result_topic = root + ("/detail" if args.action == "show" else "/status")
    if request is None and args.action != "result":
        result_topic = root + ("/index" if args.action == "list" else "/status")
    if args.domain == "capture":
        command_topic = "/capture/command" if args.action in CAPTURE_ACTIONS else "/capture/select"
        result_topic = {"list": "/capture/index", "show": "/capture/detail",
                        "status": "/fm_data_record/recorder_status"}.get(args.action, "/capture/result")
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
            detail_target=({"release": args.target, "dataset": args.dataset_id,
                           "capture": args.episode_id}.get(args.domain))
            if args.action == "show" else None,
            detail_key={"dataset": "dataset_id", "capture": "session"}.get(args.domain, "target_id"),
            inspect_release=args.domain == "release" and args.action == "result",
            provision=args.domain == "provision",
        )
        if matched is not None:
            result = matched

    qos = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                     durability=DurabilityPolicy.TRANSIENT_LOCAL)
    subscription = node.create_subscription(String, result_topic, receive, qos)
    refusal_subscription = (
        node.create_subscription(String, root + "/status", receive, qos)
        if args.domain == "dataset" and args.action == "show" else None
    )
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
            if args.domain == "capture":
                print({
                    "list": "No capture index received from the selected host.",
                    "status": "No recorder status received from the selected host.",
                    "show": "No correlated recording detail received. Check the selected host and capture browser request-ID support.",
                }.get(args.action, "No matching capture result. The outcome is unknown; inspect the same request before retrying."), file=sys.stderr)
            else:
                print("No result. Inspect the same request before retrying; the outcome is unknown."
                      if request else "No catalogue received.", file=sys.stderr)
            return 3
        print(json.dumps(result, indent=None if args.json else 2, sort_keys=True))
        return 3 if result.get("ok") is False or result.get("issue_code") or result.get("error") else 0
    except KeyboardInterrupt:
        print("Stopped waiting. Remote work was not cancelled.", file=sys.stderr)
        return 130
    finally:
        node.destroy_subscription(subscription)
        if refusal_subscription is not None:
            node.destroy_subscription(refusal_subscription)
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
