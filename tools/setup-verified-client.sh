#!/bin/bash
#
# Build (or rotate) the verified client, in one command, and print exactly what
# has to go where.
#
#   bash tools/setup-verified-client.sh --brand "AnotherBrand16Ch" \
#        --gate-user <user> --gate-pass '<password>' 
#   bash tools/setup-verified-client.sh --rotate --gate-user <user> --gate-pass '<password>' 
#   bash tools/setup-verified-client.sh --rotate --gate-user <user>         # asks for the password
#   bash tools/setup-verified-client.sh --rotate --gate-user <user> --upload  # + puts it in the bucket
#
# What it does:
#   1. finds a stock Eaglercraft 1.12 client (git history / --stock FILE),
#   2. rebuilds client/1.12.html with the new brand + the login gate,
#   3. writes .verified-client.env (the brand + UUID; never committed),
#   4. prints the two values for the Space's "Variables and secrets" and the
#      command that puts the new client into the bucket.
#
# Nothing is committed and nothing is written into start.sh: the pair belongs
# in the Space secrets, because this repository is public and a brand that is
# public can be copied into anybody's client and then shows up as "verified".
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

BRAND=""
ROTATE=false
STOCK=""
GATE_USER=""
GATE_PASS=""
OUT="client/1.12.html"
ENV_FILE=".verified-client.env"
UPLOAD=false
BUCKET="${BUCKET:-hf://buckets/smodusermc/1.12}"

while [ $# -gt 0 ]; do
    case "$1" in
        --brand) BRAND="$2"; shift 2 ;;
        --rotate) ROTATE=true; shift ;;
        --stock) STOCK="$2"; shift 2 ;;
        --gate-user) GATE_USER="$2"; shift 2 ;;
        --gate-pass) GATE_PASS="$2"; shift 2 ;;
        --output) OUT="$2"; shift 2 ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --upload) UPLOAD=true; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)"; exit 2 ;;
    esac
done

if [ -z "$BRAND" ] && [ "$ROTATE" != true ]; then
    echo "ERROR: pass --brand \"<exactly 16 chars>\" or --rotate (fresh random brand)."
    exit 2
fi
[ -n "$GATE_USER" ] || { echo "ERROR: --gate-user <username> is required (the client's login)."; exit 2; }

# --------------------------------------------------------------------------- #
# 1. a stock client to build from
# --------------------------------------------------------------------------- #
find_stock() {
    if [ -n "$STOCK" ]; then
        [ -s "$STOCK" ] || { echo "ERROR: $STOCK does not exist" >&2; exit 1; }
        printf '%s' "$STOCK"; return 0
    fi
    if [ -s /tmp/stock-1.12.html ]; then printf '%s' /tmp/stock-1.12.html; return 0; fi
    # the original (un-patched) client in git: the newest commit that still has
    # it as a plain, ungated file
    local sha
    sha=$(git rev-list --all -- client/1.12.html 2>/dev/null | tail -1)
    if [ -n "$sha" ]; then
        git show "$sha:client/1.12.html" > /tmp/stock-1.12.html 2>/dev/null \
            && [ -s /tmp/stock-1.12.html ] \
            && ! grep -q "verified-client gate" /tmp/stock-1.12.html \
            && { echo "  stock client : from git $sha" >&2; printf '%s' /tmp/stock-1.12.html; return 0; }
    fi
    return 1
}

STOCK_FILE=$(find_stock) || {
    echo "ERROR: no stock Eaglercraft 1.12 client found."
    echo "       Pass one with --stock <file> (an unpatched client/1.12.html)."
    exit 1
}

if grep -q "verified-client gate" "$STOCK_FILE" 2>/dev/null; then
    echo "ERROR: $STOCK_FILE already carries the login gate."
    echo "       Build from an unpatched client (--stock FILE), i.e. one that still"
    echo "       has the plain assetsURI data URI the patcher rewrites."
    exit 1
fi

# --------------------------------------------------------------------------- #
# 2. build
# --------------------------------------------------------------------------- #
echo "Building the verified client"
[ -n "$BRAND" ] && echo "  brand        : $BRAND"
[ "$ROTATE" = true ] && echo "  brand        : rotating (random, never used before)"

ARGS=(--output "$OUT" --gate-user "$GATE_USER")
[ -n "$GATE_PASS" ] && ARGS+=(--gate-pass "$GATE_PASS")
[ "$ROTATE" = true ] && ARGS+=(--rotate) || ARGS+=(--brand "$BRAND")

OUTPUT=$(python3 tools/patch_verified_client.py "$STOCK_FILE" "${ARGS[@]}") || {
    echo "$OUTPUT"
    echo "build failed"
    exit 1
}
echo "$OUTPUT" | sed -n 's/^\[+\]/  /p'
echo "$OUTPUT" | tail -6 | sed 's/^/  /'

NEW_BRAND=$(python3 - "$OUT" <<'PY'
import re, sys
# the marker sits at the very end of the file (the sealed payload is in front
# of it), so read the tail instead of the head
text = open(sys.argv[1], "rb").read()[-65536:].decode("utf-8", "replace")
m = re.search(r'brand: "([^"]*)", uuid: "([^"]*)"', text)
print(m.group(1) if m else "")
PY
)
NEW_UUID=$(python3 - "$OUT" <<'PY'
import re, sys
text = open(sys.argv[1], "rb").read()[-65536:].decode("utf-8", "replace")
m = re.search(r'brand: "([^"]*)", uuid: "([^"]*)"', text)
print(m.group(2) if m else "")
PY
)
echo "  new brand    : $NEW_BRAND"
echo "  new UUID     : $NEW_UUID"

# --------------------------------------------------------------------------- #
# 3. remember the pair locally (never committed)
# --------------------------------------------------------------------------- #
cat > "$ENV_FILE" <<EOF
# Identity of the verified client (read by start.sh, tests and tools).
# NEVER committed: the repository is public and a public brand can be copied
# into somebody else's client.
#
# On the Space these two values have to exist as *variables/secrets* with the
# same names (Space -> Settings -> Variables and secrets); start.sh then finds
# them in the environment and this file is not needed there at all.
VERIFIED_CLIENT_BRAND="$NEW_BRAND"
VERIFIED_CLIENT_UUID="$NEW_UUID"
EOF
echo "  wrote        : $ENV_FILE  (git-ignored)"

# --------------------------------------------------------------------------- #
# 4. what to do with it
# --------------------------------------------------------------------------- #
cat <<EOF

Now put it in the two places that matter

1. Space -> Settings -> Variables and secrets, add BOTH (any values you like,
   "secret" is fine, the Space only needs to see them at boot):

     VERIFIED_CLIENT_BRAND = $NEW_BRAND
     VERIFIED_CLIENT_UUID  = $NEW_UUID

   Without them the server marks nobody as the verified client - and since it
   then cannot tell your own /login from anybody else's, it masks every
   password until the pair is set (the boot log says so).

2. the client itself, in the private bucket (never in this public repo):

     hf buckets cp $OUT $BUCKET/client/1.12.html

The login of the client itself did not change: username "$GATE_USER".
EOF
[ "$UPLOAD" = true ] && {
    echo
    if command -v hf >/dev/null 2>&1; then
        hf buckets cp "$OUT" "$BUCKET/client/1.12.html" && \
            echo "uploaded: $BUCKET/client/1.12.html"
    else
        echo "hf CLI not found - upload it by hand (or hf auth login first)."
    fi
}
