#!/bin/bash
#
# Tests for the verified-client system:
#
#   1. the client in client/1.12.html really reports the brand that start.sh
#      expects (so client and server can never drift apart silently)
#   2. the log-parsing / detection helpers in start.sh classify console answers
#      from EaglerXBungee correctly (VERIFIED / UNVERIFIED / VANILLA)
#   3. the verified client is hidden in the logs (ip=hidden, no client=... tag)
#      while everyone else is logged with their IP
#   4. verified-only enforcement: everyone else is kicked (vanilla too), the
#      verified client and bypassed players are not, and an unresolved check
#      never kicks
#   5. /login, /register and friends are kept in full in private-logs/auth.log
#      for everybody except the verified client
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
check_at_least(){ if [ "${2:-0}" -ge "${3:-1}" ] 2>/dev/null; then ok "$1"; else bad "$1 (expected >= $3, got '$2')"; fi; }

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
export SHARED_REPORT="$WORK/shared-ips.txt"
export AUTH_LOG="$WORK/auth.log"
export IP_MAP_FILE="$WORK/player-ips.log"
export IP_MAP="$WORK/client-ips.txt"
export VERDICT_CACHE="$WORK/client-verdicts.txt"
export PENDING_AUTH="$WORK/pending-auth.tsv"
export AUTH_SEEN="$WORK/auth-seen.tsv"
export PRIV_DIR="$WORK/private"
mkdir -p "$PRIV_DIR"
export VERIFIED_CLIENT_BRAND="Eaglercraft[VER]"
export VERIFIED_CLIENT_UUID="51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"
export BUNGEE_CONSOLE="$FIFO"
export BUNGEE_PID_FILE="$PIDFILE"
export BUNGEE_CONSOLE_OK=true
export ENFORCE_VERIFIED_CLIENT=true
export ENFORCE_KICK_VANILLA=true
export ENFORCE_KICK_ON_UNKNOWN=false
export ENFORCE_BYPASS_PLAYERS=""
export HIDE_VERIFIED_IP=true
export PRIVATE_IP_LOG=true
export VERIFIED_CLIENT_KICK_MESSAGE="This server only allows the verified client."
export LOGIN_CLIENT_FIELD=""   # set by start.sh from HIDE_VERIFIED_IP
: > "$VERDICT_CACHE"; : > "$IP_MAP"; : > "$PENDING_AUTH"; : > "$AUTH_SEEN"
touch "$BLOG" "$CLIENT_LOG" "$LOGIN_LOG" "$CMD_LOG" "$AUTH_LOG" "$IP_MAP_FILE"
: > "$WORK/kicks"

extract() { awk "/^$1\(\) \{/,/^\}/" "$ROOT/start.sh"; }
FUNCS="$WORK/funcs.sh"
for f in strip_colours bungee_console bungee_alive query_client_brand check_player_client \
         last_ip_for mask_cmd is_auth_cmd queue_auth auth_seen_recently record_auth_seen \
         flush_pending_auth ip_field hide_ip_for client_field \
         set_verdict verdict_for verdict_label is_bypassed enforce_client_policy \
         shared_report_body report_shared_ips \
         handle_paper_line handle_bungee_line; do
    extract "$f"
done | sed "s|/tmp/bungee.log|$BLOG|g" > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

# capture kicks instead of talking to the server
mc_command() { printf '%s\n' "$*" >> "$WORK/kicks"; }
kick_count() { local n; n=$(grep -c "kick ${1:-}" "$WORK/kicks" 2>/dev/null); echo "${n:-0}"; }

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
stock_answer() { brand_answer "Eaglercraft 1.12" "522b2ce5-c9b9-36cf-be7c-5d90f55e631a"; }
vanilla_answer() { printf '12:00:00 [INFO] That player is not using eaglercraft!\n' > "$RESP"; }

login() { handle_paper_line "[12:00:01 INFO]: $1[/$2:5555] logged in with entity id 42 at (0.0, 0.0, 0.0)"; }
played() { handle_paper_line "[12:00:09 INFO]: $1 issued server command: $2"; }

brand_answer "Eaglercraft[VER]" "51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"
check "our client is VERIFIED" "$(query_client_brand CreppyBitch | cut -d'|' -f1)" "VERIFIED"

stock_answer
check "stock client is UNVERIFIED" "$(query_client_brand RandomGuy | cut -d'|' -f1)" "UNVERIFIED"

vanilla_answer
check "vanilla client is VANILLA" "$(query_client_brand Notch | cut -d'|' -f1)" "VANILLA"

# dead proxy -> CONSOLE_DOWN, never a false VERIFIED
rm -f "$PIDFILE"
check "dead proxy reports CONSOLE_DOWN" "$(query_client_brand Ghost | cut -d'|' -f1)" "CONSOLE_DOWN"
echo $MOCK_PID > "$PIDFILE"

# --------------------------------------------------------------------------- #
echo "== 3. the verified client is hidden, everybody else is logged =="
brand_answer "Eaglercraft[VER]" "51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"
login CreppyBitch 1.2.3.4
sleep 4.5
played CreppyBitch "/gamemode 1"
check "login recorded" "$(grep -c '| LOGIN | CreppyBitch' "$LOGIN_LOG")" "1"
check "the verified client's IP is hidden" "$(grep -c '| LOGIN | CreppyBitch | hidden$' "$LOGIN_LOG")" "1"
check "no client=... tag gives the verified client away" "$(grep -c '| LOGIN | CreppyBitch | hidden | client=' "$LOGIN_LOG")" "0"
check "no VERIFY line for the verified client" "$(grep -c '| VERIFY | CreppyBitch' "$LOGIN_LOG")" "0"
check "nothing about the verified client says VERIFIED CLIENT" "$(grep -c 'VERIFIED CLIENT' "$LOGIN_LOG")" "0"
check "client-checks.log keeps the verdict but hides the IP" \
      "$(grep -c '| VERIFIED | CreppyBitch | hidden |' "$CLIENT_LOG")" "1"
check "commands are logged, hidden and without a tag" \
      "$(grep -c '| CreppyBitch | hidden | /gamemode 1$' "$CMD_LOG")" "1"
check "the verified client is NOT kicked" "$(kick_count CreppyBitch)" "0"
check_at_least "the hidden IP was kept in private-logs/player-ips.log" \
      "$(grep -c '| CreppyBitch | 1.2.3.4' "$IP_MAP_FILE")" 1

# a stock Eaglercraft client: visible + kicked
stock_answer
login RandomGuy 5.6.7.8
sleep 4.5
played RandomGuy "/gamemode 1"
check "the stranger's login line is hidden too, the VERIFY line carries the IP" \
      "$(grep -c '5.6.7.8' "$LOGIN_LOG")" "1"
check "the stranger gets a VERIFY line with the real IP" \
      "$(grep -c '| VERIFY | RandomGuy | 5.6.7.8 | OTHER EAGLERCRAFT CLIENT |' "$LOGIN_LOG")" "1"
check "the stranger's commands are tagged" \
      "$(grep -c '| RandomGuy | 5.6.7.8 | /gamemode 1 | client=OTHER EAGLERCRAFT CLIENT$' "$CMD_LOG")" "1"
check "the stranger is kicked" "$(kick_count RandomGuy)" "1"

# a Java client
vanilla_answer
login Notch 9.9.9.9
sleep 4.5
check "the Java client gets a VERIFY line" \
      "$(grep -c '| VERIFY | Notch | 9.9.9.9 | JAVA CLIENT |' "$LOGIN_LOG")" "1"
check "the Java client is kicked (ENFORCE_KICK_VANILLA=true)" "$(kick_count Notch)" "1"

# a check that never resolves: logged, but not kicked
rm -f "$PIDFILE"
login Ghost 6.6.6.6
sleep 4.5
check "unresolved check is logged as UNKNOWN" \
      "$(grep -c '| VERIFY | Ghost | hidden | UNKNOWN CLIENT |' "$LOGIN_LOG")" "1"
check "unresolved check does not kick" "$(kick_count Ghost)" "0"
echo $MOCK_PID > "$PIDFILE"

# policy units
before=$(wc -l < "$WORK/kicks")
( ENFORCE_KICK_ON_UNKNOWN=true; enforce_client_policy Ghost UNKNOWN; ) >/dev/null
check "ENFORCE_KICK_ON_UNKNOWN=true kicks unresolved players" "$(( $(wc -l < "$WORK/kicks") - before ))" "1"
before=$(wc -l < "$WORK/kicks")
( ENFORCE_BYPASS_PLAYERS="Ghost"; enforce_client_policy Ghost UNVERIFIED; ) >/dev/null
check "a bypassed player is not kicked" "$(wc -l < "$WORK/kicks")" "$before"
before=$(wc -l < "$WORK/kicks")
( enforce_client_policy CreppyBitch UNVERIFIED; ) >/dev/null
check "the kick message is the configured one" "$(tail -1 "$WORK/kicks")" \
      "kick CreppyBitch This server only allows the verified client."

# hiding turned off puts everything back
check "HIDE_VERIFIED_IP=false shows the IP again" \
      "$( HIDE_VERIFIED_IP=false; ip_field CreppyBitch 1.2.3.4 VERIFIED )" "1.2.3.4"
check "HIDE_VERIFIED_IP=false brings the client= tag back" \
      "$( HIDE_VERIFIED_IP=false; client_field VERIFIED )" " | client=VERIFIED CLIENT"
check "client= tags for others are unaffected by the hiding" \
      "$( client_field UNVERIFIED )" " | client=OTHER EAGLERCRAFT CLIENT"
check "an unresolved verdict gets no tag either (nothing points at the owner)" \
      "$( client_field UNKNOWN )" ""

# --------------------------------------------------------------------------- #
echo "== 4. full /login logging except for the verified client =="
check "is_auth_cmd knows /login" "$(is_auth_cmd '/login hunter2' && echo yes)" "yes"
check "is_auth_cmd knows /register" "$(is_auth_cmd '/register hunter2 hunter2' && echo yes)" "yes"
check "is_auth_cmd knows /changepassword" "$(is_auth_cmd '/changepassword a b' && echo yes)" "yes"
check "is_auth_cmd does not match normal commands" "$(is_auth_cmd '/gamemode 1' || echo no)" "no"

# the owner: password never written down
played CreppyBitch "/login ownersecret"
sleep 0.3
check "the verified client's /login is not logged in full" "$(grep -c 'ownersecret' "$AUTH_LOG")" "0"
check "the verified client's /login is not queued" "$(wc -l < "$PENDING_AUTH")" "0"
check "the verified client's /login is masked in commands.log" \
      "$(grep -c '| CreppyBitch | hidden | /login \*\*\*\*\*\*\*\*$' "$CMD_LOG")" "1"

# a stranger whose verdict is already known: logged immediately, in full
played RandomGuy "/login strangerpass"
sleep 0.3
check "the stranger's /login is kept in full in private-logs/auth.log" \
      "$(grep -c '| RandomGuy | 5.6.7.8 | /login strangerpass | client=OTHER EAGLERCRAFT CLIENT$' "$AUTH_LOG")" "1"
check "the stranger's /login is masked in commands.log" \
      "$(grep -c '/login \*\*\*\*\*\*\*\*' "$CMD_LOG")" "2"

# a stranger still PENDING: queued, then written when the verdict arrives
stock_answer
login LateGuy 7.7.7.7
played LateGuy "/register latepass latepass"
sleep 0.3
check "a pending /register waits in the queue" "$(grep -c 'latepass' "$PENDING_AUTH")" "1"
sleep 4.5
check "the queued /register is logged once the verdict is known" \
      "$(grep -c '| LateGuy | 7.7.7.7 | /register latepass latepass | client=OTHER EAGLERCRAFT CLIENT$' "$AUTH_LOG")" "1"
check "the queue is empty again" "$(wc -l < "$PENDING_AUTH")" "0"
check "no password of the verified client ever reaches auth.log" \
      "$(grep -cE 'ownersecret|hunter2' "$AUTH_LOG")" "0"

# Bungee logs the same command again -> must not duplicate it
played_bungee() { handle_bungee_line "12:00:10 [INFO] $1 executed command: $2"; }
played_bungee RandomGuy "/login strangerpass"
check "the Paper+Bungee duplicate is written only once" \
      "$(grep -c 'strangerpass' "$AUTH_LOG")" "1"

# --------------------------------------------------------------------------- #
echo "== 5. reports =="
report_shared_ips
check "the synced shared-IP report hides the verified client's IP" \
      "$(grep -c '1\.2\.3\.4' "$SHARED_REPORT")" "0"
check "the report counts the verdicts" "$(grep -c 'UNVERIFIED: ' "$SHARED_REPORT")" "1"
check_at_least "private-logs/shared-ips-private.txt has the real IPs" \
      "$(grep -c '1\.2\.3\.4' "$PRIV_DIR/shared-ips-private.txt")" 1
check "private-logs/logins-real-ips.log has no 'hidden' left" \
      "$(grep -c 'hidden' "$PRIV_DIR/logins-real-ips.log")" "0"

for pair in "VERIFIED:VERIFIED CLIENT" "UNVERIFIED:OTHER EAGLERCRAFT CLIENT" \
            "VANILLA:JAVA CLIENT" "PENDING:CHECK PENDING" "GARBAGE:UNKNOWN CLIENT"; do
    check "label for ${pair%%:*} is right" "$(verdict_label "${pair%%:*}")" "${pair#*:}"
done

if [ "${PRINT_LOGS:-0}" = "1" ]; then
    echo
    echo "############ security-logs/logins.log"
    cat "$LOGIN_LOG"
    echo
    echo "############ security-logs/commands.log"
    cat "$CMD_LOG"
    echo
    echo "############ security-logs/client-checks.log"
    cat "$CLIENT_LOG"
    echo
    echo "############ private-logs/auth.log   (full passwords, never synced)"
    cat "$AUTH_LOG"
    echo
    echo "############ private-logs/player-ips.log   (the IPs hidden above)"
    sort -u "$IP_MAP_FILE"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
