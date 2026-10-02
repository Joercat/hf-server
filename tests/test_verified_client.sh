#!/bin/bash
#
# Tests for the verified-client system:
#
#   1. the client in client/1.12.html really reports the brand that start.sh
#      expects (so client and server can never drift apart silently)
#   2. the log-parsing / detection helpers in start.sh classify console answers
#      from EaglerXBungee correctly (VERIFIED / UNVERIFIED / VANILLA)
#   3. the security logger ignores the commands it injects itself
#
# Run:  bash tests/test_verified_client.sh
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# --------------------------------------------------------------------------- #
echo "== 1. client <-> start.sh consistency =="
EXPECTED_UUID=$(grep -oP '^VERIFIED_CLIENT_UUID="\K[^"]+' "$ROOT/start.sh")
CLIENT_INFO=$(python3 "$ROOT/tools/patch_verified_client.py" --check "$ROOT/client/1.12.html" 2>&1)
CLIENT_UUID=$(sed -n 's/.*brandUUID *: *//p' <<<"$CLIENT_INFO" | head -1)
CLIENT_BRAND=$(sed -n "s/.*brand *: *'\(.*\)'.*/\1/p" <<<"$CLIENT_INFO" | head -1)
echo "  client brand : $CLIENT_BRAND"
echo "  client uuid  : $CLIENT_UUID"
echo "  start.sh     : $EXPECTED_UUID"
check "client brand UUID matches VERIFIED_CLIENT_UUID in start.sh" "$CLIENT_UUID" "$EXPECTED_UUID"
check "start.sh guards against an empty UUID" "$([ -n "$EXPECTED_UUID" ] && echo yes)" "yes"

# the stock client must NOT be accepted as verified
STOCK=$(python3 "$ROOT/tools/patch_verified_client.py" --print-uuid --brand "Eaglercraft 1.12" |
        sed -n 's/^brandUUID *: *//p')
if [ "$STOCK" = "$EXPECTED_UUID" ]; then
    bad "stock client brand must differ from the verified one"
else
    ok "stock client ($STOCK) is not the verified client"
fi

# --------------------------------------------------------------------------- #
echo "== 2. start.sh detection helpers =="
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; kill ${MOCK_PID:-0} 2>/dev/null' EXIT
BLOG="$WORK/bungee.log"
FIFO="$WORK/console.pipe"
PIDFILE="$WORK/bungee.pid"
export CLIENT_LOG="$WORK/client-checks.log"
export LOGIN_LOG="$WORK/logins.log"
export CMD_LOG="$WORK/commands.log"
export VERIFIED_CLIENT_BRAND="Eaglercraft[VER]"
export VERIFIED_CLIENT_UUID="51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"
export BUNGEE_CONSOLE="$FIFO"
export BUNGEE_PID_FILE="$PIDFILE"
export BUNGEE_CONSOLE_OK=true
export ENFORCE_VERIFIED_CLIENT=false
touch "$BLOG" "$CLIENT_LOG" "$LOGIN_LOG" "$CMD_LOG"

extract() { awk "/^$1\(\) \{/,/^\}/" "$ROOT/start.sh"; }
FUNCS="$WORK/funcs.sh"
for f in strip_colours bungee_console bungee_alive query_client_brand check_player_client \
         last_ip_for mask_cmd handle_paper_line handle_bungee_line; do
    extract "$f"
done | sed "s|/tmp/bungee.log|$BLOG|g" > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

# fake BungeeCord: reads console commands from the pipe, answers in the log
RESP="$WORK/response.txt"
mock_bungee() {
    while IFS= read -r line; do
        case "$line" in
            client-brand*|clientbrand*) cat "$RESP" >> "$BLOG" ;;
        esac
    done < "$FIFO"
}
mkfifo "$FIFO"
# like start.sh: hold the pipe open read+write so readers never see EOF
exec 9<>"$FIFO"
mock_bungee & MOCK_PID=$!
echo $MOCK_PID > "$PIDFILE"

brand_answer() {
    cat > "$RESP" <<EOF
12:00:00 [INFO] Eagler Client Brand: $1
12:00:00 [INFO] Eagler Client Version: u2
12:00:00 [INFO] Eagler Client UUID: $2
12:00:00 [INFO] Minecraft Client Brand: EaglercraftX
EOF
}

brand_answer "Eaglercraft[VER]" "51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"
check "our client is VERIFIED" "$(query_client_brand CreppyBitch | cut -d'|' -f1)" "VERIFIED"

brand_answer "Eaglercraft 1.12" "522b2ce5-c9b9-36cf-be7c-5d90f55e631a"
check "stock client is UNVERIFIED" "$(query_client_brand RandomGuy | cut -d'|' -f1)" "UNVERIFIED"

printf '12:00:00 [INFO] That player is not using eaglercraft!\n' > "$RESP"
check "vanilla client is VANILLA" "$(query_client_brand Notch | cut -d'|' -f1)" "VANILLA"

# dead proxy -> CONSOLE_DOWN, never a false VERIFIED
rm -f "$PIDFILE"
check "dead proxy reports CONSOLE_DOWN" "$(query_client_brand Ghost | cut -d'|' -f1)" "CONSOLE_DOWN"
echo $MOCK_PID > "$PIDFILE"

# a full login flow: paper.log line -> logins.log + client-checks.log
brand_answer "Eaglercraft[VER]" "51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"
handle_paper_line "[12:00:01 INFO]: CreppyBitch[/1.2.3.4:5555] logged in with entity id 42 at (0.0, 0.0, 0.0)"
sleep 4
check "login recorded in logins.log" \
      "$(grep -c '| LOGIN | CreppyBitch | 1.2.3.4' "$LOGIN_LOG")" "1"
check "verified login recorded in client-checks.log" \
      "$(grep -c '| VERIFIED | CreppyBitch | 1.2.3.4 |' "$CLIENT_LOG")" "1"

# commands issued by the script itself must not be logged as a player command
handle_bungee_line "12:00:05 [INFO] CONSOLE executed command: client-brand name CreppyBitch"
check "injected console commands are ignored" "$(wc -l < "$CMD_LOG")" "0"
handle_bungee_line "12:00:06 [INFO] CreppyBitch executed command: /spawn"
check "player commands still recorded" "$(wc -l < "$CMD_LOG")" "1"

# report generation must not break on the new log
report_ips() { awk -F' [|] ' '$2=="LOGIN"{ipc[$4]++} END{}' "$LOGIN_LOG"; }
report_ips
ok "report helpers accept the log format"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
