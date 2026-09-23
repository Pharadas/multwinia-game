#!/usr/bin/env python3
"""Checks that a wss:// endpoint actually reaches the game's WebSocket server.

This is the quickest way to answer "is my tunnel/host reachable from outside?"
without involving a browser: it speaks the WebSocket protocol directly (no
third-party packages), asks for the terrain and reports what came back.

  # local TLS termination, as set up by Tests/tls_ws_proxy.py
  python3 Tests/wss_smoke.py --url wss://127.0.0.1:9443 --insecure

  # a real tunnel, e.g. from `cloudflared tunnel --url http://localhost:9080`
  python3 Tests/wss_smoke.py --url wss://something-words.trycloudflare.com

  # plain ws:// (LAN)
  python3 Tests/wss_smoke.py --url ws://192.168.1.82:9080
"""

import argparse
import base64
import json
import os
import socket
import ssl
import struct
import sys
import urllib.parse


def connect(url: str, insecure: bool) -> socket.socket:
    parts = urllib.parse.urlsplit(url)
    secure = parts.scheme == "wss"
    host = parts.hostname or "127.0.0.1"
    port = parts.port or (443 if secure else 80)
    raw = socket.create_connection((host, port), timeout=10)
    if secure:
        ctx = ssl._create_unverified_context() if insecure else ssl.create_default_context()
        raw = ctx.wrap_socket(raw, server_hostname=host)
    return raw


def handshake(sock: socket.socket, url: str) -> None:
    parts = urllib.parse.urlsplit(url)
    path = parts.path or "/"
    if parts.query:
        path += "?" + parts.query
    host_header = parts.hostname or "127.0.0.1"
    if parts.port:
        host_header += ":%d" % parts.port
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        "GET %s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n" % (path, host_header, key)
    )
    sock.sendall(request.encode())

    header = b""
    while b"\r\n\r\n" not in header:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("connection closed during handshake (%r)" % header[:120])
        header += chunk
    status = header.split(b"\r\n", 1)[0].decode(errors="replace")
    if "101" not in status:
        raise RuntimeError("handshake refused: %s" % status)
    print("handshake: %s" % status)
    return header.split(b"\r\n\r\n", 1)[1]


def send_text(sock: socket.socket, text: str) -> None:
    payload = text.encode()
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    header = bytes([0x81])
    if len(payload) < 126:
        header += bytes([0x80 | len(payload)])
    elif len(payload) < 1 << 16:
        header += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", len(payload))
    sock.sendall(header + mask + masked)


def read_frames(sock: socket.socket, pending: bytes) -> tuple:
    """Reads until the received (unmasked) text is valid JSON. Returns
    (message, leftover bytes)."""
    buf = pending
    payloads = []

    def need(n: int) -> None:
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(65536)
            if not chunk:
                raise RuntimeError("connection closed while reading a frame")
            buf += chunk

    while True:
        need(2)
        b0, b1 = buf[0], buf[1]
        opcode = b0 & 0x0F
        masked = b1 & 0x80
        length = b1 & 0x7F
        idx = 2
        if length == 126:
            need(4)
            length = struct.unpack(">H", buf[2:4])[0]
            idx = 4
        elif length == 127:
            need(10)
            length = struct.unpack(">Q", buf[2:10])[0]
            idx = 10
        mask = b""
        if masked:
            need(idx + 4)
            mask = buf[idx:idx + 4]
            idx += 4
        need(idx + length)
        data = buf[idx:idx + length]
        if masked:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        buf = buf[idx + length:]

        if opcode == 0x8:
            raise RuntimeError("server closed the socket")
        if opcode == 0x9:  # ping -> pong
            continue
        payloads.append(data)
        try:
            return json.loads(b"".join(payloads).decode()), buf
        except ValueError:
            continue  # partial frame / fragmentation: keep reading


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="wss://host or ws://host:port")
    ap.add_argument("--insecure", action="store_true",
                    help="skip TLS verification (self-signed test certs)")
    ap.add_argument("--col", type=int, default=20)
    ap.add_argument("--row", type=int, default=10)
    args = ap.parse_args()

    print("connecting to %s ..." % args.url)
    sock = connect(args.url, args.insecure)
    try:
        leftover = handshake(sock, args.url)

        sock.settimeout(15)
        send_text(sock, json.dumps({"type": "request_terrain"}))
        print("sent request_terrain")
        # The server greets a fresh client with its team number, so the first
        # message is usually assigned_team - wait for the terrain itself.
        msg = {}
        for _ in range(10):
            msg, leftover = read_frames(sock, leftover)
            print("received: %s" % json.dumps(msg)[:160])
            if msg.get("type") == "terrain":
                break
        if msg.get("type") != "terrain":
            print("FAIL: no terrain reply")
            return 1
        tiles = msg.get("tiles", [])
        print("terrain received: %d tiles (first: %s)" %
              (len(tiles), json.dumps(tiles[0])[:120] if tiles else "-"))
        if not tiles:
            print("FAIL: empty terrain")
            return 1

        sock.settimeout(10)
        send_text(sock, json.dumps(
            {"type": "tile_clicked", "col": args.col, "row": args.row, "team": 0}))
        print("sent tile_clicked %d,%d" % (args.col, args.row))
        print("OK - wss reached the game server and carried real data")
        return 0
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
