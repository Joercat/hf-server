#!/usr/bin/env python3
"""Keep the copies of the helper tools that are embedded in start.sh in sync.

The Space only ever receives Dockerfile + start.sh, so every helper that has to
exist inside the container lives in start.sh as a heredoc - but each stays an
ordinary, testable file in tools/.  Run this after editing one of them:

    python3 tools/embed_tools.py

tests/test_verified_client.sh fails when the embedded copy and the file differ,
so the two can never drift apart silently.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
START = ROOT / "start.sh"

TOOLS = [
    {"name": "bucket_sync.py", "var": "BUCKET_SYNC_PY", "marker": "BUCKET_SYNC_PY_EOF",
     "write": "write_bucket_sync_py", "ensure": "ensure_bucket_sync_py"},
    {"name": "forward_ip_probe.py", "var": "FORWARD_IP_PROBE_PY", "marker": "FORWARD_IP_PROBE_EOF",
     "write": "write_forward_ip_probe_py", "ensure": "ensure_forward_ip_probe_py"},
]


def begin(name: str) -> str:
    return f"# >>> embedded {name} (generated from tools/{name}) >>>"


def end(name: str) -> str:
    return f"# <<< embedded {name} <<<"


def block(tool: dict) -> str:
    source = ROOT / "tools" / tool["name"]
    payload = source.read_text()
    if tool["marker"] in payload:
        sys.exit(f"tools/{tool['name']} must not contain the heredoc marker {tool['marker']}")
    fn = tool["write"]
    ensure = tool["ensure"]
    return (
        f"{begin(tool['name'])}\n"
        f"{fn}() {{\n"
        '    mkdir -p "$(dirname "$' + tool["var"] + '")" 2>/dev/null\n'
        f'    cat > "${tool["var"]}" <<\'{tool["marker"]}\'\n'
        f"{payload}"
        f"{tool['marker']}\n"
        "}\n"
        f"{ensure}() {{\n"
        f'    [ -s "${tool["var"]}" ] || {fn}\n'
        "}\n"
        f"{end(tool['name'])}\n"
    )


def main() -> int:
    text = START.read_text()
    changed = []
    for tool in TOOLS:
        new = block(tool).rstrip("\n")
        b, e = begin(tool["name"]), end(tool["name"])
        if b in text:
            start = text.index(b)
            stop = text.index(e, start) + len(e)
            if text[start:stop] == new:
                continue
            text = text[:start] + new + text[stop:]
        else:
            # first time: put it right after the variables it uses
            anchor = 'FORWARD_IP_PROBE_PY="${FORWARD_IP_PROBE_PY:-/tmp/forward_ip_probe.py}"'
            if tool["name"] == "forward_ip_probe.py" and anchor in text:
                pos = text.index(anchor) + len(anchor)
                text = text[:pos] + "\n\n" + new + "\n" + text[pos:]
            else:
                sys.exit(f"cannot find where to insert the embedded {tool['name']}")
        changed.append(tool["name"])
    if changed:
        START.write_text(text)
        print("embedded into start.sh: " + ", ".join(changed))
    else:
        print("start.sh already up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
