#!/usr/bin/env python3
"""mc.fxmq.net homepage + server status.

Serves the Minecraft-styled landing page at / and a /status JSON endpoint
that pings the game server's public ports from the host bridge gateway
(172.22.0.1). The game server (PufferPanel server 2ecfbe8c) runs with
`environment.networkName = host`, so the bridge gateway reaches its ports
whenever the server is running. Both probes are read-only pings — no rcon,
no docker socket, no writes.

  Java   :25565  TCP server-list ping (version + player counts when online)
  Bedrock:19132  UDP RakNet unconnected ping (version + player counts)

Stdlib only (http.server) — no Flask/pip deps.
"""

import json
import socket
import struct
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BRIDGE_HOST = "172.22.0.1"  # host bridge gateway (game server is host-net)
JAVA_PORT = 25565
BEDROCK_PORT = 19132
CONNECT_TIMEOUT = 2.0
READ_TIMEOUT = 1.5

MAGIC = bytes([0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
               0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78])

INDEX = Path(__file__).parent / "index.html"


def _varint(n):
    out = bytearray()
    n &= 0xFFFFFFFF
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _read_varint(sock):
    shift = 0
    val = 0
    while True:
        b = sock.recv(1)
        if not b:
            raise ConnectionError("eof")
        val |= (b[0] & 0x7F) << shift
        if not (b[0] & 0x80):
            return val
        shift += 7


def _read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("eof")
        buf += chunk
    return buf


def _as_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def probe_java():
    """Modern server-list ping (status protocol). online + details."""
    try:
        sock = socket.create_connection((BRIDGE_HOST, JAVA_PORT), timeout=CONNECT_TIMEOUT)
    except OSError:
        return {"online": False}
    try:
        with sock:
            sock.settimeout(READ_TIMEOUT)
            host = b"mc.fxmq.net"
            hs = (b"\x00" + _varint(-1) + _varint(len(host)) + host
                  + struct.pack(">H", JAVA_PORT) + b"\x01")
            req = b"\x00"
            sock.sendall(_varint(len(hs)) + hs + _varint(len(req)) + req)
            _read_varint(sock)  # packet length
            if _read_varint(sock) != 0:
                return {"online": True}
            info = json.loads(_read_exact(sock, _read_varint(sock)).decode("utf-8", "replace"))
            return {
                "online": True,
                "version": (info.get("version") or {}).get("name"),
                "players": _as_int((info.get("players") or {}).get("online")),
                "max": _as_int((info.get("players") or {}).get("max")),
            }
    except (OSError, ConnectionError, ValueError, KeyError):
        # Connected but no valid status response (e.g. still booting) —
        # the port answered, so report online without details.
        return {"online": True}


def probe_bedrock():
    """RakNet unconnected ping (0x01) -> pong (0x1c) with server info."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(READ_TIMEOUT + 0.5)
    try:
        ts = struct.pack(">q", int(time.time() * 1000))
        guid = struct.pack(">q", 0x00FEEDFACE)
        sock.sendto(b"\x01" + ts + MAGIC + guid, (BRIDGE_HOST, BEDROCK_PORT))
        data, _ = sock.recvfrom(4096)
        if not data or data[0] != 0x1C:
            return {"online": False}
        payload = data[33:]  # id(1) + ping time(8) + server guid(8) + magic(16)
        slen = struct.unpack(">H", payload[:2])[0]
        text = payload[2:2 + slen].decode("utf-8", "replace")
        fields = text.split(";")
        out = {"online": True}
        if len(fields) >= 6:
            out["version"] = fields[3] or None
            out["players"] = _as_int(fields[4])
            out["max"] = _as_int(fields[5])
        return out
    except OSError:
        return {"online": False}
    finally:
        sock.close()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence access logs
        pass

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._send(200, "ok", "text/plain")
        elif path == "/status":
            self._send(200, json.dumps({
                "java": probe_java(),
                "bedrock": probe_bedrock(),
                "checked_at": int(time.time()),
            }), "application/json")
        elif path in ("/", "/index.html"):
            self._send(200, INDEX.read_bytes(), "text/html; charset=utf-8")
        else:
            self._send(404, "not found", "text/plain")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 5000), Handler).serve_forever()
