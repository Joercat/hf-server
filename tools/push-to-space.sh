#!/bin/bash
#
# Push only the files the Hugging Face Space actually needs.
#
#   bash tools/push-to-space.sh                  # smodusermc/12, minimal upload
#   bash tools/push-to-space.sh --with-readme    # also update the Space card
#   bash tools/push-to-space.sh --with-client    # also put the private client in the bucket
#   SPACE=someone/else bash tools/push-to-space.sh
#
# Needs the `hf` CLI (`pip install "huggingface_hub[cli]"`) and `hf auth login`
# with a token that can write to the Space.
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPACE="${SPACE:-smodusermc/12}"
BUCKET="${BUCKET:-hf://buckets/smodusermc/1.12}"
WITH_README=false
WITH_CLIENT=false

for arg in "$@"; do
    case "$arg" in
        --with-readme) WITH_README=true ;;
        --with-client) WITH_CLIENT=true ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (see --help)"; exit 2 ;;
    esac
done

command -v hf >/dev/null 2>&1 || {
    echo "ERROR: the 'hf' CLI is not installed."
    echo "       pip install \"huggingface_hub[cli]\"  &&  hf auth login"
    exit 1
}

# The Space needs exactly two files. Everything else is development material:
#  - Dockerfile  (must replace the old one; it no longer copies client/)
#  - start.sh    (server logic, logging, enforcement, bucket syncs)
# plugins/, config/bungee/*.jar and .gitattributes already exist on the Space
# and must stay as they are (they are LFS-tracked there).
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$ROOT/Dockerfile" "$ROOT/start.sh" "$STAGE/"
[ "$WITH_README" = true ] && cp "$ROOT/README.md" "$STAGE/"

echo "Uploading to $SPACE:"
ls -1 "$STAGE" | sed 's/^/  /'
echo

# one upload = one commit = one Space rebuild
if hf upload "$SPACE" "$STAGE" . --repo-type space; then
    echo
    echo "ok - the Space will rebuild itself (watch its Logs tab)."
    echo "    the console the build/run produces is mirrored to:"
    echo "      $BUCKET/game-data/logs/paper.log"
    echo "      $BUCKET/game-data/logs/bungee.log"
else
    echo
    echo "upload failed - run 'hf auth login' with a token that can write to $SPACE"
    exit 1
fi

if [ "$WITH_CLIENT" = true ]; then
    echo
    echo "Publishing the private client to the bucket (NOT the public Space repo):"
    if hf buckets cp "$ROOT/client/1.12.html" "$BUCKET/client/1.12.html"; then
        echo "  $BUCKET/client/1.12.html"
        echo "  download it again any time with:"
        echo "    hf buckets cp $BUCKET/client/1.12.html ./1.12.html"
    else
        echo "  failed - check that you can write to $BUCKET"
    fi
fi
