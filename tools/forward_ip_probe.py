#!/usr/bin/env python3
"""
forward_ip_probe.py - does the reverse proxy in front of the server send a
forwarded-IP header, and which one?

Behind the Hugging Face ingress (or any reverse proxy) the game sees the proxy
as the peer, so every player would otherwise be logged with the proxy's IP.
EaglerXBungee can read the real client IP from a header, but it is strict: with
`forward_ip: true` a connection *without* that header is closed immediately
("Connected without a 'X-Real-IP' header, disconnecting..."). So the header has
to be discovered before it is trusted, and this tool does that.

It performs a real WebSocket upgrade against the public URL - i.e. through the
same proxy players use - and reports the HTTP status line:

  101 Switching Protocols   the proxy passed the header through, the plugin
                            accepted the connection
  anything else / closed    the plugin refused it (header missing or invalid)

Exit code 0 = the upgrade was accepted, 1 = refused, 2 = the probe itself could
not run (no network, bad URL, ...).

usage:
  forward_ip_probe.py                       # https://smodusermc-12.hf.space/
  forward_ip_probe.py --url https://host/ --timeout 12
"""

import argparse
import base64
import os
import socket
import ssl
import sys
from urllib.parse import urlparse


def probe(host, port, path, timeout, verbose=False):
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Origin: https://{host}\r\n"
        "User-Agent: Mozilla/5.0 (EaglercraftX probe)\r\n"
        "\r\n"
    )
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=timeout) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as sock:
            sock.sendall(request.encode("ascii"))
            data = sock.recv(2048)
    if not data:
        return "", "the connection was closed without a reply"
    head = data.split(b"\r\n", 1)[0].decode("latin1", "replace")
    rest = data.decode("latin1", "replace")
    if verbose:
        print(rest[:400], file=sys.stderr)
    return head, ""


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=os.environ.get("PUBLIC_URL", "https://smodusermc-12.hf.space/"),
                    help="public URL of the server (the one players use)")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    url = urlparse(args.url)
    host = url.hostname
    port = url.port or (443 if url.scheme != "http" else 80)
    path = url.path or "/"
    if not host:
        print(f"probe: unparsable URL {args.url!r}")
        return 2

    try:
        head, why = probe(host, port, path, args.timeout, args.verbose)
    except Exception as exc:                       # noqa: BLE001 - report anything
        print(f"probe: {host}:{port} unreachable ({exc.__class__.__name__}: {exc})")
        return 2

    if head.startswith("HTTP/1.1 101") or head.startswith("HTTP/1.0 101"):
        print(f"probe: upgrade accepted ({head})")
        return 0
    print(f"probe: upgrade refused ({head or why})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
