#!/bin/bash
#
# Download the curated server logs from the Hugging Face bucket:
#
#   bash tools/fetch-logs.sh                    # -> ./server-logs/
#   bash tools/fetch-logs.sh my-logs            # -> ./my-logs/
#   bash tools/fetch-logs.sh my-logs hf://buckets/smodusermc/1.12/game-data
#
set -uo pipefail

OUT="${1:-server-logs}"
BUCKET="${2:-hf://buckets/smodusermc/1.12/game-data}"

mkdir -p "$OUT"

pull() {   # $1 = remote subfolder
    local dir="$OUT/$1"
    mkdir -p "$dir"
    if hf buckets sync "$BUCKET/$1" "$dir" >/dev/null 2>&1; then
        echo "  ok   $BUCKET/$1"
    else
        echo "  --   $BUCKET/$1 (not there yet?)"
    fi
}

echo "Downloading logs to $OUT ..."
pull security-logs
pull private-logs          # full /login lines + real IP history; keep this private
pull logs                  # combined masked Paper/Bungee snapshot

echo
for f in security-logs/activity.log security-logs/addresses.txt \
         security-logs/status.txt private-logs/auth.log \
         private-logs/addresses.log private-logs/addresses.txt \
         logs/console.log; do
    [ -s "$OUT/$f" ] && printf ' %-40s %s lines\n' "$f" "$(wc -l < "$OUT/$f")"
done

cat <<EOF

All curated timestamps use America/New_York (EST/EDT), a 12-hour clock, and
one dated divider per day. The private folder contains full passwords and IPs;
keep it private.

Read them with, for example:
  grep '| LOGIN |' $OUT/security-logs/activity.log       # player joins
  grep '| COMMAND |' $OUT/security-logs/activity.log     # commands (auth passwords masked)
  grep 'VERIFIED CLIENT' $OUT/security-logs/activity.log # your marked client
  cat $OUT/private-logs/auth.log                         # other players' full auth commands
  cat $OUT/security-logs/addresses.txt                   # public address report
  cat $OUT/security-logs/status.txt                      # logger health
EOF
