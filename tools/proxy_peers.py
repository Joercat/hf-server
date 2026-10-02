#!/usr/bin/env python3
"""proxy_peers.py - the addresses of the proxy that sits in front of the game port.

Everything that reaches the game port (7860) from outside goes through the
Hugging Face ingress, so the *peers* of the listening socket are the ingress's
own addresses - never a player's.  Comparing a logged player address with them
is what answers the question the logs alone cannot:

  * the address equals a proxy peer -> the log holds the PROXY's address, not
    the player's (no forwarded header is in use, so two logins can legitimately
    show two different addresses for one player: the ingress has several nodes)
  * it does not                     -> the log holds the player's own address

No `ss`/`iproute2` needed: the kernel's own tables are read (/proc/net/tcp and
/proc/net/tcp6, where they exist).

usage:
  proxy_peers.py                       # peers of port 7860
  proxy_peers.py --port 25565 --json
  proxy_peers.py --proc-dir ./fixture  # for the tests

Exit code is 0 even when nothing can be read - "no peers" is a valid answer.
"""

import argparse
import ipaddress
import json
import os
import sys


def decode_v4(hex_addr: str):
    raw = bytes.fromhex(hex_addr)
    if len(raw) != 4:
        return None
    return str(ipaddress.IPv4Address(raw[::-1]))


def decode_v6(hex_addr: str):
    raw = bytes.fromhex(hex_addr)
    if len(raw) != 16:
        return None
    # /proc/net/tcp6 stores the address as four 32-bit words, each in host
    # (little endian) byte order
    out = b""
    for i in range(4):
        out += raw[i * 4:(i + 1) * 4][::-1]
    return str(ipaddress.IPv6Address(out))


def split_addr(field: str):
    if ":" not in field:
        return None, None
    hex_addr, _, hex_port = field.rpartition(":")
    try:
        port = int(hex_port, 16)
    except ValueError:
        return None, None
    return hex_addr, port


def peers(port: int, proc_dir: str = "/proc"):
    found = []
    for name, decode in (("tcp", decode_v4), ("tcp6", decode_v6)):
        path = os.path.join(proc_dir, "net", name)
        try:
            with open(path, "r") as fh:
                lines = fh.read().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            parts = line.split()
            if len(parts) < 4:
                continue
            local_addr, local_port = split_addr(parts[1])
            rem_addr, rem_port = split_addr(parts[2])
            if local_port != port or not rem_port:
                continue
            if set(rem_addr) == {"0"}:          # the listening socket itself
                continue
            addr = decode(rem_addr)
            if addr and addr not in found:
                found.append(addr)
    return sorted(found, key=lambda a: (0 if "." in a else 1, ipaddress.ip_address(a).packed))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="addresses of the proxy in front of the game port")
    ap.add_argument("--port", type=int, default=7860)
    ap.add_argument("--proc-dir", default="/proc")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    found = peers(args.port, args.proc_dir)
    if args.json:
        print(json.dumps({
            "port": args.port,
            "peers": found,
            "ipv4": len([a for a in found if ":" not in a]),
            "ipv6": len([a for a in found if ":" in a]),
        }))
    else:
        for addr in found:
            print(addr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
