#!/usr/bin/env python3
"""Probe the configured local First Motive Foxglove bridge port.

This is deliberately a bounded TCP probe. It does not claim that a bridge has
the expected ROS channels; it answers only whether the configured listener is
reachable, which is the useful preflight for service ownership and boot checks.
"""

from __future__ import annotations

import argparse
import os
import socket
from pathlib import Path

DEFAULT_PORT = 8765
DEFAULT_ENV_FILE = "/etc/fm-bridge.env"


def _file_port(path: str) -> str | None:
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() == "FM_BRIDGE_PORT":
            return value.strip().strip('"').strip("'")
    return None


def _port(cli_port: int | None) -> int:
    raw = cli_port
    if raw is None:
        raw = _file_port(os.environ.get("FM_BRIDGE_ENV_FILE", DEFAULT_ENV_FILE))
    if raw is None:
        raw = os.environ.get("FM_BRIDGE_PORT", str(DEFAULT_PORT))
    try:
        port = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"FM_BRIDGE_PORT must be an integer, got {raw!r}") from exc
    if not 1 <= port <= 65535:
        raise ValueError(f"FM_BRIDGE_PORT must be between 1 and 65535, got {port}")
    return port


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="probe host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, help="override the configured bridge port")
    parser.add_argument("--timeout", type=float, default=1.0, help="connect timeout in seconds")
    parser.add_argument("--print", action="store_true", dest="print_endpoint", help="print the resolved endpoint without connecting")
    args = parser.parse_args()
    try:
        port = _port(args.port)
    except ValueError as exc:
        parser.error(str(exc))
    if args.print_endpoint:
        print(f"{args.host}:{port}")
        return 0
    try:
        with socket.create_connection((args.host, port), timeout=args.timeout):
            pass
    except OSError as exc:
        print(f"bridge probe failed: {args.host}:{port}: {exc}", file=os.sys.stderr)
        return 1
    print(f"bridge probe OK: {args.host}:{port}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
