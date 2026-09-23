#!/usr/bin/env python3
"""Local stand-in for the itch.io / GitHub Pages setup, so the "HTTPS page
connecting over wss://" path can be tested without a public tunnel.

It runs two servers off one self-signed certificate:

  * an HTTPS static server for the web export (default 8443)
  * a TLS-terminating proxy (default 9443) that hands the decrypted bytes to
    the game's plain WebSocket server (default 127.0.0.1:9080)

Connecting a browser to wss://127.0.0.1:9443 therefore exercises exactly the
same code path as a real tunnel: TLS page -> wss:// -> game.

Certificate (self-signed, throwaway):
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 \\
    -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" \\
    -keyout /tmp/mw_key.pem -out /tmp/mw_cert.pem

Usage:
  python3 Tests/tls_ws_proxy.py --root Builds/Web --cert /tmp/mw_cert.pem \\
      --key /tmp/mw_key.pem
"""

import argparse
import functools
import http.server
import socket
import ssl
import threading


def tls_context(cert: str, key: str) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    return ctx


def serve_pages(root: str, port: int, ctx: ssl.SSLContext) -> None:
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"HTTPS page server on https://127.0.0.1:{port} (root={root})", flush=True)
    httpd.serve_forever()


def pipe(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def handle_client(conn: socket.socket, target_host: str, target_port: int) -> None:
    try:
        upstream = socket.create_connection((target_host, target_port))
    except OSError as exc:
        print(f"ws proxy: cannot reach game server: {exc}", flush=True)
        conn.close()
        return
    threading.Thread(target=pipe, args=(conn, upstream), daemon=True).start()
    pipe(upstream, conn)
    conn.close()
    upstream.close()


def serve_wss_proxy(port: int, ctx: ssl.SSLContext, target: str) -> None:
    host, _, port_s = target.partition(":")
    target_port = int(port_s or 9080)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", port))
    listener.listen(16)
    print(f"TLS WebSocket proxy: wss://127.0.0.1:{port} -> {host}:{target_port}", flush=True)
    while True:
        raw, _ = listener.accept()
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
        except ssl.SSLError as exc:
            print(f"ws proxy: TLS handshake failed: {exc}", flush=True)
            raw.close()
            continue
        threading.Thread(target=handle_client, args=(conn, host, target_port), daemon=True).start()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="Builds/Web")
    ap.add_argument("--page-port", type=int, default=8443)
    ap.add_argument("--ws-port", type=int, default=9443)
    ap.add_argument("--target", default="127.0.0.1:9080")
    ap.add_argument("--cert", default="/tmp/mw_cert.pem")
    ap.add_argument("--key", default="/tmp/mw_key.pem")
    args = ap.parse_args()

    ctx = tls_context(args.cert, args.key)
    threading.Thread(target=serve_pages, args=(args.root, args.page_port, ctx), daemon=True).start()
    serve_wss_proxy(args.ws_port, ctx, args.target)


if __name__ == "__main__":
    main()
