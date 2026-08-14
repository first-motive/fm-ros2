"""Ask the foxglove bridge what it advertises, using only the stdlib.

The bridge is what the desktop app connects to, so it is the honest oracle: a
node can be running and publishing yet sit in a DDS scope the bridge cannot see.
`ros2 topic list` is NOT a substitute — a fresh CLI participant on this appliance
often discovers only a fraction of the graph, which yields false failures.
"""
import base64, json, os, socket, sys
from pathlib import Path

DEFAULT_PORT = 8765
DEFAULT_ENV_FILE = "/etc/fm-bridge.env"


def _configured_port():
    """Read the durable bridge file, then the environment, then the default."""
    raw = os.environ.get("FM_BRIDGE_PORT")
    env_file = os.environ.get("FM_BRIDGE_ENV_FILE", DEFAULT_ENV_FILE)
    try:
        for line in Path(env_file).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("FM_BRIDGE_PORT="):
                raw = line.split("=", 1)[1].strip().strip('"').strip("'")
                break
    except OSError:
        pass
    try:
        port = int(raw or DEFAULT_PORT)
    except ValueError as exc:
        raise ValueError(f"FM_BRIDGE_PORT must be an integer, got {raw!r}") from exc
    if not 1 <= port <= 65535:
        raise ValueError(f"FM_BRIDGE_PORT must be between 1 and 65535, got {port}")
    return port


HOST, PORT = "127.0.0.1", _configured_port()
WANT = sys.argv[1:] or ["/watchdog/active", "/episode_qa/session"]


def frames(sock, buf=b""):
    """Yield text payloads from a server->client WebSocket stream (unmasked)."""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return
        buf += chunk
        while len(buf) >= 2:
            opcode = buf[0] & 0x0F
            length = buf[1] & 0x7F
            offset = 2
            if length == 126:
                if len(buf) < 4:
                    break
                length = int.from_bytes(buf[2:4], "big"); offset = 4
            elif length == 127:
                if len(buf) < 10:
                    break
                length = int.from_bytes(buf[2:10], "big"); offset = 10
            if len(buf) < offset + length:
                break
            payload, buf = buf[offset:offset + length], buf[offset + length:]
            if opcode == 1:
                yield payload


def main():
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection((HOST, PORT), timeout=10)
    sock.settimeout(10)
    sock.sendall(
        f"GET / HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"Sec-WebSocket-Protocol: foxglove.websocket.v1, foxglove.sdk.v1\r\n\r\n"
        .encode())
    # Consume the HTTP 101 response before frame parsing — its bytes arrive in the
    # same stream and would otherwise be decoded as a malformed frame.
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            print("bridge closed the connection during handshake")
            return 1
        head += chunk
    header, _, rest = head.partition(b"\r\n\r\n")
    if b"101" not in header.split(b"\r\n")[0]:
        print(f"bridge refused the upgrade: {header.split(chr(13).encode())[0][:80]!r}")
        return 1
    topics, seen = set(), 0
    try:
        for payload in frames(sock, rest):
            try:
                msg = json.loads(payload)
            except ValueError:
                continue
            if msg.get("op") == "advertise":
                # The bridge sends channels in several batches; one is not enough.
                topics.update(c["topic"] for c in msg.get("channels", []))
                seen += 1
                if seen >= 3:
                    break
    except (socket.timeout, OSError):
        pass
    finally:
        sock.close()
    print(f"bridge advertises {len(topics)} topics")
    missing = [t for t in WANT if t not in topics]
    for t in WANT:
        print(f"  {'yes' if t in topics else 'NO '}  {t}")
    return 1 if missing or not topics else 0


if __name__ == "__main__":
    sys.exit(main())
