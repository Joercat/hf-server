#!/usr/bin/env python3
"""Keep the copy of bucket_sync.py that is embedded in start.sh in sync.

The Space only ever gets Dockerfile + start.sh, so the bucket fallback has to
live inside start.sh - but it stays editable as a normal, testable file here.
Run this after editing tools/bucket_sync.py:

    python3 tools/embed_bucket_sync.py

tests/test_verified_client.sh fails when the two copies differ.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
START = ROOT / "start.sh"
SOURCE = ROOT / "tools" / "bucket_sync.py"

BEGIN = "# >>> embedded bucket_sync.py (generated from tools/bucket_sync.py) >>>"
END = "# <<< embedded bucket_sync.py <<<"


def block() -> str:
    payload = SOURCE.read_text()
    if "BUCKET_SYNC_PY_EOF" in payload:
        sys.exit("tools/bucket_sync.py must not contain the heredoc marker BUCKET_SYNC_PY_EOF")
    return (
        f"{BEGIN}\n"
        "write_bucket_sync_py() {\n"
        '    mkdir -p "$(dirname "$BUCKET_SYNC_PY")" 2>/dev/null\n'
        "    cat > \"$BUCKET_SYNC_PY\" <<'BUCKET_SYNC_PY_EOF'\n"
        f"{payload}"
        "BUCKET_SYNC_PY_EOF\n"
        "}\n"
        "ensure_bucket_sync_py() {\n"
        '    [ -s "$BUCKET_SYNC_PY" ] || write_bucket_sync_py\n'
        "}\n"
        f"{END}\n"
    )


def main() -> int:
    text = START.read_text()
    start = text.index(BEGIN)
    end = text.index(END, start) + len(END)
    new = text[:start] + block().rstrip("\n") + text[end:]
    if new == text:
        print("start.sh already up to date")
        return 0
    START.write_text(new)
    print(f"embedded {len(SOURCE.read_text())} bytes of bucket_sync.py into start.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
