#!/bin/bash
#
# Pull the server logs out of the Hugging Face bucket (the only place they can
# be read from outside the Space).
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
pull private-logs          # full /login lines + the hidden IPs
pull logs                  # raw paper.log / bungee.log, if they are synced

echo
for f in security-logs/logins.log security-logs/commands.log \
         security-logs/client-checks.log security-logs/shared-ips.txt \
         private-logs/auth.log private-logs/player-ips.log; do
    [ -s "$OUT/$f" ] && printf ' %-45s %s lines\n' "$f" "$(wc -l < "$OUT/$f")"
done

cat <<EOF

Read them with, for example:
  grep 'OTHER EAGLERCRAFT CLIENT' $OUT/security-logs/logins.log   # who else logged in
  tail -n 50 $OUT/security-logs/commands.log                      # last commands
  cat $OUT/private-logs/auth.log                                  # /login lines in full
  cat $OUT/private-logs/player-ips.log                            # IPs behind "hidden"
EOF
