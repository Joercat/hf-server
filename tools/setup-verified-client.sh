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
#   2b. optimises it for low-end machines: the assets (end portal texture,
#      animation frame counts) and the end portal's render pass count, which is
#      what makes a stronghold/End portal lag - see tools/optimize_client.py.
#      --portal-passes N (default 7, 0 = leave the stock layout, PORTAL_PASSES
#      in the environment) tunes the passes; the stock client draws up to 15.
#   3. writes .verified-client.env (the brand + UUID; git-ignored),
#   4. bakes the pair into start.sh *obfuscated* (XOR + base64, like the client
#      hides the brand behind a PBKDF2 verifier), so the server works without
#      any secrets and the values are still not readable in the repository,
#   5. prints the pair for the Space's "Variables and secrets" and the command
#      that puts the new client into the bucket.
#
# The environment always wins over the baked-in pair, so setting the secrets is
# optional; a rotation that leaves stale secrets behind is reported at boot.
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
OPTIMIZE=true
PORTAL_PASSES="${PORTAL_PASSES:-7}"      # see tools/optimize_client.py --portal-passes
BUCKET="${BUCKET:-hf://buckets/smodusermc/1.12}"

while [ $# -gt 0 ]; do
    case "$1" in
        --brand) BRAND="$2"; shift 2 ;;
        --rotate) ROTATE=true; shift ;;
        --stock) STOCK="$2"; shift 2 ;;
        --no-optimize) OPTIMIZE=false; shift ;;
        --portal-passes) PORTAL_PASSES="$2"; shift 2 ;;
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
mkdir -p "$(dirname "$OUT")"
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

# the patcher prints what it built; the file itself deliberately does not
# carry the brand in plain text (only a PBKDF2 verifier of it)
NEW_BRAND=$(sed -n 's/^ *brand *: *//p' <<<"$OUTPUT" | tail -1)
NEW_UUID=$(sed -n 's/^ *brandUUID *: *//p' <<<"$OUTPUT" | tail -1)
echo "  new brand    : $NEW_BRAND"
echo "  new UUID     : $NEW_UUID"

# --------------------------------------------------------------------------- #
# 2b. optimise the assets for low-end machines
# --------------------------------------------------------------------------- #
# The build above starts from the stock client, whose assets are not optimised:
# the end portal texture is 256x256 (drawn in up to 15 blended layers) and the
# animated blocks carry 32-frame strips.  Doing this here means every rebuilt
# client is optimised by construction, which the test suite asserts.
if [ "$OPTIMIZE" = true ]; then
    echo "Optimising the client (low-end devices)"
    OPT_OUT="${OUT}.optimizing"
    if python3 tools/optimize_client.py "$OUT" --user "$GATE_USER" --pass "$GATE_PASS" \
            --portal-passes "$PORTAL_PASSES" \
            --output "$OPT_OUT" 2>&1 | sed 's/^/  /'; then
        mv -f "$OPT_OUT" "$OUT"
    else
        rm -f "$OPT_OUT"
        echo "  warning: the optimisation step failed - the client itself is fine,"
        echo "           re-run it later with: python3 tools/optimize_client.py $OUT"
    fi
fi

# --------------------------------------------------------------------------- #
# 3. remember the pair locally (never committed)
# --------------------------------------------------------------------------- #
cat > "$ENV_FILE" <<EOF
# Identity of the verified client (read by start.sh, tests and tools).
# VER_CLIENT_USER / VER_CLIENT_PASS are what the gate asks for; they are here so
# that the local tools (optimize_client.py, the tests) work without flags.  This
# file is git-ignored - never commit it and never upload it anywhere.
# NEVER committed: the repository is public and a public brand can be copied
# into somebody else's client.
#
# On the Space these two values have to exist as *variables/secrets* with the
# same names (Space -> Settings -> Variables and secrets); start.sh then finds
# them in the environment and this file is not needed there at all.
VERIFIED_CLIENT_BRAND="$NEW_BRAND"
VERIFIED_CLIENT_UUID="$NEW_UUID"
VER_CLIENT_USER="$GATE_USER"
VER_CLIENT_PASS="$GATE_PASS"
EOF
echo "  wrote        : $ENV_FILE  (git-ignored)"

# --------------------------------------------------------------------------- #
# 3b. bake the pair into start.sh, obfuscated (XOR + base64)
# --------------------------------------------------------------------------- #
if [ -f start.sh ]; then
    BAKED=$(python3 - "$NEW_BRAND|$NEW_UUID" <<'PY'
import base64, os, sys
key = os.urandom(16)
blob = bytes(b ^ key[i % len(key)] for i, b in enumerate(sys.argv[1].encode()))
print(base64.b64encode(blob).decode())
print(key.hex())
PY
)
    B64=$(sed -n '1p' <<<"$BAKED"); KEY=$(sed -n '2p' <<<"$BAKED")
    if grep -q '^VERIFIED_CLIENT_PAIR_B64=' start.sh && grep -q '^VERIFIED_CLIENT_PAIR_KEY=' start.sh; then
        python3 - "$B64" "$KEY" <<'PY'
import pathlib, re, sys
p = pathlib.Path("start.sh")
s = p.read_text()
s = re.sub(r'^VERIFIED_CLIENT_PAIR_B64=".*"$', lambda m: 'VERIFIED_CLIENT_PAIR_B64="%s"' % sys.argv[1],
           s, count=1, flags=re.M)
s = re.sub(r'^VERIFIED_CLIENT_PAIR_KEY=".*"$', lambda m: 'VERIFIED_CLIENT_PAIR_KEY="%s"' % sys.argv[2],
           s, count=1, flags=re.M)
p.write_text(s)
PY
        echo "  baked        : start.sh (VERIFIED_CLIENT_PAIR_B64/_KEY, obfuscated)"
        echo "                 the Space gets it with the next tools/push-to-space.sh"
    else
        echo "  WARNING      : could not find the pair placeholders in start.sh - the"
        echo "                 built-in pair was NOT updated (the secrets still work)."
    fi
fi

if grep -qF "$NEW_BRAND" start.sh 2>/dev/null; then
    echo "  WARNING      : the brand is readable in start.sh - that should not happen."
fi

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

2. the client itself - it is committed in this repo now (the brand inside it
   cannot be read without the login), and it belongs in the bucket too:

     hf buckets cp $OUT $BUCKET/client/1.12.html

   The pair is also baked into start.sh (obfuscated) by this script, so the
   next push is enough - the secrets below are only needed to override it.

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
