#!/usr/bin/env python3
"""Serve the Mac's camera as an MJPEG stream for the container.

OrbStack cannot pass a USB/built-in camera into a Linux container, so a containerised
node (e.g. fm_teleop_vision's vision_source) cannot open camera index 0 directly. This
host-side bridge opens the camera natively on macOS (AVFoundation) and re-serves it as a
plain MJPEG HTTP stream; the container reads it the same way it reads a phone IP-webcam:

    # On the Mac host (camera permission must be granted to the terminal app):
    uv run --with opencv-python-headless python scripts/run/mac_camera_bridge.py --port 8090

    # In the container / launch:
    camera_source:=http://host.docker.internal:8090/video

Two macOS specifics, both handled here:
  - The camera is opened on the MAIN thread. AVFoundation's authorization spins the main
    run loop; opening from an HTTP worker thread fails with "can not spin main run loop".
  - OPENCV_AVFOUNDATION_SKIP_AUTH=1 skips OpenCV's in-app auth request and relies on the
    TCC grant the terminal already has (System Settings -> Privacy -> Camera).

Device selection: with an iPhone nearby, macOS Continuity Camera often claims index 0, so
the built-in FaceTime camera may be index 1. Pass --device to pick. One consumer (the
vision node) is expected; the single shared capture is read under a lock.
"""

from __future__ import annotations

import os

# Must be set before OpenCV initialises the AVFoundation backend.
os.environ.setdefault("OPENCV_AVFOUNDATION_SKIP_AUTH", "1")

import argparse  # noqa: E402  (env var above must precede the cv2 import)
import threading  # noqa: E402
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer  # noqa: E402

import cv2  # noqa: E402

_BOUNDARY = "frame"


class _MjpegHandler(BaseHTTPRequestHandler):
    capture = None  # shared cv2.VideoCapture, opened on the main thread
    lock = threading.Lock()
    quality = 80

    def log_message(self, *args):
        pass  # quiet; a single long-lived stream makes the access log noise

    def do_GET(self):
        if self.path not in ("/video", "/"):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header(
            "Content-Type", f"multipart/x-mixed-replace; boundary={_BOUNDARY}"
        )
        self.end_headers()
        params = [cv2.IMWRITE_JPEG_QUALITY, self.quality]
        try:
            while True:
                with self.lock:
                    ok, frame = self.capture.read()
                if not ok:
                    continue
                ok, buf = cv2.imencode(".jpg", frame, params)
                if not ok:
                    continue
                self.wfile.write(b"--" + _BOUNDARY.encode() + b"\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(f"Content-Length: {len(buf)}\r\n\r\n".encode())
                self.wfile.write(buf.tobytes())
                self.wfile.write(b"\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass  # client (the node) disconnected — normal on teleop shutdown


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--device", type=int, default=0, help="camera index")
    parser.add_argument("--width", type=int, default=0, help="0 = camera default")
    parser.add_argument("--height", type=int, default=0)
    parser.add_argument("--quality", type=int, default=80, help="JPEG quality 1-100")
    args = parser.parse_args()

    # Open on the main thread so AVFoundation can authorise; workers then just read().
    cap = cv2.VideoCapture(args.device)
    if args.width:
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    if args.height:
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    if not cap.isOpened():
        raise SystemExit(
            f"camera {args.device} did not open. Try a different --device "
            "(Continuity Camera often takes 0; built-in may be 1), and confirm the "
            "terminal has camera access in System Settings -> Privacy -> Camera."
        )
    ok, _ = cap.read()
    if not ok:
        raise SystemExit(
            f"camera {args.device} opened but read no frame — likely a permission block. "
            "Grant the terminal camera access in System Settings -> Privacy -> Camera."
        )

    _MjpegHandler.capture = cap
    _MjpegHandler.quality = args.quality
    # Bind 0.0.0.0 (not 127.0.0.1): the container reaches the host via
    # host.docker.internal, which maps to the host's gateway IP, not loopback, so a
    # loopback bind would block it. Trade-off: the unauthenticated camera stream is
    # reachable by any host on the LAN. Acceptable for a manual, ephemeral dev tool on
    # a trusted network — do not run it on an untrusted one.
    server = ThreadingHTTPServer(("0.0.0.0", args.port), _MjpegHandler)
    print(
        f"MJPEG bridge: camera {args.device} -> http://0.0.0.0:{args.port}/video  "
        f"(container: http://host.docker.internal:{args.port}/video)",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cap.release()


if __name__ == "__main__":
    main()
