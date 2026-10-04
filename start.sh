#!/bin/bash

JAVA_HOME_DIR=$(find /usr/lib/jvm -maxdepth 1 -name "java-17-openjdk-*" -type d 2>/dev/null | head -1)
if [ -z "$JAVA_HOME_DIR" ]; then
    echo "ERROR: Java 17 not found!"
    exit 1
fi
JAVA="$JAVA_HOME_DIR/bin/java"

BUNGEE_DIR="/opt/server/bungee"
BACKEND_DIR="/opt/server/backend"
PLUGIN_DIR="$BACKEND_DIR/plugins"

# Security log locations (append-only, synced to the HF bucket every
# $SYNC_INTERVAL seconds, see SAVE_DIRS below):
#   hf://buckets/smodusermc/1.12/game-data/security-logs/logins.log
#   hf://buckets/smodusermc/1.12/game-data/security-logs/commands.log
#   hf://buckets/smodusermc/1.12/game-data/security-logs/client-checks.log
#   hf://buckets/smodusermc/1.12/game-data/security-logs/shared-ips.txt
SEC_DIR="$BACKEND_DIR/security-logs"
LOGIN_LOG="$SEC_DIR/logins.log"
CMD_LOG="$SEC_DIR/commands.log"
SHARED_REPORT="$SEC_DIR/shared-ips.txt"
CLIENT_LOG="$SEC_DIR/client-checks.log"

# Private log locations - NEVER synced to the bucket (private-logs is not in
# SAVE_DIRS, see the check further down):
#   auth.log        full /login, /register, /changepassword lines (passwords in
#                   clear, for password resets) - everything except the
#                   verified client, i.e. your own password is never written
#   player-ips.log  the real IPs that were hidden as "ip=hidden" in the synced
#                   logs, in case you ever need to look your own up
PRIV_DIR="$BACKEND_DIR/private-logs"
AUTH_LOG="$PRIV_DIR/auth.log"
IP_MAP_FILE="$PRIV_DIR/player-ips.log"

# Runtime caches (in /tmp, never written to disk)
#   VERDICT_CACHE : "<name>\t<VERDICT>" - last verdict per player
#   IP_MAP        : "<name>\t<ip>\t<source>\t<epoch>" - every sighting, so the
#                   newest real address wins and placeholders never do
#   PENDING_AUTH  : auth commands waiting for the player's client verdict
VERDICT_CACHE="/tmp/client-verdicts.txt"
IP_MAP="/tmp/client-ips.txt"
PENDING_AUTH="/tmp/pending-auth-commands.tsv"
AUTH_SEEN="/tmp/auth-commands-seen.tsv"
: > "$VERDICT_CACHE"; : > "$IP_MAP"; : > "$PENDING_AUTH"; : > "$AUTH_SEEN"

# Bungee console pipe - lets this script run commands on the proxy, it is used
# to ask EaglerXBungee which client a player is using (/client-brand)
BUNGEE_CONSOLE="$BUNGEE_DIR/console.pipe"

mkdir -p "$PLUGIN_DIR" "$SEC_DIR" "$PRIV_DIR"

HF_BUCKET_HANDLE="hf://buckets/smodusermc/1.12"

# The bucket is the only place the logs can be read from outside the Space, so
# BOTH log folders are synced:
#   game-data/security-logs/  logins.log, commands.log, client-checks.log, shared-ips.txt
#   game-data/private-logs/   auth.log (full /login lines), player-ips.log (the
#                             real IPs that show as "hidden"), the private reports
# SYNC_PRIVATE_LOGS=false uploads only the sanitised security-logs (then
# auth.log and the real IPs stay inside the Space - and you cannot read them
# from outside either).
SYNC_PRIVATE_LOGS="${SYNC_PRIVATE_LOGS:-true}"

SAVE_DIRS="world world_nether world_the_end players banned-ips.json banned-players.json ops.json whitelist.json plugins security-logs"
[ "$SYNC_PRIVATE_LOGS" = true ] && SAVE_DIRS="$SAVE_DIRS private-logs"

if [ "$SYNC_PRIVATE_LOGS" = true ]; then
    echo "NOTE: private-logs is synced to the bucket - it contains clear-text"
    echo "      passwords (auth.log) and the real IPs hidden in the public logs."
    echo "      Keep $HF_BUCKET_HANDLE private."
fi

SYNC_INTERVAL="${SYNC_INTERVAL:-300}"
# logs are small, so they get their own much faster sync (in seconds)
LOG_SYNC_INTERVAL="${LOG_SYNC_INTERVAL:-60}"
# also upload the tail of the raw Paper/Bungee consoles (boot errors, crashes)
# to game-data/logs/ so they can be read without access to the Space
SYNC_CONSOLE_LOGS="${SYNC_CONSOLE_LOGS:-true}"
CONSOLE_LOG_LINES="${CONSOLE_LOG_LINES:-1000}"
FULL_STAGING="/tmp/hf-staging"
LOG_STAGING="/tmp/hf-log-staging"

# How the bucket is written: `auto` tries the hf CLI first and falls back to
# the Python API (huggingface_hub ships in the image), `cli` / `python` force
# one of them. A write probe runs at boot and says clearly which one works and
# what to do when neither does.
BUCKET_METHOD="${BUCKET_METHOD:-auto}"
BUCKET_SYNC_PY="${BUCKET_SYNC_PY:-/tmp/bucket_sync.py}"
BUCKET_VIA=""
BUCKET_ERROR=""
# Every login is seen by the proxy, by Paper and by the RCON player list; the
# name is marked online so only the first of them writes a LOGIN row.
ONLINE_STATE="${ONLINE_STATE:-/tmp/online-players.txt}"
# how often the RCON player list is polled as the safety net for logins that
# never showed up in a log line (a different Paper version, a rotated file, ...)
PLAYERLIST_POLL="${PLAYERLIST_POLL:-20}"
IDLE_MODE=false

# =============================================
# OP ACCOUNT
# =============================================
OP_USERNAME="CreppyBitch"

# =============================================
# VERIFIED CLIENT  (see docs/verified-client.md)
# =============================================
# The client (built with tools/setup-verified-client.sh) reports a custom brand
# instead of the stock "Eaglercraft 1.12". The brand becomes the 16 byte "brand
# UUID" the client sends during the Eagler handshake with
#
#     brandUUID = UUID.nameUUIDFromBytes("EaglercraftXClient:" + brand)
#
# so the server can tell that one client apart from everybody else and mark
# those logins in the logs.
#
# THIS PAIR IS A SECRET AND IS NOT STORED IN THIS REPOSITORY. This repo is
# public, so any brand written down here can be copied into somebody else's
# client - they would then show up as "verified" without ever having your
# client. Two consequences:
#
#   * the pair comes from the environment (Space -> Settings -> Variables and
#     secrets) or from the git-ignored .verified-client.env next to this
#     script, and
#   * every brand that was ever committed here is refused (see
#     PUBLISHED_CLIENT_BRANDS below), even if somebody configures it.
#
# Rotating = tools/setup-verified-client.sh --rotate, then put the printed
# values into the Space and restart. Nothing in this file has to change.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# the baked-in pair: XOR'd with the key below, then base64 (python3 decodes it;
# the whole thing is a few bytes and only runs before the server starts)
VERIFIED_CLIENT_PAIR_B64="q+UqfwTaozWljKaZWoxo/ZK1eSJXy5gusPfwmhapC7iLtSs+AMvLe/zip5kW/0e51rJ4dgQ="
VERIFIED_CLIENT_PAIR_KEY="ee844d1361a8fb18d1dac5f822c8268b"

verified_client_decode_pair() {
    python3 -c '
import base64, sys
blob = base64.b64decode(sys.argv[1])
key = bytes.fromhex(sys.argv[2])
sys.stdout.write(bytes(b ^ key[i % len(key)] for i, b in enumerate(blob)).decode("utf-8"))
' "$VERIFIED_CLIENT_PAIR_B64" "$VERIFIED_CLIENT_PAIR_KEY"
}

VERIFIED_CLIENT_SOURCE=""

# 1. the environment wins. That is how the Space passes the pair in as
#    variables/secrets, and how a rotation reaches this script without editing
#    it: set both, restart, done.
VERIFIED_CLIENT_BRAND="${VERIFIED_CLIENT_BRAND:-}"
VERIFIED_CLIENT_UUID="${VERIFIED_CLIENT_UUID:-}"
[ -n "$VERIFIED_CLIENT_BRAND" ] && [ -n "$VERIFIED_CLIENT_UUID" ] && VERIFIED_CLIENT_SOURCE="environment"

# 2. the git-ignored file next to this script (local runs, tests)
if [ -z "$VERIFIED_CLIENT_SOURCE" ] && [ -s "$SCRIPT_DIR/.verified-client.env" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/.verified-client.env"
    VERIFIED_CLIENT_BRAND="${VERIFIED_CLIENT_BRAND:-}"
    VERIFIED_CLIENT_UUID="${VERIFIED_CLIENT_UUID:-}"
    [ -n "$VERIFIED_CLIENT_BRAND" ] && [ -n "$VERIFIED_CLIENT_UUID" ] && VERIFIED_CLIENT_SOURCE=".verified-client.env"
fi

# 3. the pair baked in below. It is stored XOR'd + base64 (see the key), the
#    same idea as the client: it is never written down in readable text - not
#    here and not in the client file either (that one only carries a PBKDF2
#    verifier of the brand). This is obfuscation, not encryption: what really
#    hides the brand is that nobody can read it out of the client without the
#    login. Rotate with tools/setup-verified-client.sh --rotate --upload.
if [ -z "$VERIFIED_CLIENT_SOURCE" ]; then
    _pair=$(verified_client_decode_pair 2>/dev/null)
    if [ -n "$_pair" ] && [ "${_pair#*|}" != "$_pair" ]; then
        VERIFIED_CLIENT_BRAND="${_pair%%|*}"
        VERIFIED_CLIENT_UUID="${_pair##*|}"
        VERIFIED_CLIENT_SOURCE="built-in"
    fi
    unset _pair
fi

# Brands+UUIDs that have been public at some point (they were committed to this
# repo, so anybody could have copied them into a client). If one of these is
# configured the boot log says so loudly and it is not treated as verified: a
# mark anybody can forge is worse than none.
PUBLISHED_CLIENT_BRANDS="Eaglercraft 1.12|522b2ce5-c9b9-36cf-be7c-5d90f55e631a Eaglercraft[VER]|51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff EaglercraftX[V2]|355d0b9f-14ce-359f-8c9f-97cc1a7c92ca EaglercraftX[SV]|97735bfa-bcd1-378f-b691-4714a39acb69"

if [ -n "$VERIFIED_CLIENT_BRAND" ] && [ -n "$VERIFIED_CLIENT_UUID" ]; then
    VERIFIED_CLIENT_CONFIGURED=true
else
    VERIFIED_CLIENT_CONFIGURED=false
fi
VERIFIED_CLIENT_PUBLISHED=false
for _pair in $PUBLISHED_CLIENT_BRANDS; do
    if [ "$VERIFIED_CLIENT_BRAND" = "${_pair%%|*}" ] || [ "$VERIFIED_CLIENT_UUID" = "${_pair##*|}" ]; then
        VERIFIED_CLIENT_PUBLISHED=true
    fi
done
unset _pair

# true = ONLY the verified client may stay on the server; everybody else is
# kicked right after the login. DEFAULT IS FALSE: everybody may join with any
# client and the verified client is only *marked* in the logs (your IP is
# hidden, your lines carry no client=... tag). Turn it on if you ever want the
# server to be exclusive.
ENFORCE_VERIFIED_CLIENT=false
# also kick real (Java) Minecraft clients - only has an effect while
# ENFORCE_VERIFIED_CLIENT is true
ENFORCE_KICK_VANILLA=true
# do NOT kick when the check itself could not run (proxy busy/restarting).
# Keeps you from locking yourself out; those logins stay visible as
# "UNKNOWN CLIENT" in the logs.
ENFORCE_KICK_ON_UNKNOWN=false
# names that may join with any client even when enforcement is on
# (comma separated, e.g. ENFORCE_BYPASS_PLAYERS="Friend1,Friend2")
ENFORCE_BYPASS_PLAYERS=""
VERIFIED_CLIENT_KICK_MESSAGE="This server only allows the verified client."

# The verified client is *you*, so its IP is never written to the logs that
# get synced to the bucket (commands, logins and verifications show
# "ip=hidden" instead). A local copy is kept in private-logs/ (never synced)
# in case you ever need to look your own IP up.
HIDE_VERIFIED_IP=true
PRIVATE_IP_LOG=true

# =============================================
# REAL CLIENT IPs  (see "IPs" in README.md)
# =============================================
# Players connect through the Hugging Face ingress, so the socket comes from
# the proxy and the game would log the proxy's address for everybody. The
# proxy plugin can read the client's real IP from a forwarded header
# (listeners.yml: forward_ip + forward_ip_header) but it DISCONNECTS anyone
# whose connection lacks that header - so guessing is not an option.
#
#   FORWARD_IP=auto   probe the headers once, remember the answer in the
#                     bucket, use it from then on          (default)
#   FORWARD_IP=on     trust FORWARD_IP_HEADER (no probing)
#   FORWARD_IP=off    keep the proxy's IP (old behaviour)
#   FORWARD_IP=X-Real-IP   any other value = trust that header, no probing
FORWARD_IP="${FORWARD_IP:-auto}"
FORWARD_IP_HEADER="${FORWARD_IP_HEADER:-}"
FORWARD_IP_CANDIDATES="${FORWARD_IP_CANDIDATES:-X-Real-IP X-Forwarded-For CF-Connecting-IP True-Client-IP X-Envoy-External-Address X-Client-IP}"
PUBLIC_URL="${PUBLIC_URL:-https://smodusermc-12.hf.space/}"
FORWARD_IP_STATE="$PRIV_DIR/forward-ip.state"
FORWARD_IP_PROBE_PY="${FORWARD_IP_PROBE_PY:-/tmp/forward_ip_probe.py}"
#   The boot probe can only succeed once the Space really answers on its public
#   URL, which is usually not the case while it is still starting up - and a
#   failed probe used to be final until the next restart. It is therefore
#   retried in the background until a header works; a retry restarts the proxy,
#   so it only ever happens while nobody is online. 0 disables the retries.
FORWARD_IP_RETRY_INTERVAL="${FORWARD_IP_RETRY_INTERVAL:-600}"
#   Which of the two it is - the player's address or the proxy's - is not a
#   matter of opinion: everything from outside reaches the game port through the
#   ingress, so the PEERS of that port are the proxy's own addresses. Comparing
#   a logged address against them is what makes "the IPs are wrong" answerable:
#   a logged address that equals a peer is the proxy's, never a player's.
PROXY_PEERS_PY="${PROXY_PEERS_PY:-/tmp/proxy_peers.py}"
PROXY_PEERS_STATE="$PRIV_DIR/proxy-peers.log"
PROXY_PEERS_VIEW="$SEC_DIR/proxy-peers.txt"
GAME_PORT="${GAME_PORT:-7860}"

# =============================================
# AUTH LOG CAPTURE  (why /login needs a patch)
# =============================================
# Paper prints "Steve issued server command: /login hunter2" for every command
# a player types, and that line is the only place the security logger can read
# /login, /register and /changepassword from.  LoginSecurity 3.3.1 (and AuthMe)
# install a log filter that makes the logging framework DROP every line like
# that before the console, the log file or the parser ever see it - which is
# why no login was picked up at all.  tools/patch_auth_filter.py rewrites the
# string constants of that filter inside the plugin jar, so the filter cannot
# match any more; the plugin itself keeps working unchanged.  apply_auth_filter_patch
# does that before Paper starts, checks the patched class with the JVM's own
# parser (javap) and rolls back if anything looks wrong.
AUTH_FILTER_PATCH="${AUTH_FILTER_PATCH:-true}"   # false = leave the plugin jars alone
AUTH_FILTER_PATCH_PY="${AUTH_FILTER_PATCH_PY:-/tmp/patch_auth_filter.py}"
AUTH_PATCH_BACKUP_DIR="${AUTH_PATCH_BACKUP_DIR:-/tmp/authlog-jar-backups}"
AUTH_PATCH_JAR_GLOB="${AUTH_PATCH_JAR_GLOB:-*LoginSecurity*.jar *AuthMe*.jar *loginsecurity*.jar *authme*.jar}"
AUTH_PATCH_STATUS="not run"
AUTH_PATCHED_CLASSES=""      # "<jar>|<class>|<backup>" per patched filter class
AUTH_PATCH_EXPECT=""         # plugin names that must appear in "Enabling ..." lines
AUTH_PATCH_RESTART_DONE=false

# >>> embedded forward_ip_probe.py (generated from tools/forward_ip_probe.py) >>>
write_forward_ip_probe_py() {
    mkdir -p "$(dirname "$FORWARD_IP_PROBE_PY")" 2>/dev/null
    cat > "$FORWARD_IP_PROBE_PY" <<'FORWARD_IP_PROBE_EOF'
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
FORWARD_IP_PROBE_EOF
}
ensure_forward_ip_probe_py() {
    [ -s "$FORWARD_IP_PROBE_PY" ] || write_forward_ip_probe_py
}
# <<< embedded forward_ip_probe.py <<<

# >>> embedded proxy_peers.py (generated from tools/proxy_peers.py) >>>
write_proxy_peers_py() {
    mkdir -p "$(dirname "$PROXY_PEERS_PY")" 2>/dev/null
    cat > "$PROXY_PEERS_PY" <<'PROXY_PEERS_EOF'
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
PROXY_PEERS_EOF
}
ensure_proxy_peers_py() {
    [ -s "$PROXY_PEERS_PY" ] || write_proxy_peers_py
}
# <<< embedded proxy_peers.py <<<


# >>> embedded patch_auth_filter.py (generated from tools/patch_auth_filter.py) >>>
write_auth_filter_patch_py() {
    mkdir -p "$(dirname "$AUTH_FILTER_PATCH_PY")" 2>/dev/null
    cat > "$AUTH_FILTER_PATCH_PY" <<'AUTH_FILTER_PATCH_PY_EOF'
#!/usr/bin/env python3
"""Stop the auth plugins' log filters from hiding /login from the console.

Why this exists
---------------
The security logger in start.sh reads /login, /register and /changepassword
out of the *console log* (Paper prints "Steve issued server command: /login
hunter2" for every command a player types).  LoginSecurity 3.3.1 does not let
that line reach the console: its `LoggingFilter` is added to the log4j root
logger in `LoginSecurity.enable()` and returns DENY for every message that
looks like an auth command, so the line is dropped before Paper, the file log
and our parser ever see it.  AuthMe does the same thing through
`LogFilterHelper` (used by its ConsoleFilter and Log4JFilter).  That is why
"logins are not picked up" - no amount of pattern matching can find a line
that the logging framework never writes.

What this does
--------------
It rewrites *only the string constants* of those filter classes inside the
plugin jar, so the deny check can never match a real console line again:

    "/login"                   -> "[authlog-patched] /login"
    "issued server command: "  -> "[authlog-patched] issued server command: "

Nothing else changes: the class file keeps its bytecode, its structure and its
constant indices (only the bytes of those UTF-8 constants and their lengths are
rewritten), which `javap -c` on the original and the patched class proves line
by line.  The plugin keeps working exactly as before - it just cannot hide the
auth lines any more, which is what the server owner wants, because those lines
are the only place the passwords can be read from (private-logs/auth.log).

The password itself is still never written down for the verified client (see
the masking in start.sh), and the copies of the raw console logs that are
synced to the bucket have the passwords masked as well.

Usage
-----
    python3 tools/patch_auth_filter.py --check   <jar> [<jar> ...]
    python3 tools/patch_auth_filter.py --apply   <jar> [<jar> ...]
    python3 tools/patch_auth_filter.py --restore <jar> [<jar> ...]
    python3 tools/patch_auth_filter.py --selftest [--dir DIR]

    --apply keeps a copy of the untouched jar (--backup-dir, default: next to
    the jar as <jar>.authlog-orig) so --restore can put it back.
    --json prints one machine readable object per jar for start.sh.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import zipfile
from pathlib import Path

# The marker that is put in front of every deny string.  It makes the string
# impossible to match ("issued server command: [authlog-patched] /login" never
# appears in a log) and it is what --check and the tests grep for.
PATCH_PREFIX = "[authlog-patched] "

BACKUP_SUFFIX = ".authlog-orig"

# One entry per plugin we know.  `class` is the class inside the jar that does
# the hiding, `markers` are the exact string constants that make the filter
# match.  A jar is only touched when the class file really contains one of
# them, and every marker that is found must be patchable.
RULES = [
    {
        "plugin": "LoginSecurity",
        "class": "com/lenis0012/bukkit/loginsecurity/util/LoggingFilter.class",
        "markers": [
            "/login",
            "/register",
            "/changepassword",
            "/changepass",
            "issued server command: ",
        ],
        "why": (
            "LoginSecurity 3.3.x adds this filter to the log4j root logger and "
            "denies every console line that contains 'issued server command: ' "
            "followed by one of the auth commands"
        ),
    },
    {
        "plugin": "AuthMe",
        "class": "fr/xephi/authme/output/LogFilterHelper.class",
        "markers": ["issued server command:"],
        "why": (
            "AuthMe 5.x uses this helper from ConsoleFilter and Log4JFilter to "
            "hide every auth command from the console"
        ),
    },
]

# Used by --selftest: a tiny, valid class file that prints the given strings.
# It exists so the patch can be proven on a class the JVM really loads and runs
# (tests/test_verified_client.sh does exactly that), also on machines that have
# no auth plugin jar at hand.
FIXTURE_CLASS = "com/lenis0012/bukkit/loginsecurity/util/LoggingFilter"


# --------------------------------------------------------------------------- #
# class file handling
# --------------------------------------------------------------------------- #
class ClassFile:
    """Just enough of the class file format to rewrite UTF-8 constants."""

    MAGIC = 0xCAFEBABE

    def __init__(self, data: bytes):
        self.data = data
        if len(data) < 10 or struct.unpack_from(">I", data, 0)[0] != self.MAGIC:
            raise ValueError("not a class file")
        self.major, self.minor = struct.unpack_from(">HH", data, 6)
        self.count = struct.unpack_from(">H", data, 8)[0]
        self.utf8 = []  # (index, value, length_offset, bytes_offset)
        self._walk()

    def _walk(self) -> None:
        pos = 10
        i = 1
        while i < self.count:
            tag = self.data[pos]
            pos += 1
            if tag == 1:  # CONSTANT_Utf8
                (length,) = struct.unpack_from(">H", self.data, pos)
                start = pos + 2
                value = self.data[start:start + length]
                self.utf8.append((i, value, pos, start))
                pos = start + length
            elif tag in (7, 8, 16, 19, 20):  # Class, String, MethodType, Module, Package
                pos += 2
            elif tag in (15,):  # MethodHandle
                pos += 3
            elif tag in (3, 4, 9, 10, 11, 12, 17, 18):  # int, float, refs, NameAndType, dynamic
                pos += 4
            elif tag in (5, 6):  # long, double take two slots
                pos += 8
                i += 1
            else:
                raise ValueError(f"unknown constant pool tag {tag} at {pos - 1}")
            i += 1
        if pos > len(self.data):
            raise ValueError("class file constant pool runs past the end of the file")

    def strings(self) -> list[str]:
        return [value.decode("utf-8", "replace") for _, value, _, _ in self.utf8]

    @staticmethod
    def dangerous(strings: list[str]) -> list[str]:
        """Strings that could still make a password-hiding filter deny a line.

        A class *name* may contain "/login" by accident, so only exact matches
        of an auth command and strings containing the console prefix count.
        """
        words = {
            "/login", "/l", "/log", "/register", "/reg", "/unregister", "/unreg",
            "/changepassword", "/changepass", "/cp", "/authme",
        }
        return [s for s in strings
                if not s.startswith(PATCH_PREFIX)
                and ("issued server command" in s or s in words)]

    def patch(self, markers: list[str]) -> tuple[bytes, list[str], list[str]]:
        """Prefix every marker constant, keep everything else byte identical."""
        want = {m.encode(): PATCH_PREFIX.encode() + m.encode() for m in markers}
        done: list[str] = []
        out = bytearray()
        cursor = 0
        for _, value, length_offset, bytes_offset in self.utf8:
            new = want.get(value)
            if new is None or value.startswith(PATCH_PREFIX.encode()):
                continue
            # keep the bytes before this constant, then write the longer one
            out += self.data[cursor:length_offset]
            out += struct.pack(">H", len(new))
            out += new
            cursor = bytes_offset + len(value)
            done.append(value.decode("utf-8", "replace"))
        if not done:
            return self.data, [], []
        out += self.data[cursor:]
        patched = ClassFile(bytes(out))  # re-parse, so a broken rewrite fails here
        return bytes(out), done, self.dangerous(patched.strings())


# --------------------------------------------------------------------------- #
# jar handling
# --------------------------------------------------------------------------- #
def read_text_file(path: Path) -> dict:
    """Read a whole jar into memory (plugin jars are a few MB)."""
    with zipfile.ZipFile(path) as zf:
        return {
            "comment": zf.comment,
            "entries": [(info, zf.read(info.filename)) for info in zf.infolist()],
        }


def write_jar(path: Path, entries: list, comment: bytes) -> None:
    tmp = path.with_name(path.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
        if comment:
            zf.comment = comment
        for info, data in entries:
            zf.writestr(info, data)
    os.replace(tmp, path)


def patch_jar(path: Path, apply: bool, backup_dir: Path | None) -> dict:
    report = {
        "jar": str(path),
        "exists": path.is_file(),
        "plugin": None,
        "class": None,
        "status": "no-rule-class",
        "markers_found": [],
        "markers_patched": [],
        "residual": [],
        "backup": None,
        "error": None,
    }
    if not path.is_file():
        report["status"] = "missing"
        return report

    try:
        content = read_text_file(path)
        by_name = {info.filename: (info, data) for info, data in content["entries"]}

        changed_any = False
        errors = []
        for rule in RULES:
            entry = by_name.get(rule["class"])
            if entry is None:
                continue
            info, data = entry
            report["plugin"] = rule["plugin"]
            report["class"] = rule["class"]
            try:
                patched_bytes, done, residual = ClassFile(data).patch(rule["markers"])
            except ValueError as exc:
                report["status"] = "error"
                report["error"] = str(exc)
                return report

            strings = ClassFile(data).strings()
            found = done or [m for m in rule["markers"] if m in strings]
            report["markers_found"] = found
            if residual:
                # a deny string we cannot neutralise: refuse to touch the jar
                report["status"] = "unpatchable"
                report["residual"] = residual
                return report
            if not done:
                # nothing left to patch: either already patched or the strings
                # are not constants in this build of the plugin
                already = [s for s in strings
                           if s.startswith(PATCH_PREFIX)
                           and s[len(PATCH_PREFIX):] in rule["markers"]]
                report["status"] = "already-patched" if already else "markers-missing"
                report["markers_patched"] = already and rule["markers"] or []
                return report

            report["markers_patched"] = done
            if not apply:
                report["status"] = "would-patch"
                return report

            # write it back, keeping a copy of the original first
            backup = None
            if backup_dir is not None:
                backup_dir.mkdir(parents=True, exist_ok=True)
                backup = backup_dir / (path.name + BACKUP_SUFFIX)
                if not backup.is_file():
                    shutil.copy2(path, backup)
            elif not (path.with_name(path.name + BACKUP_SUFFIX)).is_file():
                backup = path.with_name(path.name + BACKUP_SUFFIX)
                shutil.copy2(path, backup)
            if backup is not None:
                report["backup"] = str(backup)

            entries = [(i, patched_bytes if i.filename == rule["class"] else d)
                       for i, d in content["entries"]]
            write_jar(path, entries, content["comment"])
            # read it back and prove the whole jar is intact and patched
            check = read_text_file(path)
            check_by_name = {info.filename: data for info, data in check["entries"]}
            if check_by_name.get(rule["class"]) != patched_bytes:
                errors.append(f"{rule['class']} did not survive the rewrite")
            for i, d in content["entries"]:
                if i.filename != rule["class"] and check_by_name.get(i.filename) != d:
                    errors.append(f"unrelated entry {i.filename} changed")
            report["status"] = "patched" if not errors else "error"
            report["error"] = "; ".join(errors) or None
            changed_any = True
            return report

        if report["status"] == "no-rule-class":
            report["status"] = "not-applicable"
        return report
    except (zipfile.BadZipFile, OSError) as exc:
        report["status"] = "error"
        report["error"] = f"{type(exc).__name__}: {exc}"
        return report


def restore_jar(path: Path, backup_dir: Path | None) -> dict:
    candidates = []
    if backup_dir is not None:
        candidates.append(backup_dir / (path.name + BACKUP_SUFFIX))
    candidates.append(path.with_name(path.name + BACKUP_SUFFIX))
    for backup in candidates:
        if backup.is_file():
            shutil.copy2(backup, path)
            return {"jar": str(path), "status": "restored", "backup": str(backup)}
    return {"jar": str(path), "status": "no-backup", "backup": None}


# --------------------------------------------------------------------------- #
# self test: build a class the JVM can load and run, then patch it
# --------------------------------------------------------------------------- #
class _Pool:
    """A tiny constant pool builder (dedupes entries by their key)."""

    def __init__(self):
        self.entries: list[tuple] = []
        self.index: dict = {}

    def _add(self, key, payload, slots=1):
        if key in self.index:
            return self.index[key]
        idx = len(self.entries) + 1
        self.entries.append((key, payload, slots))
        self.index[key] = idx
        if slots == 2:
            self.entries.append((None, b"", 0))
        return idx

    def utf8(self, s: str) -> int:
        b = s.encode("utf-8")
        return self._add(("utf8", s), struct.pack(">BH", 1, len(b)) + b)

    def string(self, s: str) -> int:
        # ldc needs a CONSTANT_String entry; pointing it at the Utf8 would be
        # "Illegal type at constant pool entry"
        return self._add(("string", s), struct.pack(">BH", 8, self.utf8(s)))

    def cls(self, name: str) -> int:
        return self._add(("class", name), struct.pack(">BH", 7, self.utf8(name)))

    def nat(self, name: str, desc: str) -> int:
        return self._add(("nat", name, desc),
                         struct.pack(">BHH", 12, self.utf8(name), self.utf8(desc)))

    def fieldref(self, cls: str, name: str, desc: str) -> int:
        return self._add(("field", cls, name, desc),
                         struct.pack(">BHH", 9, self.cls(cls), self.nat(name, desc)))

    def methodref(self, cls: str, name: str, desc: str) -> int:
        return self._add(("method", cls, name, desc),
                         struct.pack(">BHH", 10, self.cls(cls), self.nat(name, desc)))

    def dump(self) -> bytes:
        out = struct.pack(">H", len(self.entries) + 1)
        for _, payload, _slots in self.entries:
            out += payload
        return out


def build_fixture_class(name: str, strings: list[str]) -> bytes:
    """A valid Java 8 class whose main() prints `strings`, one per line.

    Straight line code only, so an empty StackMapTable is enough - the same
    shape javac emits for a method without branches.
    """
    pool = _Pool()
    # constant pool class entries use the internal form, "com/foo/Bar"
    this_cls = pool.cls(name.replace(".", "/"))
    super_cls = pool.cls("java/lang/Object")
    ptr = "Ljava/io/PrintStream;"
    sb = "java/lang/StringBuilder"
    main = pool.utf8("main")
    main_desc = pool.utf8("([Ljava/lang/String;)V")
    code_name = pool.utf8("Code")
    smt_name = pool.utf8("StackMapTable")
    sb_cls = pool.cls(sb)
    sb_init = pool.methodref(sb, "<init>", "()V")
    sb_append = pool.methodref(sb, "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;")
    sb_to_string = pool.methodref(sb, "toString", "()Ljava/lang/String;")
    sys_out = pool.fieldref("java/lang/System", "out", ptr)
    println = pool.methodref("java/io/PrintStream", "println", "(Ljava/lang/String;)V")

    code = bytearray()
    code += b"\xbb" + struct.pack(">H", sb_cls)      # new StringBuilder
    code += b"\x59"                                   # dup
    code += b"\xb7" + struct.pack(">H", sb_init)      # invokespecial <init>
    code += b"\x4c"                                   # astore_1
    for s in strings:
        code += b"\x2b"                               # aload_1
        idx = pool.string(s)
        if idx > 255:
            raise ValueError("fixture has too many strings for a 1 byte ldc index")
        code += b"\x12" + bytes([idx])                # ldc <string>
        code += b"\xb6" + struct.pack(">H", sb_append)
        code += b"\x57"                               # pop
    code += b"\xb2" + struct.pack(">H", sys_out)      # getstatic System.out
    code += b"\x2b"                                   # aload_1
    code += b"\xb6" + struct.pack(">H", sb_to_string)
    code += b"\xb6" + struct.pack(">H", println)
    code += b"\xb1"                                   # return

    # StackMapTable: no entries (no branch targets in this method)
    smt = struct.pack(">HI", smt_name, 2) + struct.pack(">H", 0)
    code_attr = (struct.pack(">HI", code_name, 12 + len(code) + len(smt))
                 + struct.pack(">HH", 2, 2) + struct.pack(">I", len(code))  # max_stack, max_locals
                 + bytes(code) + struct.pack(">H", 0)  # exception table
                 + struct.pack(">H", 1) + smt)         # attributes: StackMapTable
    method = (struct.pack(">HHH", 0x0009, main, main_desc)  # public static
              + struct.pack(">H", 1) + code_attr)

    out = bytearray()
    out += struct.pack(">IHH", 0xCAFEBABE, 0, 52)     # Java 8
    out += pool.dump()
    out += struct.pack(">HHH", 0x0021, this_cls, super_cls)   # public class, super
    out += struct.pack(">HHH", 0, 0, 1)                        # interfaces, fields, methods
    out += method
    out += struct.pack(">H", 0)                                # class attributes
    return bytes(out)


def selftest(directory: Path) -> dict:
    """Build fixture jars (one per rule), patch them and report the paths."""
    directory.mkdir(parents=True, exist_ok=True)
    result = {"dir": str(directory), "classes": [], "patch": []}
    for rule in RULES:
        name = rule["class"][:-len(".class")].replace("/", ".")
        cls = build_fixture_class(name, rule["markers"])
        rel = rule["class"][:-len(".class")]
        original = directory / f"{rule['plugin']}-original.jar"
        patched = directory / f"{rule['plugin']}-patched.jar"
        # a decoy class that uses the same words for its real job (the command
        # class of the plugin does exactly that): the patch must not touch it
        decoy_rel = "com/lenis0012/bukkit/loginsecurity/commands/CommandLogin"
        if rule["plugin"] != "LoginSecurity":
            decoy_rel = "fr/xephi/authme/commands/executors/LoginCommand"
        decoy = build_fixture_class(decoy_rel.replace("/", "."), ["/login", "/register"])
        for target in (original, patched):
            with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zf:
                zf.writestr(rel + ".class", cls)
                zf.writestr(decoy_rel + ".class", decoy)
                zf.writestr("plugin.yml", f"name: {rule['plugin']}\nversion: 0\n")
        report = patch_jar(patched, apply=True, backup_dir=directory / "backup")
        result["classes"].append({"plugin": rule["plugin"], "class": name,
                                  "decoy": decoy_rel.replace("/", "."),
                                  "original": str(original), "patched": str(patched)})
        result["patch"].append(report)
    return result


# --------------------------------------------------------------------------- #
def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="only report what would happen")
    mode.add_argument("--apply", action="store_true", help="patch the jars (keeps a backup)")
    mode.add_argument("--restore", action="store_true", help="put the original jar back")
    mode.add_argument("--selftest", action="store_true", help="build, patch and verify a fixture")
    parser.add_argument("--backup-dir", default=None, help="where the originals are kept")
    parser.add_argument("--json", action="store_true", help="one JSON object per line")
    parser.add_argument("--dir", default=None, help="--selftest work directory")
    parser.add_argument("jars", nargs="*")
    args = parser.parse_args(argv[1:])

    backup_dir = Path(args.backup_dir) if args.backup_dir else None

    if args.selftest:
        import tempfile
        directory = Path(args.dir) if args.dir else Path(tempfile.mkdtemp(prefix="authfilter-"))
        result = selftest(directory)
        if args.json:
            print(json.dumps(result))
        else:
            for report in result["patch"]:
                print(f"{report['plugin']}: {report['status']} "
                      f"({len(report['markers_patched'])} markers)")
            for item in result["classes"]:
                print(f"  original: {item['original']}")
                print(f"  patched : {item['patched']}")
                print(f"  run with: java -cp {item['patched']} {item['class']}")
        return 0

    if not args.jars:
        parser.error("at least one jar is required")

    reports = []
    for jar in args.jars:
        path = Path(jar)
        if args.apply:
            reports.append(patch_jar(path, apply=True, backup_dir=backup_dir))
        elif args.check:
            reports.append(patch_jar(path, apply=False, backup_dir=backup_dir))
        else:
            reports.append(restore_jar(path, backup_dir))

    ok = True
    for report in reports:
        if args.json:
            print(json.dumps(report))
        else:
            detail = report.get("class") or "-"
            note = f" [{report['error']}]" if report.get("error") else ""
            print(f"{report.get('plugin') or 'unknown plugin'}: {report['status']} ({detail}){note}")
            for marker in report.get("markers_patched") or report.get("markers_found") or []:
                print(f"    {marker}")
        if report["status"] in ("error", "unpatchable", "markers-missing"):
            ok = False
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
AUTH_FILTER_PATCH_PY_EOF
}
ensure_auth_filter_patch_py() {
    [ -s "$AUTH_FILTER_PATCH_PY" ] || write_auth_filter_patch_py
}
# <<< embedded patch_auth_filter.py <<<


# -------------------------------------------------------------
# The auth filter patch (LoginSecurity / AuthMe)
# -------------------------------------------------------------
# one jar -> one TSV line: status <TAB> plugin <TAB> class <TAB> markers <TAB> backup <TAB> error
auth_patch_one() {
    python3 "$AUTH_FILTER_PATCH_PY" --apply --json --backup-dir "$AUTH_PATCH_BACKUP_DIR" "$1" 2>/dev/null \
        | tail -1 \
        | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read().strip() or "{}")
except Exception:
    d = {}
print("\t".join([
    d.get("status") or "error",
    d.get("plugin") or "?",
    d.get("class") or "?",
    ",".join(d.get("markers_patched") or d.get("markers_found") or []),
    d.get("backup") or "",
    d.get("error") or "",
]))' 2>/dev/null
}

# javap is part of the JDK that runs the server and parses a class file the same
# way the JVM will, so it is the cheapest proof that a patched class is intact.
javap_dump() {   # $1 jar, $2 dotted class name
    local javap="$JAVA_HOME_DIR/bin/javap"
    [ -x "$javap" ] || return 1
    "$javap" -p -c -classpath "$1" "$2" 2>/dev/null
}

# The patched and the original class may differ in nothing but the deny strings:
# the instruction lines (constant comments removed) have to be identical, the
# diff must be replacements only, and every added line must name the patch.
javap_verify_patch() {   # $1 patched jar, $2 original jar, $3 dotted class
    local new old d added removed
    new=$(javap_dump "$1" "$3") || return 2
    old=$(javap_dump "$2" "$3") || return 2
    [ -n "$new" ] && [ -n "$old" ] || return 2
    d=$(diff <(printf '%s\n' "$old") <(printf '%s\n' "$new"))
    added=$(printf '%s\n' "$d" | grep -c '^>')
    removed=$(printf '%s\n' "$d" | grep -c '^<')
    [ "$added" -ge 1 ] || return 1
    [ "$added" = "$removed" ] || return 1
    if printf '%s\n' "$d" | grep '^>' | grep -qv 'authlog-patched'; then
        return 1
    fi
    # the code itself (everything left of the constant comments) must be equal
    [ "$(printf '%s\n' "$old" | sed 's#//.*##' | md5sum)" = \
      "$(printf '%s\n' "$new" | sed 's#//.*##' | md5sum)" ] || return 1
    return 0
}

# Patch every auth plugin jar before Paper starts, so that /login reaches the
# console again.  Prints what happened and leaves a one line summary in
# AUTH_PATCH_STATUS (written to logger-status.log, which is synced).
apply_auth_filter_patch() {
    ensure_auth_filter_patch_py
    local jar name status plugin class markers backup err dotted rc verify found=0 summary=""
    if [ "${AUTH_FILTER_PATCH:-true}" != true ]; then
        AUTH_PATCH_STATUS="disabled (AUTH_FILTER_PATCH=false) - /login stays hidden from the console"
        echo "   [AUTHPATCH] disabled by AUTH_FILTER_PATCH=false"
        return 0
    fi
    AUTH_PATCHED_CLASSES=""
    AUTH_PATCH_EXPECT=""
    for jar in $PLUGIN_DIR/$AUTH_PATCH_JAR_GLOB; do
        [ -f "$jar" ] || continue
        name=$(basename "$jar")
        case "$name" in *.authlog-orig|*.tmp) continue ;; esac
        found=1
        IFS=$'\t' read -r status plugin class markers backup err <<< "$(auth_patch_one "$jar")"
        status="${status:-error}"
        dotted="${class%.class}"; dotted="${dotted//\//.}"
        case "$status" in
            patched|already-patched)
                verify="not checked (no javap)"
                [ "$status" = "already-patched" ] && verify="already patched (nothing to do on this boot)"
                if [ "$status" = "patched" ] && [ -n "$backup" ] && [ -f "$backup" ]; then
                    javap_verify_patch "$jar" "$backup" "$dotted"; rc=$?
                    case "$rc" in
                        0) verify="javap: only the deny strings changed" ;;
                        1) verify="FAILED" ;;
                        *) verify="not checked (no javap)" ;;
                    esac
                    if [ "$rc" = 1 ]; then
                        cp -f "$backup" "$jar" 2>/dev/null && \
                            echo "   [AUTHPATCH] $name: the patched class failed the javap check - original restored"
                        summary="${summary}${summary:+; }$name: NOT patched (javap check failed, original jar kept) - /login stays hidden"
                        continue
                    fi
                fi
                AUTH_PATCHED_CLASSES="${AUTH_PATCHED_CLASSES}${jar}|${dotted}|${backup}"$'\n'
                AUTH_PATCH_EXPECT="$AUTH_PATCH_EXPECT $plugin"
                summary="${summary}${summary:+; }$plugin ${class##*/} ${status} (${markers//,/, }) - $verify"
                echo "   [AUTHPATCH] $plugin: $status, deny strings: $markers"
                echo "   [AUTHPATCH]   $verify"
                if [ "$status" = "patched" ]; then
                    echo "   [AUTHPATCH]   backup: $backup"
                    echo "   [AUTHPATCH]   /login, /register, /changepassword now reach the console (and the logs)"
                fi
                ;;
            not-applicable)
                echo "   [AUTHPATCH] $name: no password filter in this build - nothing to patch"
                summary="${summary}${summary:+; }$name: no password filter found (nothing to patch)"
                ;;
            markers-missing)
                echo "   [AUTHPATCH] $name: the filter class has no deny strings - unknown plugin build, not patched"
                summary="${summary}${summary:+; }$name: filter class without the known deny strings - not patched, check the plugin version"
                ;;
            missing)
                : ;;
            *)
                echo "   [AUTHPATCH] $name: $status ${err:+($err)}"
                summary="${summary}${summary:+; }$name: $status ${err:+($err)}"
                ;;
        esac
    done
    if [ "$found" != 1 ]; then
        echo "   [AUTHPATCH] no auth plugin jar in $PLUGIN_DIR (nothing to patch)"
        AUTH_PATCH_STATUS="no LoginSecurity/AuthMe jar found in $PLUGIN_DIR (nothing to patch)"
    else
        AUTH_PATCH_STATUS="${summary:-nothing to patch}"
    fi
    return 0
}

# If a patched plugin is installed but Paper did not enable it, the patch broke
# the class file: put the originals back and start Paper again, so the server is
# never left without the auth plugin (players could not log in at all).
auth_patch_post_start_check() {
    [ -n "$AUTH_PATCH_EXPECT" ] || return 0
    local plugin missing="" i
    for plugin in $AUTH_PATCH_EXPECT; do
        grep -qai "Enabling .*${plugin}" /tmp/paper.log 2>/dev/null || missing="$missing $plugin"
    done
    if [ -z "$missing" ]; then
        echo "[AUTHPATCH] patched plugin(s) loaded:${AUTH_PATCH_EXPECT}"
        return 0
    fi
    echo "[AUTHPATCH] !!${missing} did not load with the patched jar - restoring the originals"
    while IFS='|' read -r jar dotted backup; do
        [ -n "$jar" ] || continue
        if [ -f "$backup" ]; then
            cp -f "$backup" "$jar" && echo "[AUTHPATCH] restored $(basename "$jar")"
        fi
    done <<< "$AUTH_PATCHED_CLASSES"
    AUTH_PATCH_STATUS="ROLLED BACK:${missing} did not load with the patched jar, the originals are back - /login stays hidden from the console"
    if [ "$AUTH_PATCH_RESTART_DONE" != true ]; then
        AUTH_PATCH_RESTART_DONE=true
        echo "[AUTHPATCH] restarting Paper with the original plugin jar"
        kill "$BACKEND_PID" 2>/dev/null
        for i in $(seq 1 20); do
            kill -0 "$BACKEND_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$BACKEND_PID" 2>/dev/null
        > /tmp/paper.log
        start_paper
        wait_for_paper_ready
    fi
    return 1
}

# -------------------------------------------------------------
# The console tails that are synced to the bucket are copies of the raw logs, so
# they must not become a second place where the verified client's password or
# address shows up.  private-logs/auth.log stays the one place passwords can be
# read from (full for everybody except the verified client); in the bucket copy
# every auth command argument is masked and the verified client's address is
# written as "hidden".
# -------------------------------------------------------------
mask_console_tail() {
    awk -v cache="$VERDICT_CACHE" -v hide="${HIDE_VERIFIED_IP:-true}" '
        BEGIN {
            while ((getline l < cache) > 0) {
                n = index(l, "\t")
                if (n > 1) v[substr(l, 1, n - 1)] = substr(l, n + 1)
            }
        }
        {
            line = $0
            if (match(line, /issued server command: *\/[A-Za-z]+/)) {
                word = substr(line, RSTART, RLENGTH); sub(/.*\//, "", word)
                if (word == "login" || word == "l" || word == "log" ||
                    word == "register" || word == "reg" || word == "unregister" || word == "unreg" ||
                    word == "changepassword" || word == "changepass" || word == "cp" || word == "authme")
                    line = substr(line, 1, RSTART + RLENGTH - 1) " ********"
            }
            if (hide == "true") {
                for (name in v) {
                    if ((v[name] == "VERIFIED" || v[name] == "PENDING" || v[name] == "UNKNOWN" ||
                         v[name] == "CONSOLE_DOWN") && index(line, name "[/") > 0) {
                        esc = name; gsub(/\./, "\\.", esc)
                        gsub(esc "\\[/[^]]*\\]", name "[/hidden]", line)
                    }
                }
            }
            print line
        }'
}


# how the login logger is reported: logins.log row format + a status file so
# "it is not logging logins" can be answered from the bucket in one look
LOG_STATUS_INTERVAL="${LOG_STATUS_INTERVAL:-60}"
SCRIPT_VERSION="${SCRIPT_VERSION:-v2-gated-client}"

# The login line is written before the client check has finished. When the IP
# is hidden the tag is left off as well, so a login by the verified client is
# just "DATE | LOGIN | name | hidden" with nothing marking it.
if [ "$HIDE_VERIFIED_IP" = true ]; then
    LOGIN_CLIENT_FIELD=""
else
    LOGIN_CLIENT_FIELD=" | client=CHECK PENDING"
fi

# Open the Bungee console pipe now, before any background subshell exists, so
# every part of this script can push console commands into the proxy.
mkfifo "$BUNGEE_CONSOLE" 2>/dev/null
if exec 9<>"$BUNGEE_CONSOLE" 2>/dev/null; then
    BUNGEE_CONSOLE_OK=true
else
    BUNGEE_CONSOLE_OK=false
    echo "WARNING: could not open $BUNGEE_CONSOLE - verified-client checks are disabled"
fi
BUNGEE_PID_FILE="/tmp/bungee.pid"

CPU_CORES=$(nproc 2>/dev/null || echo 2)
NETTY_THREADS=2

TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
BUNGEE_MAX_MB=1024
PAPER_MAX_MB=$(( TOTAL_MEM_MB - BUNGEE_MAX_MB - 768 ))
[ "$PAPER_MAX_MB" -gt 8192 ] && PAPER_MAX_MB=8192
[ "$PAPER_MAX_MB" -lt 1024 ] && PAPER_MAX_MB=1024
# -Xms must be <= -Xmx or the JVM refuses to start ("Initial heap size set to a
# larger value than the maximum heap size"), and it must also fit in the Space's
# RAM: on a 16 GB Space the max is 8192 but on a smaller one it is not, so the
# initial heap is derived from the max instead of being a fixed 8192.
PAPER_MIN_MB=$(( PAPER_MAX_MB / 2 ))
[ "$PAPER_MIN_MB" -gt 4096 ] && PAPER_MIN_MB=4096
[ "$PAPER_MIN_MB" -lt 512 ] && PAPER_MIN_MB=512

echo "========================================"
echo "  Eaglercraft 1.12.2 Vanilla Survival"
echo "  Paper 1.12.2 + HuggingFace Buckets"
echo "========================================"
echo ""
echo " CPUs: $CPU_CORES | RAM: ${TOTAL_MEM_MB}MB"
echo " Server: ${PAPER_MIN_MB}-${PAPER_MAX_MB}MB | Bungee: ${BUNGEE_MAX_MB}MB"
echo " Java: $($JAVA -version 2>&1 | head -1)"
echo " Bucket: $HF_BUCKET_HANDLE"
[ -n "$OP_USERNAME" ] && echo " OP Account: $OP_USERNAME"
echo " Plugins synced: WorldEdit, WorldGuard, MineResetLite, Shopkeepers, SafeTrade, Skript, PvPManager"
echo " Security logs: $SEC_DIR"
echo " Private logs:  $PRIV_DIR"
echo " Both are synced to the bucket every ${LOG_SYNC_INTERVAL}s (full game-data sync: ${SYNC_INTERVAL}s):"
echo "   ${HF_BUCKET_HANDLE}/game-data/security-logs/logins.log        logins + verdicts"
echo "   ${HF_BUCKET_HANDLE}/game-data/security-logs/commands.log      every command"
echo "   ${HF_BUCKET_HANDLE}/game-data/security-logs/client-checks.log verified/other/vanilla per login"
echo "   ${HF_BUCKET_HANDLE}/game-data/security-logs/shared-ips.txt    shared-IP report"
if [ "$SYNC_PRIVATE_LOGS" = true ]; then
    echo "   ${HF_BUCKET_HANDLE}/game-data/private-logs/auth.log          full /login lines (passwords!)"
    echo "   ${HF_BUCKET_HANDLE}/game-data/private-logs/player-ips.log     real IPs of \"hidden\" lines"
    echo "   ${HF_BUCKET_HANDLE}/game-data/private-logs/logins-real-ips.log, shared-ips-private.txt"
else
    echo "   (SYNC_PRIVATE_LOGS=false: auth.log / player-ips.log stay inside the Space)"
fi
[ "$SYNC_CONSOLE_LOGS" = true ] && \
    echo "   ${HF_BUCKET_HANDLE}/game-data/logs/{paper,bungee}.log        last ${CONSOLE_LOG_LINES} console lines (passwords masked)"
echo " Login capture: the LoginSecurity/AuthMe password filters are neutralised at"
echo "                startup, so /login reaches the console (see logger-status.log)"
if [ "$HIDE_VERIFIED_IP" = true ]; then
    echo " The verified client is hidden in the security-logs: its IP is written as"
    echo " \"hidden\" and it gets no client=... tag / VERIFY line"
fi
echo " Verified client: $VERIFIED_CLIENT_BRAND ($VERIFIED_CLIENT_UUID)"
if [ "$ENFORCE_VERIFIED_CLIENT" = true ]; then
    echo " Enforce verified client: ON - only the verified client may join"
    echo "   -> kick vanilla clients too: $ENFORCE_KICK_VANILLA | kick unresolved checks: $ENFORCE_KICK_ON_UNKNOWN"
    [ -n "$ENFORCE_BYPASS_PLAYERS" ] && echo "   -> bypass: $ENFORCE_BYPASS_PLAYERS"
else
    echo " Enforce verified client: off - everyone can join, only logged"
fi
echo ""

# =============================================
# JVM FLAGS
# =============================================
PAPER_JVM_FLAGS=(
    -Xmx${PAPER_MAX_MB}M
    -Xms${PAPER_MIN_MB}M
    -XX:+UseG1GC
    -XX:+ParallelRefProcEnabled
    -XX:MaxGCPauseMillis=25
    -XX:+UnlockExperimentalVMOptions
    -XX:+DisableExplicitGC
    -XX:G1NewSizePercent=40
    -XX:G1MaxNewSizePercent=50
    -XX:G1HeapRegionSize=8M
    -XX:G1ReservePercent=15
    -XX:G1HeapWastePercent=10
    -XX:G1MixedGCCountTarget=8
    -XX:InitiatingHeapOccupancyPercent=60
    -XX:G1MixedGCLiveThresholdPercent=90
    -XX:G1RSetUpdatingPauseTimePercent=5
    -XX:SurvivorRatio=32
    -XX:+PerfDisableSharedMem
    -XX:MaxTenuringThreshold=1
    -XX:+OptimizeStringConcat
    -XX:+UseCompressedOops
    -XX:MaxMetaspaceSize=256M
    -XX:CompressedClassSpaceSize=128M
    -XX:ReservedCodeCacheSize=128M
    -XX:-UseCodeCacheFlushing
    -Xss256k
    -Djline.terminal=jline.UnsupportedTerminal
    -Dio.netty.allocator.maxCachedBufferCapacity=524288
    -Dio.netty.recycler.maxCapacityPerThread=0
    -Dio.netty.eventLoopThreads=${NETTY_THREADS}
    -Dio.netty.allocator.numDirectArenas=${NETTY_THREADS}
    -Dio.netty.allocator.numHeapArenas=${NETTY_THREADS}
    -Dcom.mojang.eula.agree=true
    -DIReallyKnowWhatIAmDoingISwear
    -Dusing.aikars.flags=https://mcflags.emc.gs
    -Daikars.new.flags=true
    # Java 17 Compatibility overrides for 1.12.2
    --add-opens=java.base/java.lang=ALL-UNNAMED
    --add-opens=java.base/java.lang.reflect=ALL-UNNAMED
    --add-opens=java.base/java.math=ALL-UNNAMED
    --add-opens=java.base/java.net=ALL-UNNAMED
    --add-opens=java.base/java.nio=ALL-UNNAMED
    --add-opens=java.base/java.security=ALL-UNNAMED
    --add-opens=java.base/java.text=ALL-UNNAMED
    --add-opens=java.base/java.util=ALL-UNNAMED
    --add-opens=java.base/java.util.concurrent=ALL-UNNAMED
    --add-opens=java.base/jdk.internal.math=ALL-UNNAMED
    --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED
    --add-opens=java.base/sun.net.www.protocol.http=ALL-UNNAMED
    --add-opens=java.base/sun.net.www.protocol.https=ALL-UNNAMED
    --add-opens=java.base/sun.security.action=ALL-UNNAMED
    --add-opens=java.base/sun.security.util=ALL-UNNAMED
    --add-opens=java.base/sun.security.x509=ALL-UNNAMED
)

BUNGEE_JVM_FLAGS=(
    -Xmx${BUNGEE_MAX_MB}M
    -Xms128M
    -XX:+UseG1GC
    -XX:+ParallelRefProcEnabled
    -XX:MaxGCPauseMillis=30
    -XX:+UnlockExperimentalVMOptions
    -XX:+DisableExplicitGC
    -XX:+PerfDisableSharedMem
    -XX:+OptimizeStringConcat
    -XX:+UseCompressedOops
    -XX:MaxMetaspaceSize=128M
    -XX:ReservedCodeCacheSize=64M
    -Xss256k
    -Dio.netty.allocator.maxCachedBufferCapacity=524288
    -Dio.netty.recycler.maxCapacityPerThread=0
    -Dio.netty.eventLoopThreads=${NETTY_THREADS}
    -Dio.netty.allocator.numDirectArenas=${NETTY_THREADS}
    -Dio.netty.allocator.numHeapArenas=${NETTY_THREADS}
    -Deaglerxbungee.stfu=true
    # Additional Bungee reflection backups
    --add-opens=java.base/java.lang=ALL-UNNAMED
    --add-opens=java.base/java.lang.reflect=ALL-UNNAMED
)

# =============================================================
# RCON — each command sent individually to avoid mangling
# =============================================================
RCON_PASS="chunkystart"

get_player_count() {
    local RESULT
    RESULT=$(mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASS" "list" 2>/dev/null)
    echo "$RESULT" | grep -oE 'are [0-9]+' | grep -oE '[0-9]+' || echo "0"
}

mc_command() {
    for cmd in "$@"; do
        mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASS" "$cmd" 2>/dev/null
    done
}

# =============================================================
# Paper starter
# =============================================================
start_paper() {
    cd "$BACKEND_DIR"
    $JAVA "${PAPER_JVM_FLAGS[@]}" -jar server.jar nogui --noconsole >> /tmp/paper.log 2>&1 &
    BACKEND_PID=$!
}

# Wait until Paper reports "Done".  Returns 1 when the JVM died; a timeout is
# not fatal (the rest of the boot continues, exactly as before).
wait_for_paper_ready() {
    local i
    for i in $(seq 1 120); do
        if grep -q "Done" /tmp/paper.log 2>/dev/null; then
            echo " Paper READY (~${i}s)"
            return 0
        fi
        if ! kill -0 $BACKEND_PID 2>/dev/null; then
            echo " PAPER CRASHED!"
            tail -30 /tmp/paper.log
            return 1
        fi
        [ $((i % 15)) -eq 0 ] && echo " Loading... (${i}s)"
        sleep 1
    done
    echo " Paper did not report Done within 120s - carrying on"
    return 0
}

# =============================================================
# OP Account Setup
# =============================================================
setup_op_account() {
    if [ -z "$OP_USERNAME" ]; then
        return
    fi

    echo " Setting up OP for: $OP_USERNAME"

    local OFFLINE_UUID
    OFFLINE_UUID=$(echo -n "OfflinePlayer:${OP_USERNAME}" | md5sum | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    local V3_UUID
    V3_UUID=$(echo "$OFFLINE_UUID" | sed 's/.\{1\}\(.\\{3\}-\)/3\1/' | sed 's/\(.\{14\}-\).\(.\{3\}-\)/\1'"$(echo "$OFFLINE_UUID" | cut -c15 | tr '0-9a-f' '89ab89ab89ab89ab')"'\2/')

    cat > "$BACKEND_DIR/ops.json" << OPEOF
[
  {
    "uuid": "${V3_UUID}",
    "name": "${OP_USERNAME}",
    "level": 4,
    "bypassesPlayerLimit": true
  }
]
OPEOF
    echo "   ops.json written (level 4, UUID: ${V3_UUID})"

    mc_command "op ${OP_USERNAME}"
    echo "   RCON op command sent"
}

# =============================================================
# IDLE MODE — safe version that does NOT kill entities
# =============================================================
enter_idle_mode() {
    [ "$IDLE_MODE" = true ] && return
    IDLE_MODE=true
    mc_command "gamerule randomTickSpeed 0"
    mc_command "gamerule doMobSpawning false"
    # Kill regular hostile mobs to free up CPU, without affecting gameplay since players are gone
    mc_command "kill @e[type=Zombie]"
    mc_command "kill @e[type=Skeleton]"
    mc_command "kill @e[type=Spider]"
    mc_command "kill @e[type=Creeper]"
    mc_command "kill @e[type=Enderman]"
    mc_command "kill @e[type=Witch]"
    mc_command "kill @e[type=Slime]"
    mc_command "kill @e[type=CaveSpider]"
    mc_command "kill @e[type=Silverfish]"
    mc_command "kill @e[type=Guardian]"
    mc_command "kill @e[type=Endermite]"
    mc_command "kill @e[type=Blaze]"
    mc_command "kill @e[type=Ghast]"
    mc_command "kill @e[type=MagmaCube]"
    mc_command "kill @e[type=WitherSkeleton]"
    mc_command "kill @e[type=ZombiePigman]"
    echo "[IDLE] Active — hostile mobs cleared, ticks paused"
}

exit_idle_mode() {
    [ "$IDLE_MODE" = false ] && return
    IDLE_MODE=false
    mc_command "gamerule randomTickSpeed 3"
    mc_command "gamerule doMobSpawning true"
    echo "[IDLE] Gameplay restored"
}

# =============================================================
# Port fix
# =============================================================
find_listeners_yml() {
    find "$BUNGEE_DIR/plugins" -name "listeners.yml" -type f 2>/dev/null | head -1
}

patch_eagler_port() {
    local FILE=$(find_listeners_yml)
    [ -z "$FILE" ] && return 1
    grep -q ":7860" "$FILE" && return 0
    sed -i 's/\(address:[[:space:]]*"[^:]*:\)[0-9]*/\17860/' "$FILE"
    sed -i "s/\(address:[[:space:]]*[^\"][^:]*:\)[0-9]*/\17860/" "$FILE"
    echo "  Port -> 7860"
}

# =============================================================
# REAL CLIENT IPs (forward_ip in listeners.yml)
# =============================================================
# With forward_ip: true the plugin reads the player's address from a header
# and closes the connection when that header is missing - so the header has to
# be verified before it is trusted, and a wrong guess must never be left in
# place. The probe is a real WebSocket upgrade through the public URL (the same
# path players take), done once; the answer is kept in the bucket.
set_forward_ip_in_listeners() {
    local FILE=$(find_listeners_yml)
    [ -n "$FILE" ] || return 1
    local enabled="$1" header="${2:-X-Real-IP}"
    if grep -q '^[[:space:]]*forward_ip:' "$FILE"; then
        sed -i "s/^\([[:space:]]*forward_ip:\)[[:space:]].*/\1 $enabled/" "$FILE"
    else
        sed -i "0,/^\([[:space:]]*forward_ip_header:\)/s//\1 $header\n  forward_ip: $enabled/" "$FILE"
    fi
    if grep -q '^[[:space:]]*forward_ip_header:' "$FILE"; then
        sed -i "s/^\([[:space:]]*forward_ip_header:\)[[:space:]].*/\1 $header/" "$FILE"
    else
        sed -i "0,/^\([[:space:]]*forward_ip:\)/s//\1\n  forward_ip_header: $header/" "$FILE"
    fi
    return 0
}

forward_ip_setting() {   # "true|false <header>" as currently configured
    local FILE=$(find_listeners_yml)
    [ -n "$FILE" ] || return 0
    local on header
    on=$(sed -n 's/^[[:space:]]*forward_ip:[[:space:]]*\([a-z]*\).*/\1/p' "$FILE" | head -1)
    header=$(sed -n 's/^[[:space:]]*forward_ip_header:[[:space:]]*"\?\([^"[:space:]]*\)"\?.*/\1/p' "$FILE" | head -1)
    echo "${on:-false} ${header:-X-Real-IP}"
}

forward_ip_start_line() {   # remember where the log was before the probe
    FORWARD_IP_LOG_LINE=$(wc -l < /tmp/bungee.log 2>/dev/null || echo 0)
}

forward_ip_was_refused() {  # the plugin's own words when the header is missing
    tail -n "+$(( ${FORWARD_IP_LOG_LINE:-0} + 1 ))" /tmp/bungee.log 2>/dev/null \
        | grep -q "header, disconnecting"
}

# -------------------------------------------------------------
# Is the address in the log the player's, or the proxy's?
# -------------------------------------------------------------
proxy_peer_addrs() {   # the proxy's own addresses (kernel tables, no ss needed)
    ensure_proxy_peers_py
    python3 "$PROXY_PEERS_PY" --port "$GAME_PORT" 2>/dev/null
}

# Remember every peer we have seen: the proxy is not a single machine, and a
# peer may be gone by the time a report is written. The list is written into
# private-logs/ (which is restored from the bucket, so it survives a restart)
# and a readable copy goes into the synced security-logs/.
proxy_peers_record() {
    local addr new=0
    [ -n "$PRIV_DIR" ] || return 0
    mkdir -p "$PRIV_DIR" "$SEC_DIR" 2>/dev/null
    touch "$PROXY_PEERS_STATE" 2>/dev/null
    while IFS= read -r addr; do
        [ -n "$addr" ] || continue
        grep -qF "$(printf '\t')$addr" "$PROXY_PEERS_STATE" 2>/dev/null && continue
        printf '%s\t%s\n' "$(date '+%F %T')" "$addr" >> "$PROXY_PEERS_STATE" 2>/dev/null
        new=$((new + 1))
    done <<< "$(proxy_peer_addrs)"
    [ "${new:-0}" -gt 0 ] 2>/dev/null && echo "   proxy peers: $new new address(es) recorded"
    {
        echo "The addresses the proxy in front of the server connects from."
        echo "An address in the logs that equals one of these is the PROXY's, not a player's."
        echo "updated: $(date '+%F %T')"
        echo ""
        awk -F'\t' 'NF>1 {print "  " $2 "   (first seen " $1 ")"}' "$PROXY_PEERS_STATE" 2>/dev/null | sort -u
    } > "$PROXY_PEERS_VIEW" 2>/dev/null
    return 0
}

proxy_peer_list() {   # the known proxy addresses, one per line
    awk -F'\t' 'NF>1 {print $2}' "$PROXY_PEERS_STATE" 2>/dev/null | sort -u
}

is_proxy_addr() {
    [ -n "${1:-}" ] || return 1
    proxy_peer_list 2>/dev/null | grep -qxF "$1"
}

# 0 = the addresses in the IP map are the proxy's (so the logs hold nothing the
# player's own address could be read from)
logged_ip_is_proxy() {
    local addr seen
    seen=$(awk -F'\t' '{print $2}' "$IP_MAP" 2>/dev/null | sort -u)
    [ -n "$seen" ] || return 1
    while IFS= read -r addr; do
        is_real_ip "$addr" || continue
        is_proxy_addr "$addr" && return 0
    done <<< "$seen"
    return 1
}

# What a log line's address really is, in one sentence, for logger-status.log
ip_evidence_line() {
    if ! proxy_peer_list 2>/dev/null | grep -q .; then
        echo "no proxy peer recorded yet - the players' addresses cannot be told from the proxy's"
    elif logged_ip_is_proxy; then
        echo "THE ADDRESSES IN THE LOGS ARE THE PROXY'S (they equal the peers of port $GAME_PORT) - the players' real IPs are not available, see the IPs section in README.md"
    else
        echo "the addresses in the logs are not proxy peers - they are the players' own"
    fi
}

# A header can only be discovered while the public URL answers - i.e. not during
# the boot (that is why the boot probe may fail even though a header exists).
# Retry it in the background, but only with nobody online: applying a header
# restarts the proxy.
forward_ip_retry_needed() {
    [ "$FORWARD_IP" = "auto" ] || return 1
    case "${FORWARD_IP_RETRY_INTERVAL:-0}" in ""|*[!0-9]*) return 1 ;; esac
    [ "$FORWARD_IP_RETRY_INTERVAL" -gt 0 ] || return 1
    case "$(read_forward_ip_state)" in
        ""|probe|off) : ;;
        *) return 1 ;;                      # a header already worked
    esac
    [ -s "${ONLINE_STATE:-/dev/null}" ] && return 1      # never kick players for a retry
    logged_ip_is_proxy || return 1                       # nothing to fix
    return 0
}

# A probe that already answered "no header works" is only re-asked rarely: the
# answer is unlikely to change, and every attempt restarts the proxy.
forward_ip_retry_due() {   # $1 = tick number, 0 = ask now
    case "$(read_forward_ip_state)" in
        ""|probe) return 0 ;;
        off)      [ $(( ${1:-0} % 6 )) -eq 0 ] ;;   # ~ every 6th interval
        *)        return 1 ;;
    esac
}

forward_ip_retry_loop() {
    local tick=0
    while true; do
        sleep "${FORWARD_IP_RETRY_INTERVAL:-600}" 2>/dev/null || sleep 600
        tick=$((tick + 1))
        forward_ip_retry_due "$tick" || continue
        if forward_ip_retry_needed; then
            echo "[FORWARD-IP] the logged addresses are the proxy's - retrying the header discovery (nobody online)"
            discover_forward_ip_header || true
            proxy_peers_record
        fi
    done
}

forward_ip_probe_once() {   # 0 = the proxy passed the header through
    ensure_forward_ip_probe_py
    python3 "$FORWARD_IP_PROBE_PY" --url "$PUBLIC_URL" --timeout "${FORWARD_IP_TIMEOUT:-10}" \
        2>/dev/null | sed 's/^/   /'
    return "${PIPESTATUS[0]}"
}

read_forward_ip_state() {
    [ -s "$FORWARD_IP_STATE" ] || return 0
    head -1 "$FORWARD_IP_STATE" 2>/dev/null | tr -d '\r'
}

write_forward_ip_state() {
    mkdir -p "$(dirname "$FORWARD_IP_STATE")" 2>/dev/null
    printf '%s\n' "$1" > "$FORWARD_IP_STATE" 2>/dev/null
    echo "   saved: $FORWARD_IP_STATE ($1) -> kept in the bucket"
}

# decide what to write into listeners.yml before Bungee starts
apply_forward_ip_choice() {
    local saved
    if [ "$FORWARD_IP" = "off" ]; then
        set_forward_ip_in_listeners false "${FORWARD_IP_HEADER:-X-Real-IP}"
        echo "   real IPs: disabled (FORWARD_IP=off) - logs show the proxy address"
        return 0
    fi
    case "$FORWARD_IP" in
        auto|on|off) ;;
        *)   # a header name was given directly
            set_forward_ip_in_listeners true "$FORWARD_IP"
            echo "   real IPs: trusting '$FORWARD_IP' (set by FORWARD_IP)"
            return 0 ;;
    esac
    if [ -n "$FORWARD_IP_HEADER" ] || [ "$FORWARD_IP" = "on" ]; then
        local h="${FORWARD_IP_HEADER:-X-Real-IP}"
        set_forward_ip_in_listeners true "$h"
        echo "   real IPs: trusting '$h' (FORWARD_IP=$FORWARD_IP)"
        return 0
    fi
    saved=$(read_forward_ip_state)
    case "$saved" in
        ""|probe)
            set_forward_ip_in_listeners false "X-Real-IP"
            echo "   real IPs: not configured yet - will probe after startup"
            FORWARD_IP_DECISION=probe ;;
        off)
            set_forward_ip_in_listeners false "X-Real-IP"
            echo "   real IPs: no header worked last time - staying on the proxy address" ;;
        *)
            set_forward_ip_in_listeners true "$saved"
            echo "   real IPs: using '$saved' (discovered earlier)" ;;
    esac
}

bungee_restart() {
    local i
    echo "   restarting BungeeCord to apply the change..."
    kill "$BUNGEE_PID" 2>/dev/null
    wait "$BUNGEE_PID" 2>/dev/null
    for i in $(seq 1 20); do
        nc -z 127.0.0.1 7860 2>/dev/null || break
        sleep 1
    done
    > /tmp/bungee.log
    start_bungee
    for i in $(seq 1 45); do
        nc -z 127.0.0.1 7860 2>/dev/null && { echo "   BungeeCord is back (~$((i*2))s)"; return 0; }
        kill -0 "$BUNGEE_PID" 2>/dev/null || { echo "   BungeeCord did not come back!"; return 1; }
        sleep 2
    done
    echo "   BungeeCord did not open the port in time"
    return 1
}

# find out which header the proxy actually sends, then save it
discover_forward_ip_header() {
    local cand reached=no rc
    echo ""
    echo "[FORWARD-IP] finding out which header carries the real client address"
    for cand in $FORWARD_IP_CANDIDATES; do
        echo "   trying $cand ..."
        set_forward_ip_in_listeners true "$cand"
        bungee_restart || { set_forward_ip_in_listeners false "$cand"; continue; }
        forward_ip_start_line
        forward_ip_probe_once; rc=$?
        if [ "$rc" -ne 2 ]; then
            reached=yes        # the connection made it to the server
        fi
        if forward_ip_was_refused; then
            reached=yes        # the plugin answered, and it said no
            echo "   $cand was not sent by the proxy (the plugin refused the probe)"
        elif [ "$rc" -eq 0 ]; then
            echo "   $cand works - real client IPs are now used"
            write_forward_ip_state "$cand"
            FORWARD_IP_DECISION=done
            return 0
        else
            echo "   $cand: no usable answer (probe exit $rc)"
        fi
    done
    set_forward_ip_in_listeners false "X-Real-IP"
    bungee_restart || true
    if [ "$reached" = yes ]; then
        write_forward_ip_state off
        echo "   no forwarded header worked; logs will show the proxy address"
        echo "   set FORWARD_IP_HEADER=<name> in the Space variables to force one"
    else
        rm -f "$FORWARD_IP_STATE"
        echo "   could not reach $PUBLIC_URL from inside the Space - no header trusted"
        echo "   (this will be tried again on the next restart; a header name can be"
        echo "    forced with FORWARD_IP_HEADER=<name> or FORWARD_IP=<name>)"
        FORWARD_IP_DECISION=probe
    fi
    return 1
}

start_bungee() {
    cd "$BUNGEE_DIR"
    # BungeeCord reads console commands from stdin. Giving it the write+read end
    # of the pipe we opened at startup means its stdin never hits EOF, and this
    # script can inject commands (used by the verified-client check).
    if [ "$BUNGEE_CONSOLE_OK" = true ]; then
        $JAVA "${BUNGEE_JVM_FLAGS[@]}" \
            -cp "sqlite-jdbc.jar:BungeeCord.jar" \
            net.md_5.bungee.Bootstrap <&9 >> /tmp/bungee.log 2>&1 &
    else
        $JAVA "${BUNGEE_JVM_FLAGS[@]}" \
            -cp "sqlite-jdbc.jar:BungeeCord.jar" \
            net.md_5.bungee.Bootstrap < /dev/null >> /tmp/bungee.log 2>&1 &
    fi
    BUNGEE_PID=$!
    echo "$BUNGEE_PID" > "$BUNGEE_PID_FILE"
}

# =============================================================
# SECURITY LOGGER — logins/IPs + commands (append-only)
# =============================================================
# logins.log   : DATE | LOGIN  | name | ip | client=CHECK PENDING
#                DATE | VERIFY | name | ip | <label> | brand=... | version=... | uuid=...
#                DATE | LOGOUT | name | ip | client=...
# commands.log : DATE | name | ip | command | client=...
# shared-ips.txt : report of shared IPs / multi-IP accounts
#
# When HIDE_VERIFIED_IP=true the IP of the verified client is written as
# "hidden" everywhere in these files and its "client=..." tag and VERIFY line
# are left out, so a verified login is just "DATE | LOGIN | name | hidden".
# Everybody else keeps the full ip / client=... information.
#
# VERIFIED CLIENT
# client-checks.log : DATE | VERDICT | name | ip | brand=... | version=... | uuid=...
#   VERIFIED   = the client from this repo (unique Eagler brand UUID)
#   UNVERIFIED = some other Eaglercraft client / fork
#   VANILLA    = a real Minecraft client (not Eaglercraft)
#   UNKNOWN    = could not be checked
#
# private-logs/auth.log : DATE | name | ip | full /login command | client=...
#                         (verified client: "/login ********" with ip=hidden,
#                          password never written; everybody else: full command)
#   every password-reset relevant command from everybody EXCEPT the verified
#   client, so you can read "what password did they set" without ever writing
#   your own password down. Never synced to the bucket.
# =============================================================

# last known (real) IP of a player - from the runtime map, so it also works
# when the IP is hidden in the logs themselves
# A real address, as opposed to a placeholder. Everything that reads the IP
# map goes through this, so a value like "unknown" can never be mistaken for
# a player's address (that is how several accounts ended up "sharing" one).
is_real_ip() {
    case "${1:-}" in
        ""|unknown|hidden|none|null|-|0.0.0.0|127.0.0.1|"") return 1 ;;
    esac
    [[ "${1}" =~ ^[0-9a-fA-F:.]{3,45}$ ]] || return 1
    return 0
}

# record one sighting: every source is kept, with where it came from
record_ip() {
    local name="$1" ip="$2" source="${3:-?}"
    [ -n "$name" ] || return 0
    printf '%s\t%s\t%s\t%s\n' "$name" "${ip:-unknown}" "$source" "$(date +%s)" >> "$IP_MAP"
    if [ "$PRIVATE_IP_LOG" = true ]; then
        printf '%s | %s | %s | source=%s\n' "$(date '+%F %T')" "$name" "${ip:-unknown}" "$source" >> "$IP_MAP_FILE"
    fi
}

# The most recent *real* address of a player. Sources are treated equally but
# the newest wins, and a placeholder never overwrites a real address.
last_ip_for() {
    awk -F'\t' -v n="$1" '
        $1==n && $2!="" && $2!="unknown" && $2!="hidden" { v=$2; t=$4+0 }
        END { if (v != "") print v }' "$IP_MAP" 2>/dev/null
}

# every distinct address a player has been seen from, newest first
ips_for() {
    awk -F'\t' -v n="$1" '
        $1==n && $2!="" && $2!="unknown" && $2!="hidden" { if (!seen[$2]++) print $2" ("$3")" }' \
        "$IP_MAP" 2>/dev/null
}

# the IP that goes into a log line: real, or "hidden" for the verified client
ip_field() {
    local name="$1" ip="${2:-unknown}" verdict="${3:-UNKNOWN}"
    if hide_ip_for "$verdict"; then
        echo "hidden"
    else
        echo "$ip"
    fi
}

# which verdicts get their IP hidden: the verified client, and any verdict
# that is not final yet (a check that never resolves must never expose it)
hide_ip_for() {
    [ "$HIDE_VERIFIED_IP" = true ] || return 1
    case "${1:-UNKNOWN}" in
        VERIFIED|PENDING|UNKNOWN|CONSOLE_DOWN) return 0 ;;
        *) return 1 ;;
    esac
}

# " | client=LABEL" for a log line. While the owner's identity is hidden only
# the clients that are definitely not the verified one are tagged (and those
# are the lines that also carry a real IP), so nothing in the synced logs
# points back at the verified client.
client_field() {
    local v="${1:-UNKNOWN}"
    if [ "$HIDE_VERIFIED_IP" = true ]; then
        case "$v" in
            UNVERIFIED|VANILLA) ;;
            *) return 0 ;;
        esac
    fi
    printf ' | client=%s' "$(verdict_label "$v")"
}

# -------------------------------------------------------------
# Verified client verdict cache
# -------------------------------------------------------------
# The client check runs in the background right after the login (the proxy
# handshake needs a moment), so commands a player typed in the first seconds
# are logged as PENDING and everything after that carries the final verdict.
set_verdict() {
    printf '%s\t%s\n' "$1" "${2:-UNKNOWN}" >> "$VERDICT_CACHE"
}

verdict_for() {
    local v
    v=$(awk -F'\t' -v n="$1" '$1==n{v=$2} END{print v}' "$VERDICT_CACHE" 2>/dev/null)
    echo "${v:-UNKNOWN}"
}

# Human readable form used next to logins/commands so the raw logs say it
# plainly. VERIFIED CLIENT is the only label containing that phrase, so
# "grep 'VERIFIED CLIENT' logins.log" always means "this was my client".
verdict_label() {
    case "${1:-UNKNOWN}" in
        VERIFIED)   echo "VERIFIED CLIENT" ;;
        UNVERIFIED) echo "OTHER EAGLERCRAFT CLIENT" ;;
        VANILLA)    echo "JAVA CLIENT" ;;
        PENDING)    echo "CHECK PENDING" ;;
        *)          echo "UNKNOWN CLIENT" ;;
    esac
}

# -------------------------------------------------------------
# Password / register / login commands
# -------------------------------------------------------------
# auth-style commands are masked in commands.log (which can be read by other
# people and is synced) but kept in full in private-logs/auth.log, so a lost
# password can be looked up. The verified client's own commands are the one
# exception: your password is never written anywhere.
is_auth_cmd() {
    case "${1,,}" in
        "/login "*|"/l "*|"/log "*|"/register "*|"/reg "*|"/changepassword "*|"/changepass "*|"/unregister "*) return 0 ;;
        "/authme"*) return 0 ;;
        *) return 1 ;;
    esac
}

# The same command reaches us twice (Paper logs it and the Bungee console logs
# it), so every auth command is recorded once, with a short time window.
auth_seen_recently() {
    awk -F'\t' -v n="$1" -v c="$2" -v e="$(date +%s)" \
        '$2==n && $3==c && (e-$1)<15 {f=1} END{exit !f}' "$AUTH_SEEN" 2>/dev/null
}

record_auth_seen() {
    printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$AUTH_SEEN"
}

# queue an auth command until the player's client verdict is known
queue_auth() {
    local name="$1" cmd="$2"
    auth_seen_recently "$name" "$cmd" && return 0
    record_auth_seen "$name" "$cmd"
    printf '%s\t%s\t%s\n' "$(date +%s)" "$name" "$cmd" >> "$PENDING_AUTH"
}

# write queued auth commands whose verdict is known (or that are old enough)
flush_pending_auth() {
    [ -s "$PENDING_AUTH" ] || return 0
    local tmp="${PENDING_AUTH}.tmp" epoch name cmd v now ip
    : > "$tmp"
    while IFS=$'\t' read -r epoch name cmd; do
        v=$(verdict_for "$name")
        ip=$(last_ip_for "$name"); ip="${ip:-unknown}"
        if [ "${VERIFIED_CLIENT_CONFIGURED:-false}" != true ]; then
            write_auth_masked "$name" "$cmd" "UNCONFIGURED" "$v" "$epoch"
        elif [ "$v" = "VERIFIED" ]; then
            # the owner: never write the password, but do record that the
            # command happened, so auth.log shows the capture path working
            write_auth_masked "$name" "$cmd" "VERIFIED CLIENT" "$v" "$epoch"
        elif [ "$v" != "PENDING" ]; then
            echo "$(date -d "@$epoch" '+%F %T') | $name | $ip | $cmd | client=$(verdict_label "$v")" >> "$AUTH_LOG"
        elif [ $(( $(date +%s) - epoch )) -gt 300 ]; then
            echo "$(date -d "@$epoch" '+%F %T') | $name | $ip | $cmd | client=UNKNOWN CLIENT (check never resolved)" >> "$AUTH_LOG"
        else
            printf '%s\t%s\t%s\n' "$epoch" "$name" "$cmd" >> "$tmp"
        fi
    done < "$PENDING_AUTH"
    mv "$tmp" "$PENDING_AUTH"
}

# one masked auth row. Used for the owner's own commands (whose password is
# never written anywhere) and while the verified client is not configured (when
# nobody's password can be attributed safely).
write_auth_masked() {
    local name="$1" cmd="$2" label="${3:-UNCONFIGURED}" verdict="${4:-UNKNOWN}" epoch="${5:-}" ip="${6:-}"
    if [ -z "$ip" ]; then
        if [ "$label" = "VERIFIED CLIENT" ]; then
            ip="hidden"           # the owner's own address stays out of every log
        else
            ip=$(last_ip_for "$name"); ip="${ip:-unknown}"
        fi
    fi
    [ -n "$epoch" ] || epoch=$(date +%s)
    echo "$(date -d "@$epoch" '+%F %T') | $name | $ip | ${cmd%% *} ******** | client=$label (password not recorded)" >> "$AUTH_LOG"
}

# mask passwords in the log lines that leave the Space; the full command is
# kept in private-logs/auth.log instead (except for the verified client, whose
# password is not written anywhere - its row there is masked as well)
mask_cmd() {
    local name="$1" cmd="$2" verdict="${3:-UNKNOWN}" ip
    if is_auth_cmd "$cmd"; then
        if [ "${VERIFIED_CLIENT_CONFIGURED:-false}" != true ]; then
            # no way to tell the owner's /login from anybody else's - do not
            # write anybody's password in clear until the pair is configured
            write_auth_masked "$name" "$cmd" "UNCONFIGURED" "${verdict:-UNKNOWN}"
        else
            case "${verdict:-UNKNOWN}" in
                VERIFIED)
                    # the owner: the password is never written anywhere, but the
                    # command is still recorded (masked, IP hidden) so auth.log
                    # shows that a /login happened and keeps proving the capture
                    # path works end to end
                    if ! auth_seen_recently "$name" "$cmd"; then
                        record_auth_seen "$name" "$cmd"
                        write_auth_masked "$name" "$cmd" "VERIFIED CLIENT" VERIFIED
                    fi
                    ;;
                *)
                    case "$verdict" in
                        # verdict still unknown - keep it and log it once the
                        # player's client has been identified
                        PENDING|UNKNOWN|CONSOLE_DOWN) queue_auth "$name" "$cmd" ;;
                        *)
                            if ! auth_seen_recently "$name" "$cmd"; then
                                record_auth_seen "$name" "$cmd"
                                ip=$(last_ip_for "$name"); ip="${ip:-unknown}"
                                echo "$(date '+%F %T') | $name | $ip | $cmd | client=$(verdict_label "$verdict")" >> "$AUTH_LOG"
                            fi ;;
                    esac ;;
            esac
        fi
        cmd="${cmd%% *} ********"
    fi
    echo "$cmd"
}

# -------------------------------------------------------------
# One login = one LOGIN row
# -------------------------------------------------------------
# The same join is reported by the proxy (`<-> ServerConnector [..] has
# connected`), by the game server (`logged in with entity id`) and by the
# polled RCON player list. Whichever of them arrives first writes the row; the
# others see the name marked online and stay quiet. This also means a login is
# still logged if a log line never appears, which is what makes the log
# trustworthy on a server whose console format we cannot control.
is_online() {
    local f="${ONLINE_STATE:-/tmp/online-players.txt}"
    [ -s "$f" ] || return 1
    grep -qxF "$1" "$f" 2>/dev/null
}

mark_online() {
    local f="${ONLINE_STATE:-/tmp/online-players.txt}"
    is_online "$1" || printf '%s\n' "$1" >> "$f"
}

mark_offline() {
    local f="${ONLINE_STATE:-/tmp/online-players.txt}" tmp
    [ -f "$f" ] || return 0
    tmp="${f}.tmp"
    grep -vxF "$1" "$f" > "$tmp" 2>/dev/null
    mv "$tmp" "$f"
}

# $1 name, $2 ip, $3 where it was seen (paper|bungee|rcon list)
record_login() {
    local name="$1" ip="${2:-unknown}" src="${3:-?}"
    is_real_ip "$ip" && record_ip "$name" "$ip" "$src"
    if is_online "$name"; then
        return 0                     # this join is already in logins.log
    fi
    mark_online "$name"
    echo "$(date '+%F %T') | LOGIN | $name | $(ip_field "$name" "$ip" PENDING)${LOGIN_CLIENT_FIELD:-}" >> "$LOGIN_LOG"
    set_verdict "$name" PENDING
    echo "[LOG] LOGIN  $name (seen by $src)"
    check_player_client "$name" "$ip" &
}

record_logout() {
    local name="$1" src="${2:-?}" v ip
    is_online "$name" || return 0
    mark_offline "$name"
    v=$(verdict_for "$name")
    ip=$(last_ip_for "$name")
    echo "$(date '+%F %T') | LOGOUT | $name | $(ip_field "$name" "${ip:-unknown}" "$v")$(client_field "$v")" >> "$LOGIN_LOG"
    echo "[LOG] LOGOUT $name (seen by $src)"
}

# -------------------------------------------------------------
# Safety net: ask the server itself who is online (RCON `list`)
# -------------------------------------------------------------
playerlist_names() {   # pull the names out of a `list` answer
    # `There are 2 of a max 20 players online: Steve, Alex` - with or without
    # colour codes, and with whatever wording the server uses as long as the
    # names follow the last colon
    strip_colours 2>/dev/null | awk '
        {
            line = $0
            if (line ~ /players online/) {
                sub(/.*players online:?[[:space:]]*/, "", line)
            } else if (line ~ /:[[:space:]]*[A-Za-z0-9_.-]/) {
                sub(/^[^:]*:[[:space:]]*/, "", line)
            } else next
            n = split(line, names, /,[[:space:]]*/)
            for (i = 1; i <= n; i++)
                # no {1,16} interval: the awk Debian ships (mawk) lacks them
                if (names[i] ~ /^[A-Za-z0-9_.-]+$/ && length(names[i]) <= 16)
                    print names[i]
        }'
}

playerlist_check() {
    local raw names name ip
    PLAYERLIST_LAST="$(date '+%T')"
    raw=$(mc_command "list" 2>/dev/null)
    if [ -n "$raw" ]; then
        PLAYERLIST_LAST="$PLAYERLIST_LAST got: $(printf '%s' "$raw" | tr -d '\n' | cut -c1-120)"
    else
        PLAYERLIST_LAST="$PLAYERLIST_LAST no answer from RCON"
    fi
    # RCON unreachable or an answer we do not understand: never guess, or a
    # hiccup would log everybody out at once
    [ -n "$raw" ] || return 0
    case "$raw" in *"players online"*|*"There are"*) ;; *) return 0 ;; esac
    names=$(printf '%s\n' "$raw" | playerlist_names)
    [ "${PLAYERLIST_DEBUG:-false}" = true ] && \
        echo "[LOG] playerlist: $(printf '%s' "$names" | tr '\n' ' ')"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if ! is_online "$name"; then
            ip=$(last_ip_for "$name"); ip="${ip:-unknown}"
            echo "[LOG] $name is online without a LOGIN row - logging it now"
            record_login "$name" "$ip" "rcon list"
        fi
    done <<< "$names"
    if [ -s "${ONLINE_STATE:-/tmp/online-players.txt}" ]; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            grep -qxF "$name" <<< "$names" || record_logout "$name" "rcon list"
        done < "${ONLINE_STATE:-/tmp/online-players.txt}"
    fi
}

playerlist_loop() {
    while true; do
        sleep "${PLAYERLIST_POLL:-20}"
        playerlist_check || true
    done
}

# Paper's console format has changed over the years
#   [12:00:00 INFO]: Steve[/1.2.3.4:5555] logged in with entity id 42 at (...)
#   [12:00:00] [Server thread/INFO]: Steve[/1.2.3.4:5555] logged in with entity id 42
# so the patterns match the payload only and never the prefix. Anything the
# patterns miss is still caught by the RCON player list (see playerlist_check).
handle_paper_line() {
    local line="${1%$'\r'}" name ip cmd v NOW
    local LOGIN_RE='([A-Za-z0-9_.-]{1,16})\[/([^]]+):[0-9]+\] logged in with entity id'
    local CMD_RE='([A-Za-z0-9_.-]{1,16}) issued server command: (.*)$'
    local LEAVE_RE='([A-Za-z0-9_.-]{1,16}) (left the game|lost connection)'
    NOW=$(date '+%F %T')

    if [[ "$line" =~ $LOGIN_RE ]]; then
        name="${BASH_REMATCH[1]}"; ip="${BASH_REMATCH[2]}"
        record_login "$name" "$ip" paper
    elif [[ "$line" =~ $CMD_RE ]]; then
        name="${BASH_REMATCH[1]}"
        v=$(verdict_for "$name")
        cmd=$(mask_cmd "$name" "${BASH_REMATCH[2]}" "$v")
        ip=$(last_ip_for "$name")
        echo "$NOW | $name | $(ip_field "$name" "${ip:-unknown}" "$v") | $cmd$(client_field "$v")" >> "$CMD_LOG"
    elif [[ "$line" =~ $LEAVE_RE ]]; then
        record_logout "${BASH_REMATCH[1]}" paper
    fi
}

# BungeeCord is the other source of logins (and the only one that sees the IP
# before the player is even through):
#   [12:00:00 INFO] Steve[/1.2.3.4:5555] <-> InitialHandler has connected
#   [12:00:00 INFO] [UserConnection] Steve[/1.2.3.4:5555] <-> ServerConnector [lobby] has connected
#   [12:00:00 INFO] Steve executed command: /server lobby
# NOTE: "executed command" is logged by BungeeCord only for commands the proxy
# itself handles (log_commands in config.yml prints it after the command was
# found in the proxy's own command map).  /login, /register and /changepassword
# belong to the auth plugin on the backend server, so they are forwarded and
# never appear here - the auth lines come from Paper's console instead, which is
# why the plugins' password filters have to be patched (see AUTH LOG CAPTURE).
handle_bungee_line() {
    local line="${1%$'\r'}" name ip cmd v NOW
    local JOIN_RE='([A-Za-z0-9_.-]{1,16})\[/([^]]+):[0-9]+\] <-> ServerConnector \[?[^]]*\]? has connected'
    local SEEN_RE='([A-Za-z0-9_.-]{1,16})\[/([^]]+):[0-9]+\] <-> InitialHandler has connected'
    local QUIT_RE='([A-Za-z0-9_.-]{1,16})\[/([^]]+):[0-9]+\] <-> UpstreamBridge has disconnected'
    local BC_RE='([A-Za-z0-9_.-]+)\]? executed command: (.*)$'
    NOW=$(date '+%F %T')

    if [[ "$line" =~ $JOIN_RE ]]; then
        name="${BASH_REMATCH[1]}"; ip="${BASH_REMATCH[2]}"
        record_login "$name" "$ip" bungee
    elif [[ "$line" =~ $SEEN_RE ]]; then
        # not a login yet (the handshake can still fail) - remember the IP so
        # whoever reports the actual join can log it
        record_ip "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" bungee-handshake
    elif [[ "$line" =~ $QUIT_RE ]]; then
        record_logout "${BASH_REMATCH[1]}" bungee
    elif [[ "$line" =~ $BC_RE ]]; then
        name="${BASH_REMATCH[1]}"
        # don't log commands that this script itself injects into the console
        [[ "$name" == "CONSOLE" || "$name" == "Console" || "$name" == "client-brand" ]] && return
        v=$(verdict_for "$name")
        cmd=$(mask_cmd "$name" "${BASH_REMATCH[2]}" "$v")
        ip=$(last_ip_for "$name")
        echo "$NOW | $name | $(ip_field "$name" "${ip:-unknown}" "$v") | [bungee] $cmd$(client_field "$v")" >> "$CMD_LOG"
    fi
}

start_security_logger() {
    mkdir -p "$SEC_DIR" "$PRIV_DIR"
    touch "$LOGIN_LOG" "$CMD_LOG" "$CLIENT_LOG" "$AUTH_LOG"

    # Make sure no old watchers are left over (prevents duplicate log lines)
    pkill -f "tail -n0 -F /tmp/" 2>/dev/null
    [ -n "$SECLOG_PID" ] && kill "$SECLOG_PID" 2>/dev/null

    # no grep pre-filter: a line the filter would have dropped is a login that
    # never gets logged, and the handlers already ignore everything else
    (
        tail -n0 -F /tmp/paper.log 2>/dev/null \
            | while IFS= read -r l; do handle_paper_line "$l"; done &

        tail -n0 -F /tmp/bungee.log 2>/dev/null \
            | while IFS= read -r l; do handle_bungee_line "$l"; done &

        wait
    ) &
    SECLOG_PID=$!
}

# =============================================================
# VERIFIED CLIENT CHECK
# =============================================================
# Runs "/client-brand name <player>" on the Bungee console (through the pipe
# opened by start_bungee) and reads the answer back out of /tmp/bungee.log.
# EaglerXBungee prints:
#   Eagler Client Brand:   <brand>       <- "Eaglercraft[VER]" for our client
#   Eagler Client Version: <version>
#   Eagler Client UUID:    <brand UUID>  <- the unique marker
#   Minecraft Client Brand: <vanilla brand>
# =============================================================
strip_colours() {
    sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\xc2\xa7[0-9a-fk-or]//g' -e 's/\xa7[0-9a-fk-or]//g'
}

# write one command into the BungeeCord console pipe (safe from any subshell)
bungee_console() {
    [ "$BUNGEE_CONSOLE_OK" = true ] || return 1
    [ -p "$BUNGEE_CONSOLE" ] || return 1
    timeout 3 bash -c 'printf "%s\n" "$1" > "$2"' bash "$*" "$BUNGEE_CONSOLE" 2>/dev/null || return 1
}

bungee_alive() {
    local pid
    pid=$(cat "$BUNGEE_PID_FILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

query_client_brand() {
    local player="$1" start_line out brand version uuid mcbrand i
    if ! bungee_alive; then
        echo "CONSOLE_DOWN||||"
        return 1
    fi

    start_line=$(wc -l < /tmp/bungee.log 2>/dev/null || echo 0)
    bungee_console "client-brand name $player" || { echo "CONSOLE_DOWN||||"; return 1; }

    for i in $(seq 1 25); do
        sleep 0.2
        out=$(tail -n "+$((start_line + 1))" /tmp/bungee.log 2>/dev/null | tr -d '\r' | strip_colours)
        grep -q "Eagler Client UUID:" <<<"$out" && break
        grep -qE "not using eaglercraft|That player was not found|Unknown command" <<<"$out" && break
    done

    if grep -qi "not using eaglercraft" <<<"$out"; then
        echo "VANILLA||||"
        return 0
    fi

    brand=$(sed -n 's/.*Eagler Client Brand: //p' <<<"$out" | tail -1)
    version=$(sed -n 's/.*Eagler Client Version: //p' <<<"$out" | tail -1)
    uuid=$(sed -n 's/.*Eagler Client UUID: //p' <<<"$out" | tail -1)
    mcbrand=$(sed -n 's/.*Minecraft Client Brand: //p' <<<"$out" | tail -1)

    if [ -z "$uuid" ] && [ -z "$brand" ]; then
        echo "UNKNOWN||||"
        return 0
    fi

    if [ "${VERIFIED_CLIENT_CONFIGURED:-false}" = true ] && \
       [ "${VERIFIED_CLIENT_PUBLISHED:-false}" != true ] && \
       { [ "$uuid" = "$VERIFIED_CLIENT_UUID" ] || [ "$brand" = "$VERIFIED_CLIENT_BRAND" ]; }; then
        echo "VERIFIED|$brand|$version|$uuid|$mcbrand"
    else
        echo "UNVERIFIED|$brand|$version|$uuid|$mcbrand"
    fi
}

# Why the configured pair (if any) cannot be trusted - empty when it is fine.
verified_client_problem() {
    if [ "$VERIFIED_CLIENT_CONFIGURED" != true ]; then
        echo "NOT CONFIGURED: set VERIFIED_CLIENT_BRAND and VERIFIED_CLIENT_UUID"
        echo "  (Space -> Settings -> Variables and secrets, then Restart). Until"
        echo "  then nobody is marked as the verified client and, because your own"
        echo "  /login cannot be told apart from anybody else's, every password is"
        echo "  masked instead of written in clear."
    elif [ "$VERIFIED_CLIENT_PUBLISHED" = true ]; then
        echo "PUBLIC BRAND: '$VERIFIED_CLIENT_BRAND' was committed to this repo at some"
        echo "  point, so anybody can build a client that reports it. It is NOT"
        echo "  treated as verified. Rotate: bash tools/setup-verified-client.sh --rotate"
    fi
}

# A rotation updates the built-in pair. If the Space still holds the *old* pair
# as a secret, that one wins and the fresh client would not be recognised, so
# it is worth saying out loud.
warn_verified_client_mismatch() {
    local builtin
    [ "$VERIFIED_CLIENT_SOURCE" = environment ] || return 0
    builtin=$(verified_client_decode_pair 2>/dev/null)
    [ -n "$builtin" ] || return 0
    [ "${builtin%%|*}" = "$VERIFIED_CLIENT_BRAND" ] && return 0
    echo ""
    echo "!! VERIFIED CLIENT: the pair in the environment (${VERIFIED_CLIENT_BRAND})"
    echo "!!   is not the one this build was made for (hidden, see logger-status.log)."
    echo "!!   If you just rotated the client, delete the old secrets"
    echo "!!   (VERIFIED_CLIENT_BRAND / VERIFIED_CLIENT_UUID) and restart."
    echo ""
}

warn_verified_client_problem() {
    local problem
    problem=$(verified_client_problem)
    [ -n "$problem" ] || return 0
    echo ""
    echo "!! VERIFIED CLIENT: $problem" | sed 's/^/!! /'
    echo ""
}

check_player_client() {
    local name="$1" ip="$2" res verdict brand version uuid mcbrand now
    sleep 1   # give the Eagler handshake a moment to finish
    res=$(query_client_brand "$name")
    IFS='|' read -r verdict brand version uuid mcbrand <<< "$res"
    if [ "${verdict:-UNKNOWN}" = "UNKNOWN" ] || [ "$verdict" = "CONSOLE_DOWN" ]; then
        sleep 2
        res=$(query_client_brand "$name")
        IFS='|' read -r verdict brand version uuid mcbrand <<< "$res"
    fi

    now=$(date '+%F %T')
    verdict="${verdict:-UNKNOWN}"
    set_verdict "$name" "$verdict"
    flush_pending_auth
    local shown_ip=$(ip_field "$name" "$ip" "$verdict")
    echo "$now | ${verdict} | $name | $shown_ip | brand=${brand:-?} | version=${version:-?} | uuid=${uuid:-?}" >> "$CLIENT_LOG"
    # Everybody except the verified client also gets a plainly readable VERIFY
    # line in logins.log, so logins.log alone answers "was this me?" with
    # "grep 'VERIFIED CLIENT' logins.log". For the verified client the line is
    # omitted (see client_field) - a login by it is just LOGIN + LOGOUT.
    if [ "$verdict" != "VERIFIED" ] || [ "$HIDE_VERIFIED_IP" != true ]; then
        echo "$now | VERIFY | $name | $shown_ip | $(verdict_label "$verdict") | brand=${brand:-?} | version=${version:-?} | uuid=${uuid:-?}" >> "$LOGIN_LOG"
    fi
    echo "[CLIENT] $(date '+%H:%M:%S') $name ($shown_ip): ${verdict} / $(verdict_label "$verdict") brand=${brand:-?} version=${version:-?}"

    enforce_client_policy "$name" "$verdict"
}

# =============================================================
# Enforcement — only the verified client may stay
# =============================================================
# ENFORCE_VERIFIED_CLIENT=true kicks everybody who is not on the verified
# client. Nothing is kicked while the check has not resolved
# (ENFORCE_KICK_ON_UNKNOWN=false), so a proxy hiccup can never lock you out.
is_bypassed() {
    local n l
    for n in ${ENFORCE_BYPASS_PLAYERS//,/ }; do
        [ -z "$n" ] && continue
        for l in "$@"; do
            [ "${n,,}" = "${l,,}" ] && return 0
        done
    done
    return 1
}

enforce_client_policy() {
    local name="$1" verdict="${2:-UNKNOWN}"
    [ "$ENFORCE_VERIFIED_CLIENT" = true ] || return 0
    is_bypassed "$name" && return 0

    case "$verdict" in
        VERIFIED)
            return 0 ;;
        UNVERIFIED)
            mc_command "kick $name $VERIFIED_CLIENT_KICK_MESSAGE"
            echo "[CLIENT] kicked $name (other Eaglercraft client - only the verified client may join)" ;;
        VANILLA)
            if [ "$ENFORCE_KICK_VANILLA" = true ]; then
                mc_command "kick $name $VERIFIED_CLIENT_KICK_MESSAGE"
                echo "[CLIENT] kicked $name (Java client - only the verified client may join)"
            else
                echo "[CLIENT] letting $name stay (Java client, ENFORCE_KICK_VANILLA=false)"
            fi ;;
        *)
            if [ "$ENFORCE_KICK_ON_UNKNOWN" = true ]; then
                mc_command "kick $name $VERIFIED_CLIENT_KICK_MESSAGE"
                echo "[CLIENT] kicked $name (client could not be verified)"
            else
                echo "[CLIENT] letting $name stay (${verdict} - not kicked, ENFORCE_KICK_ON_UNKNOWN=false)"
            fi ;;
    esac
}

# =============================================================
# Shared IP / verified client report
# =============================================================
# $1 = logins.log-style file to analyse, $2 = file to write
shared_report_body() {
    awk -F' [|] ' '
        $2=="LOGIN" {
            ip=$4; n=$3
            if (!((ip SUBSEP n) in s1)) { s1[ip,n]=1; ipn[ip]=ipn[ip] " " n; ipc[ip]++ }
            if (!((n SUBSEP ip) in s2)) { s2[n,ip]=1; nip[n]=nip[n] " " ip; nc[n]++ }
        }
        END {
            print "=== IPs used by MULTIPLE accounts ==="
            for (i in ipc) if (ipc[i]>1) print i " ->" ipn[i]
            print ""
            print "=== Accounts logged in from MULTIPLE IPs ==="
            for (n in nc) if (nc[n]>1) print n " ->" nip[n]
        }' "$1" > "$2"

    {
        echo ""
        echo "=== Verified client checks (client-checks.log) ==="
        if [ -s "$CLIENT_LOG" ]; then
            awk -F' \\| ' '
                { c[$2]++; last[$2]=$0 }
                END {
                    for (k in c) print k ": " c[k] " login(s)    (last seen " last[k] ")"
                }' "$CLIENT_LOG" | sort
            echo ""
            echo "=== Logins NOT using the verified client ==="
            grep -E "UNVERIFIED|VANILLA" "$CLIENT_LOG" 2>/dev/null | tail -20
        else
            echo "no client checks recorded yet"
        fi
    } >> "$2"
}

# Per-account IP report: every address a player was seen from, where it came
# from and how often. This is the file to look at when two accounts show the
# same IP (or one account turns up with several) - a proxy address appears here
# for every account, a real client address does not.  With $3=yes the owner's
# own addresses are left out, for the copy that gets synced.
ip_report_body() {
    local map="$1" out="$2" skip_verified="${3:-no}" skip=""
    if [ "$skip_verified" = yes ]; then
        skip=$(awk -F'\t' '{print $1}' "$map" 2>/dev/null | sort -u | while IFS= read -r n; do
                   [ -n "$n" ] || continue
                   [ "$(verdict_for "$n")" = "VERIFIED" ] && printf '%s,' "$n"
               done)
    fi
    awk -F'\t' -v skip="$skip" -v peersfile="${PROXY_PEERS_STATE:-}" '
        BEGIN {
            m = split(skip, a, ","); for (i = 1; i <= m; i++) if (a[i] != "") hidden[a[i]] = 1
            if (peersfile != "") {
                while ((getline l < peersfile) > 0) {
                    p = index(l, "\t")
                    if (p > 1) {
                        addr = substr(l, p + 1)
                        if (addr != "") { peer[addr] = 1; npeer++ }
                    }
                }
            }
        }
        $1 != "" && $2 != "" && $2 != "unknown" && $2 != "hidden" && !($1 in hidden) {
            pair = $1 SUBSEP $2
            if (!(pair in seen)) {
                seen[pair] = 1
                sources[pair] = $3
                ips[$1] = ips[$1] (ips[$1] ? ", " : "") $2 " (" $3 ")"
            }
            hits[pair]++
            rows++
            who[$2] = who[$2] " " $1
            users[$2]++
            if (!($2 in peer)) fam[$1] = fam[$1] (index($2, ":") ? "6" : "4")
        }
        END {
            print "=== Accounts and the IPs they were seen from ==="
            for (pair in hits) {
                split(pair, parts, SUBSEP)
                print "  " parts[1] " -> " parts[2] " (" sources[pair] ") x" hits[pair]
            }
            if (rows == 0) print "  (no IPs recorded yet)"
            print ""
            print "=== One IP, several accounts ==="
            for (ip in users) if (users[ip] > 1) print "  " ip " ->" who[ip]
            print ""
            print "=== Which address is a real client address ==="
            if (npeer == 0) print "  (no proxy peer recorded yet - see security-logs/proxy-peers.txt)"
            for (ip in users) {
                if (ip in peer) print "  " ip " -> the PROXY address (not a player), " users[ip] " account(s)"
                else            print "  " ip " -> a real client address (not a proxy peer), " users[ip] " account(s)"
            }
            proxied = 0; own = 0
            for (ip in users) { if (ip in peer) proxied++; else own++ }
            if (rows > 0) {
                if (own == 0)          print "  verdict: every address here is the PROXY address - the real client IPs are not in these logs"
                else if (proxied == 0) print "  verdict: the addresses here are the real client addresses (a forwarded header is in use)"
                else                   print "  verdict: both kinds are present - a row with the PROXY address had no forwarded header"
            }
            print ""
            print "=== One device, two protocols (IPv4 + IPv6) ==="
            duals = 0
            for (n in fam) {
                if (fam[n] ~ /4/ && fam[n] ~ /6/) {
                    print "  " duals + 1 " account(s) -> seen over IPv4 and IPv6 - that is one device, not two"
                    duals++
                }
            }
            if (duals == 0) print "  (none)"
        }' "$map" 2>/dev/null | sort > "$out"
}

# What "the IP in the log" really is: the player's own address when a forwarded
# header is in use, the address of the proxy in front of the server otherwise.
# This is the honest answer to "the IPs are wrong" - if no header works, every
# address the server can possibly log is the proxy's one.
real_client_ip_line() {
    local s
    s=$(forward_ip_setting 2>/dev/null || true)
    case "$s" in
        true*) echo "on (${s#true }) - the logged IPs are the players' real addresses" ;;
        "")    echo "unknown - listeners.yml could not be read" ;;
        *)     echo "OFF - the logged IPs are the ADDRESS OF THE PROXY, not the player's (set FORWARD_IP_HEADER=<name> to force a header)" ;;
    esac
}

# =============================================================
# LOGGER STATUS  (security-logs/logger-status.log)
# =============================================================
# "It is not logging logins" used to be unanswerable from outside: the file was
# empty and there was no way to tell whether the server saw no joins, or the
# lines arrived in a shape the parser did not know. This file says which, and
# prints the raw lines the parser is being fed, so a mismatch is visible in the
# bucket without access to the Space.
write_logger_status() {
    local out="$SEC_DIR/logger-status.log" tmp
    [ -n "$SEC_DIR" ] || return 0
    mkdir -p "$SEC_DIR" 2>/dev/null
    tmp="${out}.tmp"
    {
        echo "verified-client logger status   $(date '+%F %T')"
        echo "version        : ${SCRIPT_VERSION:-unknown}"
        echo "paper.log      : $(wc -l < /tmp/paper.log 2>/dev/null || echo 0) lines"
        echo "bungee.log     : $(wc -l < /tmp/bungee.log 2>/dev/null || echo 0) lines"
        echo "online now     : $(tr '\n' ' ' < "${ONLINE_STATE:-/dev/null}" 2>/dev/null)"
        echo "logins.log     : $(grep -c '| LOGIN |' "$LOGIN_LOG" 2>/dev/null) logins, $(grep -c '| LOGOUT |' "$LOGIN_LOG" 2>/dev/null) logouts"
        echo "commands.log   : $(wc -l < "$CMD_LOG" 2>/dev/null || echo 0) rows"
        echo "client-checks  : $(wc -l < "$CLIENT_LOG" 2>/dev/null || echo 0) rows"
        echo "playerlist     : ${PLAYERLIST_LAST:-not polled yet}"
        echo "real client IPs: $(real_client_ip_line)"
        echo "proxy peers    : $(proxy_peer_list 2>/dev/null | tr '\n' ' ')"
        echo "ip evidence    : $(ip_evidence_line)"
        echo "login capture  : ${AUTH_PATCH_STATUS:-not run}"
        if [ "$VERIFIED_CLIENT_CONFIGURED" = true ]; then
            echo "verified client: ${VERIFIED_CLIENT_BRAND} (uuid ${VERIFIED_CLIENT_UUID})"
            echo "  from         : ${VERIFIED_CLIENT_SOURCE:-?}$([ "$VERIFIED_CLIENT_SOURCE" = environment ] && echo " - the Space secrets win over the built-in pair")"
        else
            echo "verified client: NOT CONFIGURED (nobody is marked as you)"
        fi
        local _vcproblem
        _vcproblem=$(verified_client_problem)
        [ -n "$_vcproblem" ] && printf '%s\n' "$_vcproblem" | sed 's/^/  !! /'
        echo "enforcement    : ENFORCE_VERIFIED_CLIENT=${ENFORCE_VERIFIED_CLIENT:-false} (false = everybody may join)"
        echo "tail of logins.log:"
        tail -3 "$LOGIN_LOG" 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "--- raw lines the parsers see (last 6 login/command-like lines of each) ---"
        echo "if a join is missing from logins.log, compare its shape with the patterns"
        echo "paper.log:"
        grep -a -E 'logged in|left the game|lost connection|issued server command|\.\[IP' /tmp/paper.log 2>/dev/null | tail -6 | sed 's/^/  /'
        echo "bungee.log:"
        grep -a -E 'has connected|has disconnected|executed command|disconnecting' /tmp/bungee.log 2>/dev/null | tail -6 | sed 's/^/  /'
    } > "$tmp" 2>/dev/null
    mv "$tmp" "$out" 2>/dev/null
}

report_shared_ips() {
    flush_pending_auth
    [ -s "$LOGIN_LOG" ] || return
    ip_report_body "$IP_MAP" "$SEC_DIR/ip-report.log" yes
    [ "$PRIVATE_IP_LOG" = true ] && ip_report_body "$IP_MAP" "$PRIV_DIR/ip-report-private.log" no
    {
        echo "=== Shared IP report $(date '+%F %T') ==="
        [ "$HIDE_VERIFIED_IP" = true ] && \
            echo "(the verified client's own IP shows as \"hidden\" here - see private-logs/shared-ips-private.txt)"
    } > "$SHARED_REPORT"
    shared_report_body "$LOGIN_LOG" "$SHARED_REPORT"

    # private copy with the real IPs put back in, for your own analysis
    if [ "$HIDE_VERIFIED_IP" = true ] && [ "$PRIVATE_IP_LOG" = true ]; then
        local name ip line
        : > "$PRIV_DIR/logins-real-ips.log"
        while IFS= read -r line; do
            if [[ "$line" == *"| hidden"* ]]; then
                name=$(awk -F' [|] ' '{print $3}' <<<"$line")
                ip=$(last_ip_for "$name")
                line="${line//| hidden/| ${ip:-unknown}}"
            fi
            printf '%s\n' "$line" >> "$PRIV_DIR/logins-real-ips.log"
        done < "$LOGIN_LOG"
        echo "=== Shared IP report (real IPs) $(date '+%F %T') ===" > "$PRIV_DIR/shared-ips-private.txt"
        shared_report_body "$PRIV_DIR/logins-real-ips.log" "$PRIV_DIR/shared-ips-private.txt"
        {
            echo ""
            echo "=== Last 20 logins with their real IPs ==="
            tail -20 "$PRIV_DIR/logins-real-ips.log"
        } >> "$PRIV_DIR/shared-ips-private.txt"
    fi
}

# =============================================================
# HuggingFace Bucket
# =============================================================
hf_authenticate() {
    if [ -n "$HF_TOKEN" ]; then
        hf auth login --token "$HF_TOKEN" --add-to-git-credential 2>/dev/null || true
        echo " Authenticated"
    else
        echo " No HF_TOKEN"
    fi
}

hf_ensure_bucket() {
    local BUCKET_ID
    BUCKET_ID=$(echo "$HF_BUCKET_HANDLE" | sed 's|hf://buckets/||')
    hf buckets create "$BUCKET_ID" --exist-ok 2>/dev/null
    ensure_bucket_sync_py
    python3 "$BUCKET_SYNC_PY" --create "$BUCKET_ID" >/dev/null 2>&1 || true
}

# >>> embedded bucket_sync.py (generated from tools/bucket_sync.py) >>>
write_bucket_sync_py() {
    mkdir -p "$(dirname "$BUCKET_SYNC_PY")" 2>/dev/null
    cat > "$BUCKET_SYNC_PY" <<'BUCKET_SYNC_PY_EOF'
#!/usr/bin/env python3
"""
bucket_sync.py - copy a local directory into a Hugging Face *bucket*.

Why this exists: everything the server logs is meant to be readable from the
bucket, but the upload happens from inside the Space and the `hf` CLI there can
fail for reasons the Space itself can only report (missing CLI, read-only
token, an older CLI without `hf buckets`, ...).  This script is the fallback:
it needs nothing but `huggingface_hub`, which the Space image already installs.

usage:
    bucket_sync.py <local_dir> <bucket_id> <prefix> [--delete] [--token TOKEN]
    bucket_sync.py --probe <bucket_id> [--prefix P] [--token TOKEN]
    bucket_sync.py --whoami  [--token TOKEN]

`bucket_id` is `namespace/name` (the part after `hf://buckets/`), `prefix` is
the folder inside the bucket (may be empty).

It prints exactly one summary line that start.sh logs:

    bucket-sync: uploaded=3 skipped=2 deleted=1 bytes=4096 prefix=game-data method=batch

Exit code 0 = the bucket is up to date, 1 = something failed (the reason is
printed to stderr as well, so it shows up in the Space logs).
"""

import argparse
import os
import sys
from pathlib import Path

SUMMARY_PREFIX = "bucket-sync:"


def log(msg):
    print(msg, flush=True)


def fail(msg, code=1):
    print(f"bucket-sync: ERROR {msg}", file=sys.stderr, flush=True)
    raise SystemExit(code)


def load_api(token=None):
    try:
        from huggingface_hub import HfApi
    except Exception as exc:  # pragma: no cover - only when the image is broken
        fail(f"huggingface_hub is not installed ({exc}). "
             f"pip install 'huggingface_hub[cli]' in the image")
    try:
        return HfApi(token=token)
    except Exception as exc:
        fail(f"could not create the Hub client ({exc})")


def whoami(api):
    try:
        info = api.whoami()
    except Exception as exc:
        fail(f"the token is not usable ({exc.__class__.__name__}: {exc})")
    name = info.get("name") or info.get("user") or "?"
    role = "?"
    auth = info.get("auth") or {}
    access = (auth.get("accessToken") or {}) if isinstance(auth, dict) else {}
    if isinstance(access, dict):
        role = access.get("role") or role
    log(f"{SUMMARY_PREFIX} user={name} token_role={role}")
    return name, role


def iter_local(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            path = Path(dirpath) / name
            try:
                size = path.stat().st_size
            except OSError:
                continue
            yield path.relative_to(root).as_posix(), path, size


def join(prefix, rel):
    return f"{prefix}/{rel}" if prefix else rel


def strip_prefix(path, prefix):
    if prefix and path.startswith(prefix + "/"):
        return path[len(prefix) + 1:]
    return path


def list_remote(api, bucket_id, prefix):
    """{relative path: size} of what is already in the bucket under prefix."""
    try:
        tree = api.list_bucket_tree(bucket_id, prefix=prefix or None, recursive=True)
    except TypeError:                      # older signature
        tree = api.list_bucket_tree(bucket_id, recursive=True)
    except Exception as exc:
        fail(f"could not list the bucket ({exc.__class__.__name__}: {exc}). "
             f"Does the token have write access to {bucket_id}?")
    out = {}
    for item in tree:
        path = getattr(item, "path", None) or getattr(item, "file_path", None)
        size = getattr(item, "size", None)
        if path is None or size is None:   # folders have no size
            continue
        out[strip_prefix(path, prefix)] = size
    return out


def batch(api, bucket_id, add, delete):
    if api is not None and hasattr(api, "batch_bucket_files"):
        api.batch_bucket_files(bucket_id, add=add or None, delete=delete or None)
        return "batch"
    try:
        from huggingface_hub import batch_bucket_files as fn
    except Exception:
        fn = None
    if fn is not None:
        fn(bucket_id, add=add or None, delete=delete or None)
        return "batch"
    # last resort: the directory sync of huggingface_hub >= 1.5
    if hasattr(api, "sync_bucket"):
        return "sync"
    fail("this huggingface_hub has no bucket upload API - "
         "upgrade it (`pip install -U 'huggingface_hub[cli]'`)")


def cmd_sync(args):
    api = load_api(args.token)
    root = Path(args.local_dir)
    if not root.is_dir():
        fail(f"{root} is not a directory")

    local = {rel: size for rel, _path, size in iter_local(root)}
    remote = list_remote(api, args.bucket_id, args.prefix)

    add = [(str(path), join(args.prefix, rel), size)
           for rel, path, size in iter_local(root)
           if remote.get(rel) != size]
    delete = [join(args.prefix, rel) for rel in remote
              if args.delete and rel not in local]

    method = "batch"
    if add or delete:
        method = batch(api, args.bucket_id, [(src, dst) for src, dst, _size in add], delete)
        if method == "sync":               # fallback for other library versions
            api.sync_bucket(str(root), f"hf://buckets/{args.bucket_id}"
                            + (f"/{args.prefix}" if args.prefix else ""),
                            delete=args.delete)
    log(f"{SUMMARY_PREFIX} uploaded={len(add)} skipped={len(local) - len(add)} "
        f"deleted={len(delete)} bytes={sum(size for _s, _d, size in add)} "
        f"prefix={args.prefix or '.'} method={method}")
    return 0


def cmd_probe(args):
    api = load_api(args.token)
    whoami(api)
    marker = join(args.prefix, ".write-probe")
    try:
        api.batch_bucket_files(args.bucket_id, add=[(b"probe", marker)])
        api.batch_bucket_files(args.bucket_id, delete=[marker])
    except Exception as exc:
        fail(f"no write access to {args.bucket_id} ({exc.__class__.__name__}: {exc})")
    log(f"{SUMMARY_PREFIX} probe ok - {args.bucket_id} is writable")
    return 0


def cmd_create(args):
    api = load_api(args.token)
    try:
        api.create_bucket(args.bucket_id, private=True, exist_ok=True)
    except Exception as exc:
        log(f"{SUMMARY_PREFIX} could not create {args.bucket_id} "
            f"({exc.__class__.__name__}: {exc}) - assuming it exists")
        return 0
    log(f"{SUMMARY_PREFIX} bucket {args.bucket_id} ready")
    return 0


def cmd_whoami(args):
    whoami(load_api(args.token))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("local_dir", nargs="?")
    ap.add_argument("bucket_id", nargs="?")
    ap.add_argument("prefix", nargs="?", default="")
    ap.add_argument("--delete", action="store_true",
                    help="also remove bucket files that are not local anymore")
    ap.add_argument("--probe", action="store_true",
                    help="only test that the token can write to the bucket")
    ap.add_argument("--create", action="store_true",
                    help="only make sure the bucket exists")
    ap.add_argument("--whoami", action="store_true",
                    help="print the token's user and role, then exit")
    ap.add_argument("--token", default=os.environ.get("HF_TOKEN") or None)
    args = ap.parse_args(argv)

    # --probe/--create take the bucket id as their only argument, so it can
    # land in either position
    if args.whoami:
        return cmd_whoami(args)
    if args.probe or args.create:
        args.bucket_id = args.bucket_id or args.local_dir
        if not args.bucket_id:
            ap.error("--probe/--create need a bucket id (namespace/name)")
        return cmd_probe(args) if args.probe else cmd_create(args)
    if not args.local_dir or not args.bucket_id:
        ap.error("local_dir and bucket_id are required (or use --probe/--whoami)")
    return cmd_sync(args)


if __name__ == "__main__":
    sys.exit(main())
BUCKET_SYNC_PY_EOF
}
ensure_bucket_sync_py() {
    [ -s "$BUCKET_SYNC_PY" ] || write_bucket_sync_py
}
# <<< embedded bucket_sync.py <<<

# The bucket sync, the world copy and the log parsers run on the same two cores
# as Paper.  They are pushed to the lowest CPU (and disk) priority so the tick
# loop always wins the core: the upload then takes a little longer, but a player
# never feels it as a lag spike.  Both tools are probed once - a container
# without ionice (or without the permission to set an I/O class) silently falls
# back to nice, and a container without nice runs them as before.
BG_PRIORITY=()
if command -v ionice >/dev/null 2>&1 && ionice -c3 true >/dev/null 2>&1; then
    BG_PRIORITY=(nice -n 19 ionice -c3)
elif command -v nice >/dev/null 2>&1; then
    BG_PRIORITY=(nice -n 19)
fi

bucket_py() {   # run the embedded bucket uploader (tools/bucket_sync.py)
    ensure_bucket_sync_py
    "${BG_PRIORITY[@]}" python3 "$BUCKET_SYNC_PY" "$@" 2>&1
}

# hf://buckets/ns/name/game-data -> "ns/name", and the part after it on stdout
bucket_id_of() {
    printf '%s' "${1#hf://buckets/}" | cut -d/ -f1,2
}

bucket_prefix_of() {
    printf '%s' "${1#hf://buckets/}" | cut -d/ -f3-
}

# Copy a local directory into the bucket. Tries the hf CLI first (it skips
# unchanged files) and falls back to the Python API when the CLI is missing,
# too old, or not allowed to write - so the logs/backups cannot silently stop
# being uploaded. $3 may be --delete (mirror, used for the world backup).
bucket_sync_dir() {
    local local_dir="$1" remote="$2" flag="${3:-}" bucket_id prefix out rc method
    method="${BUCKET_METHOD:-auto}"
    bucket_id=$(bucket_id_of "$remote")
    prefix=$(bucket_prefix_of "$remote")
    BUCKET_ERROR=""

    if [ "$method" != "python" ] && command -v hf >/dev/null 2>&1; then
        out=$("${BG_PRIORITY[@]}" hf buckets sync "$local_dir" "$remote" $flag 2>&1); rc=$?
        if [ $rc -eq 0 ]; then
            BUCKET_VIA="cli"
            return 0
        fi
        BUCKET_ERROR=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' ' ')
        if [ "$method" = "cli" ]; then
            echo "   [BUCKET] hf buckets sync failed: $BUCKET_ERROR"
            return 1
        fi
        echo "   [BUCKET] hf buckets sync failed (rc=$rc): $BUCKET_ERROR"
        echo "   [BUCKET] retrying with the Python API..."
    fi

    out=$(bucket_py "$local_dir" "$bucket_id" "$prefix" $flag)
    rc=$?
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -3 | sed 's/^/   /'
    if [ $rc -eq 0 ]; then
        BUCKET_VIA="python"
        return 0
    fi
    BUCKET_ERROR=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' ' ')
    BUCKET_VIA=""
    return 1
}

# Does the Space's token actually have write access? Asked once at boot, with
# the answer (and the fix) printed where the user can see it in the Logs tab.
bucket_write_probe() {
    local out rc bucket_id role
    BUCKET_WRITE_OK=false
    BUCKET_VIA=""
    bucket_id=$(bucket_id_of "$HF_BUCKET_HANDLE")
    echo "[BUCKET] write test: $HF_BUCKET_HANDLE"

    out=$(bucket_py --whoami); rc=$?
    if [ $rc -eq 0 ]; then
        role=$(printf '%s\n' "$out" | sed -n 's/.*token_role=\([^ ]*\).*/\1/p' | head -1)
        [ -n "$role" ] && echo "   [BUCKET] token role: $role"
    else
        echo "   [BUCKET] $(printf '%s\n' "$out" | tail -1)"
    fi

    if [ "${BUCKET_METHOD:-auto}" != "python" ] && command -v hf >/dev/null 2>&1; then
        printf 'probe' > /tmp/.hf-write-probe
        out=$(hf buckets cp /tmp/.hf-write-probe "$HF_BUCKET_HANDLE/.write-probe" 2>&1); rc=$?
        if [ $rc -eq 0 ]; then
            hf buckets remove "$HF_BUCKET_HANDLE/.write-probe" >/dev/null 2>&1
            BUCKET_WRITE_OK=true
            BUCKET_VIA="cli"
            echo "   [BUCKET] write test OK (hf CLI)"
            return 0
        fi
        echo "   [BUCKET] hf CLI cannot write: $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
    fi

    out=$(bucket_py --probe "$bucket_id"); rc=$?
    if [ $rc -eq 0 ]; then
        BUCKET_WRITE_OK=true
        BUCKET_VIA="python"
        BUCKET_METHOD="python"
        echo "   [BUCKET] write test OK (Python API)"
        return 0
    fi

    echo "   [BUCKET] $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
    echo "   [BUCKET] !! NOTHING will reach the bucket until this works."
    echo "   [BUCKET] !! 1. open huggingface.co/settings/tokens -> New token -> Write"
    echo "   [BUCKET] !! 2. copy it, then Space Settings -> Variables and secrets"
    echo "   [BUCKET] !! 3. new secret: name HF_TOKEN, value the token, then Restart"
    return 1
}

hf_restore_saves() {
    echo " Restoring game data..."
    hf buckets sync "${HF_BUCKET_HANDLE}/game-data" "$BACKEND_DIR" 2>&1 | tail -5
    for dir in $SAVE_DIRS; do
        [ -e "$BACKEND_DIR/$dir" ] && echo "   Found: $dir"
    done
}

# Copying the whole world out and hashing it in the bucket costs CPU (and disk)
# on the same two cores Paper runs on, so every run reports how long it took:
# if the game hitches in a regular rhythm, these lines are the first thing to
# look at (SYNC_INTERVAL is a Space variable if you want it less often).
hf_push_saves() {
    report_shared_ips
    local STAGING="$FULL_STAGING" out rc STARTED TOOK
    STARTED=$(date +%s)
    rm -rf "$STAGING" && mkdir -p "$STAGING"
    for item in $SAVE_DIRS; do
        if [ -e "$BACKEND_DIR/$item" ]; then
            mkdir -p "$STAGING/$(dirname "$item")"
            "${BG_PRIORITY[@]}" cp -a "$BACKEND_DIR/$item" "$STAGING/$item"
        fi
    done
    if bucket_sync_dir "$STAGING" "${HF_BUCKET_HANDLE}/game-data" --delete; then
        TOOK=$(($(date +%s) - STARTED))
        echo "[SYNC] OK $(date '+%H:%M:%S') via ${BUCKET_VIA:-?} (took ${TOOK}s)"
    else
        TOOK=$(($(date +%s) - STARTED))
        echo "[SYNC] FAIL $(date '+%H:%M:%S') - ${BUCKET_ERROR:-unknown error} (took ${TOOK}s)"
    fi
    rm -rf "$STAGING"
}

# Fast log-only sync: the bucket is the only way to read the logs from outside
# the Space, so the log folders are pushed every $LOG_SYNC_INTERVAL seconds
# instead of waiting for the full game-data sync. No --delete here: this must
# never remove anything from game-data (world, plugins, ...).
hf_push_logs() {
    flush_pending_auth
    report_shared_ips
    proxy_peers_record
    local STAGING="$LOG_STAGING" out rc STARTED TOOK
    STARTED=$(date +%s)
    rm -rf "$STAGING" && mkdir -p "$STAGING"
    [ -d "$SEC_DIR" ] && cp -a "$SEC_DIR" "$STAGING/security-logs"
    if [ "$SYNC_PRIVATE_LOGS" = true ] && [ -d "$PRIV_DIR" ]; then
        cp -a "$PRIV_DIR" "$STAGING/private-logs"
    fi
    if [ "$SYNC_CONSOLE_LOGS" = true ]; then
        mkdir -p "$STAGING/logs"
        # mask_console_tail: no password and no verified-client address in the
        # copies that leave the Space (auth.log keeps the full commands)
        [ -f /tmp/paper.log ]  && tail -n "$CONSOLE_LOG_LINES" /tmp/paper.log  | mask_console_tail > "$STAGING/logs/paper.log"  2>/dev/null
        [ -f /tmp/bungee.log ] && tail -n "$CONSOLE_LOG_LINES" /tmp/bungee.log | mask_console_tail > "$STAGING/logs/bungee.log" 2>/dev/null
    fi
    LOG_SYNC_FILES=$(cd "$STAGING" 2>/dev/null && find . -type f -printf '%P(%s) ' 2>/dev/null | sort)
    if bucket_sync_dir "$STAGING" "${HF_BUCKET_HANDLE}/game-data"; then
        TOOK=$(($(date +%s) - STARTED))
        echo "[LOGSYNC] OK $(date '+%H:%M:%S') via ${BUCKET_VIA:-?} (took ${TOOK}s) (security-logs$([ "$SYNC_PRIVATE_LOGS" = true ] && echo ' + private-logs')$([ "$SYNC_CONSOLE_LOGS" = true ] && echo ' + console tails'))"
        echo "          $(printf '%s' "$LOG_SYNC_FILES")"
    else
        TOOK=$(($(date +%s) - STARTED))
        echo "[LOGSYNC] FAIL $(date '+%H:%M:%S') - ${BUCKET_ERROR:-unknown error} (took ${TOOK}s)"
    fi
    rm -rf "$STAGING"
}

hf_sync_loop() {
    while true; do
        sleep "$SYNC_INTERVAL"
        hf_push_saves
    done
}

log_sync_loop() {
    while true; do
        hf_push_logs
        sleep "$LOG_SYNC_INTERVAL"
    done
}

# =============================================================
# STEP 0: Bucket
# =============================================================
echo "[0/7] Bucket setup..."
hf_authenticate
hf_ensure_bucket
bucket_write_probe || true
hf_restore_saves
mkdir -p "$SEC_DIR" "$PRIV_DIR"
touch "$LOGIN_LOG" "$CMD_LOG" "$CLIENT_LOG" "$AUTH_LOG"
: > "$ONLINE_STATE"
echo ""

# =============================================================
# STEP 1: World size
# =============================================================
echo "[1/7] World analysis..."
for WORLD_DIR in world world_nether world_the_end; do
    if [ -d "$BACKEND_DIR/$WORLD_DIR" ]; then
        SIZE=$(du -sh "$BACKEND_DIR/$WORLD_DIR" 2>/dev/null | awk '{print $1}')
        REGIONS=$(find "$BACKEND_DIR/$WORLD_DIR" -name "*.mca" 2>/dev/null | wc -l)
        echo "   $WORLD_DIR: $SIZE ($REGIONS region files)"
    fi
done
echo ""

# =============================================================
# STEP 2: Core server configs + Start Paper
# =============================================================
cd "$BACKEND_DIR"
echo "eula=true" > eula.txt

echo "[2/7] Writing core server configs + starting Paper..."

cat > server.properties << 'EOF'
server-port=25565
server-ip=127.0.0.1
online-mode=false
spawn-protection=0
max-players=20
view-distance=6
gamemode=0
difficulty=2
level-name=world
level-type=DEFAULT
generate-structures=true
motd=Vanilla Survival Eaglercraft
pvp=true
allow-flight=false
white-list=false
spawn-npcs=true
spawn-animals=true
spawn-monsters=true
enable-command-block=false
allow-nether=true
use-native-transport=true
network-compression-threshold=-1
entity-broadcast-range-percentage=50
max-tick-time=-1
enable-rcon=true
rcon.port=25575
rcon.password=chunkystart
EOF

cat > bukkit.yml << 'EOF'
settings:
  allow-end: true
  warn-on-overload: true
  connection-throttle: -1
  shutdown-message: Server closed
  save-user-cache-on-stop-only: true
spawn-limits:
  monsters: 50
  animals: 10
  water-animals: 2
  ambient: 1
chunk-gc:
  period-in-ticks: 600
ticks-per:
  animal-spawns: 600
  monster-spawns: 4
  autosave: 12000
EOF

cat > spigot.yml << 'EOF'
config-version: 8
settings:
  bungeecord: true
  timeout-time: 60
  netty-threads: 2
  async-catcher-enabled: false
  save-user-cache-on-stop-only: true
  moved-wrongly-threshold: 0.0625
  moved-too-quickly-multiplier: 10.0
  item-dirty-ticks: 20
  player-shuffle: 0
commands:
  tab-complete: 0
  log: true
world-settings:
  default:
    verbose: false
    view-distance: 4
    mob-spawn-range: 4
    entity-activation-range:
      animals: 16
      monsters: 24
      misc: 8
      tick-inactive-villagers: false
    entity-tracking-range:
      players: 48
      animals: 32
      monsters: 32
      misc: 16
      other: 48
    ticks-per:
      hopper-transfer: 8
      hopper-check: 1
    hopper-amount: 1
    max-entity-collisions: 2
    merge-radius:
      exp: 6.0
      item: 4.0
    arrow-despawn-rate: 60
    item-despawn-rate: 3000
    nerf-spawner-mobs: true
    zombie-aggressive-towards-villager: true
    enable-zombie-pigmen-portal-spawns: true
EOF

# Let the auth plugins' own log filters stop hiding /login from the console
# (without this the parser has nothing to read - see AUTH LOG CAPTURE above).
apply_auth_filter_patch

setup_op_account

> /tmp/paper.log
start_paper
echo " Paper PID: $BACKEND_PID"
wait_for_paper_ready || exit 1
# If a patched plugin did not load, roll the original jar back and restart once
auth_patch_post_start_check || true

# Start security logger (logins/IPs + commands + verified client checks)
warn_verified_client_problem
warn_verified_client_mismatch
proxy_peers_record 2>/dev/null || true
write_logger_status
start_security_logger
echo " Security logger PID: $SECLOG_PID"

# Safety net for logins the log files never showed (RCON `list` polling)
playerlist_loop &
PLAYERLIST_PID=$!
echo " Player list watchdog PID: $PLAYERLIST_PID (every ${PLAYERLIST_POLL}s)"

# one-time: find the header that carries the real client IP
if [ "$FORWARD_IP_DECISION" = "probe" ]; then
    discover_forward_ip_header || true
fi

for i in $(seq 1 30); do
    nc -z 127.0.0.1 25575 2>/dev/null && break
    sleep 1
done

if [ -n "$OP_USERNAME" ]; then
    mc_command "op ${OP_USERNAME}"
    echo " OP granted to ${OP_USERNAME} via RCON"
fi

echo ""
echo " === PLUGINS LOADED ==="
grep -i "Enabling" /tmp/paper.log | grep -oP "Enabling \K[^\s]+" 2>/dev/null | while read p; do
    echo "   - $p"
done
echo " ======================"
echo ""

# =============================================================
# STEP 3: Vanilla Survival gamerules
# =============================================================
echo "[3/7] Setting Vanilla gamerules..."
mc_command "gamerule pvp true"
mc_command "gamerule keepInventory false"
mc_command "gamerule naturalRegeneration true"
mc_command "gamerule doFireTick true"
mc_command "gamerule mobGriefing true"
mc_command "gamerule announceAdvancements true"
mc_command "difficulty 1"
mc_command "seed"
mc_command "defaultgamemode survival"
echo " Survival gamerules set"
echo ""

# =============================================================
# STEP 4: Idle mode
# =============================================================
echo "[4/7] Applying idle mode (no players)..."
enter_idle_mode
echo ""

# =============================================================
# STEP 5: Write BungeeCord config
# =============================================================
echo "[5/7] Writing BungeeCord config..."

cd "$BUNGEE_DIR"

cat > config.yml << 'EOF'
server_connect_timeout: 5000
remote_ping_cache: -1
forge_support: false
player_limit: 10
permissions:
  default:
    - bungeecord.command.server
  admin:
    - bungeecord.command.alert
timeout: 30000
log_commands: true
network_compression_threshold: 256
online_mode: false
disabled_commands:
  - disabledcommandhere
servers:
  lobby:
    motd: '&aEaglercraft Survival'
    address: 127.0.0.1:25565
    restricted: false
listeners:
  - query_port: 25577
    motd: '&6Eaglercraft 1.12.2 Survival'
    tab_list: GLOBAL_PING
    query_enabled: false
    proxy_protocol: false
    forced_hosts: {}
    ping_passthrough: false
    priorities:
      - lobby
    bind_local_address: true
    host: 127.0.0.1:25577
    max_players: 10
    tab_size: 60
    force_default_server: true
ip_forward: true
remote_ping_timeout: 5000
prevent_proxy_connections: false
groups:
  default:
    - default
connection_throttle: -1
connection_throttle_limit: 0
stats: none
log_pings: false
EOF
echo "   BungeeCord config.yml written"

echo ""
echo "   Reloading server via RCON..."
sleep 2
mc_command "reload confirm"
echo "   Full server reload done"
echo ""

# =============================================================
# STEP 6: EaglerXServer generation + Start BungeeCord
# =============================================================
LISTENERS_FILE=$(find_listeners_yml)

if [ -z "$LISTENERS_FILE" ]; then
    echo "[6/7] Generating EaglerXServer config..."
    cd "$BUNGEE_DIR"
    $JAVA "${BUNGEE_JVM_FLAGS[@]}" \
        -cp "sqlite-jdbc.jar:BungeeCord.jar" \
        net.md_5.bungee.Bootstrap >> /tmp/bungee-gen.log 2>&1 &
    GEN_PID=$!

    for i in $(seq 1 60); do
        if nc -z 127.0.0.1 8081 2>/dev/null || nc -z 127.0.0.1 7860 2>/dev/null; then
            echo " EaglerXServer started (~$((i*2))s)"
            break
        fi
        if ! kill -0 $GEN_PID 2>/dev/null; then
            echo " Generation failed"
            tail -20 /tmp/bungee-gen.log
            break
        fi
        sleep 2
    done

    sleep 3
    kill $GEN_PID 2>/dev/null
    wait $GEN_PID 2>/dev/null
    for i in $(seq 1 15); do
        nc -z 127.0.0.1 8081 2>/dev/null || break
        sleep 1
    done
    sleep 2
else
    echo "[6/7] EaglerXServer config exists"
fi

echo " Starting BungeeCord..."

patch_eagler_port
FORWARD_IP_DECISION=""
apply_forward_ip_choice

# === MOTD AND ICON PATCH ===
LISTENERS_NOW=$(find_listeners_yml)
if [ -n "$LISTENERS_NOW" ]; then
    sed -i 's/An EaglercraftX server/\&e\&l★ \&a\&lSurvival 1.12 Server \&e\&l★/g' "$LISTENERS_NOW"
    sed -i 's/smodusermc-server.hf.space/\&r\&7Survive, craft and explore!/g' "$LISTENERS_NOW"
fi

EAGLER_DIR=$(dirname "$(find_listeners_yml)" 2>/dev/null)

if [ -n "$EAGLER_DIR" ]; then
    mkdir -p "$EAGLER_DIR/drivers"
    cp -f "$BUNGEE_DIR/sqlite-jdbc.jar" "$EAGLER_DIR/drivers/sqlite-jdbc.jar" 2>/dev/null
fi

> /tmp/bungee.log
start_bungee
echo " BungeeCord PID: $BUNGEE_PID"

PORT_READY=false
for i in $(seq 1 45); do
    if nc -z 127.0.0.1 7860 2>/dev/null; then
        PORT_READY=true
        echo " Port 7860 OPEN (~$((i*2))s)"
        break
    fi
    if ! kill -0 $BUNGEE_PID 2>/dev/null; then
        echo " BungeeCord crashed!"
        tail -20 /tmp/bungee.log
        break
    fi
    sleep 2
done

if [ "$PORT_READY" = true ]; then
    echo ""
    echo "============================================"
    echo " SERVER READY — Vanilla EaglerCraft on :7860"
    [ -n "$OP_USERNAME" ] && echo " OP: $OP_USERNAME (level 4)"
    echo " Plugins Synced via HuggingFace!"
    echo " Security logging ACTIVE  ->  ${HF_BUCKET_HANDLE}/game-data/"
    if [ "$BUCKET_WRITE_OK" = true ]; then
        echo "   bucket uploads: OK (${BUCKET_VIA:-?}), every ${LOG_SYNC_INTERVAL}s + world every ${SYNC_INTERVAL}s"
    else
        echo "   bucket uploads: FAILING - see the [BUCKET] lines above"
    fi
    echo "   security-logs/{logins,commands,client-checks}.log"
    echo "                  + shared-ips.txt, ip-report.log, logger-status.log"
    [ "$SYNC_PRIVATE_LOGS" = true ] && \
        echo "   private-logs/{auth,player-ips,logins-real-ips,ip-report-private}.log"
    if [ "$VERIFIED_CLIENT_CONFIGURED" = true ]; then
        echo " Verified client: $VERIFIED_CLIENT_BRAND  (uuid $VERIFIED_CLIENT_UUID)"
        echo "   pair from: $VERIFIED_CLIENT_SOURCE$([ "$VERIFIED_CLIENT_SOURCE" = environment ] && echo ' (Space secrets override the built-in pair)')"
    else
        echo " Verified client: NOT CONFIGURED - set VERIFIED_CLIENT_BRAND/_UUID in"
        echo "                  the Space's Variables and secrets (nobody is marked as you)"
    fi
    echo "   everybody may join (ENFORCE_VERIFIED_CLIENT=$ENFORCE_VERIFIED_CLIENT); the"
    echo "   verified client is only marked in the logs (IP hidden, no client= tag)"
    echo "   every brand ever committed to the repo (Eaglercraft[VER], EaglercraftX[V2],"
    echo "   the stock one) is refused - it cannot make anybody 'verified' any more"
    echo "   real client IPs: $(forward_ip_setting 2>/dev/null)"
    echo "   build: $SCRIPT_VERSION"
    echo "============================================"
else
    echo " Port 7860 NOT open!"
    for port in 7860 8081 25565 25577; do
        nc -z 127.0.0.1 $port 2>/dev/null && echo "   OK $port" || echo "   FAIL $port"
    done
    LISTENERS_NOW=$(find_listeners_yml)
    if [ -n "$LISTENERS_NOW" ] && grep -q ":8081" "$LISTENERS_NOW"; then
        kill $BUNGEE_PID 2>/dev/null
        wait $BUNGEE_PID 2>/dev/null
        sleep 3
        patch_eagler_port
        start_bungee
        sleep 20
        nc -z 127.0.0.1 7860 2>/dev/null && echo " Port 7860 open!" || echo " Failed"
    fi
fi

# =============================================================
# STEP 7: Final confirmation
# =============================================================
echo ""
echo "[7/7] Final status check..."
echo " === ACTIVE PLUGINS ==="
RELOAD_CHECK=$(mc_command "plugins")
echo "   $RELOAD_CHECK"
echo " ======================"
echo ""

# =============================================================
# Sync loops — full game data + fast log-only sync
# =============================================================
hf_sync_loop &
SYNC_PID=$!
log_sync_loop &
LOGSYNC_PID=$!
forward_ip_retry_loop &
FORWARDIP_PID=$!

# =============================================================
# Shutdown — save world properly, then push, then stop processes
# =============================================================
graceful_shutdown() {
    echo " Shutting down..."
    mc_command "gamerule doMobSpawning true"
    mc_command "gamerule randomTickSpeed 3"
    mc_command "save-all"
    sleep 5
    pkill -f "tail -n0 -F /tmp/" 2>/dev/null
    kill $SECLOG_PID 2>/dev/null
    kill $LOGSYNC_PID 2>/dev/null
    hf_push_logs     # make sure the last log lines reached the bucket
    hf_push_saves
    kill $SYNC_PID 2>/dev/null
    mc_command "stop"
    sleep 5
    kill $BUNGEE_PID 2>/dev/null
    kill -0 $BACKEND_PID 2>/dev/null && kill $BACKEND_PID 2>/dev/null
    exit 0
}

trap graceful_shutdown SIGTERM SIGINT SIGHUP

# =============================================================
# Monitor loop
# =============================================================
echo ""
echo "Monitor loop started..."

LAST_LOG_LINE=$(wc -l < /tmp/paper.log 2>/dev/null || echo 0)
LOOP_COUNT=0
LOG_STATUS_TS=0

while true; do
    LOOP_COUNT=$((LOOP_COUNT + 1))
    # refresh the status file the bucket carries, but not on every tick (the
    # writer greps the raw console logs)
    if [ $(( $(date +%s) - LOG_STATUS_TS )) -ge "${LOG_STATUS_INTERVAL:-60}" ]; then
        write_logger_status 2>/dev/null
        LOG_STATUS_TS=$(date +%s)
    fi

    if ! kill -0 $BACKEND_PID 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] Paper crashed — restarting..."
        hf_push_saves
        IDLE_MODE=false
        start_paper
        sleep 45
        for i in $(seq 1 30); do
            nc -z 127.0.0.1 25575 2>/dev/null && break
            sleep 1
        done
        if [ -n "$OP_USERNAME" ]; then
            mc_command "op ${OP_USERNAME}"
        fi
        mc_command "gamerule pvp true"
        mc_command "gamerule keepInventory false"
        mc_command "gamerule mobGriefing true"
        enter_idle_mode
    fi

    if ! kill -0 $BUNGEE_PID 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] BungeeCord crashed — restarting..."
        patch_eagler_port
        start_bungee
    fi

    if ! kill -0 $SYNC_PID 2>/dev/null; then
        hf_sync_loop &
        SYNC_PID=$!
    fi

    if [ -z "${LOGSYNC_PID:-}" ] || ! kill -0 "$LOGSYNC_PID" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] Log sync died — restarting..."
        log_sync_loop &
        LOGSYNC_PID=$!
    fi

    if [ -z "${FORWARDIP_PID:-}" ] || ! kill -0 "$FORWARDIP_PID" 2>/dev/null; then
        forward_ip_retry_loop &
        FORWARDIP_PID=$!
    fi

    if ! kill -0 "$SECLOG_PID" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] Security logger died — restarting..."
        start_security_logger
    fi

    if kill -0 $BACKEND_PID 2>/dev/null; then
        PLAYER_COUNT=$(get_player_count)
        if [ "$PLAYER_COUNT" != "0" ] && [ "$IDLE_MODE" = true ]; then
            exit_idle_mode
        elif [ "$PLAYER_COUNT" = "0" ] && [ "$IDLE_MODE" = false ]; then
            enter_idle_mode
        fi
    fi

    # auth commands waiting for a verdict that never came (player left mid-check)
    if [ $((LOOP_COUNT % 10)) -eq 0 ]; then
        flush_pending_auth
    fi

    if [ $((LOOP_COUNT % 5)) -eq 0 ]; then
        CURRENT_LINE=$(wc -l < /tmp/paper.log 2>/dev/null || echo 0)
        if [ "$CURRENT_LINE" -gt "$LAST_LOG_LINE" ]; then
            NEW_ERRORS=$(tail -n +"$((LAST_LOG_LINE + 1))" /tmp/paper.log | grep -c "ERROR\|SEVERE" || echo 0)
            [ "$NEW_ERRORS" -gt 0 ] && echo "[$(date '+%H:%M:%S')] $NEW_ERRORS errors" && \
                tail -n +"$((LAST_LOG_LINE + 1))" /tmp/paper.log | grep "ERROR\|SEVERE" | tail -3
            LAST_LOG_LINE=$CURRENT_LINE
        fi
    fi

    if [ $((LOOP_COUNT % 30)) -eq 0 ]; then
        for LF in /tmp/paper.log /tmp/bungee.log; do
            LS=$(stat -c%s "$LF" 2>/dev/null || echo 0)
            if [ "$LS" -gt 10485760 ]; then
                # Truncate in place so Java and the security logger keep working
                tail -1000 "$LF" > "${LF}.old"
                : > "$LF"
                echo "[$(date '+%H:%M:%S')] Trimmed $(basename $LF)"
            fi
        done
        LAST_LOG_LINE=$(wc -l < /tmp/paper.log 2>/dev/null || echo 0)
    fi

    if [ $((LOOP_COUNT % 5)) -eq 0 ]; then
        RSS=$(ps -p $BACKEND_PID -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
        echo "[STATUS] Players: ${PLAYER_COUNT:-?} | RAM: ${RSS:-?}MB | $([ "$IDLE_MODE" = true ] && echo IDLE || echo ACTIVE)"
    fi

    sleep 60
done
