#!/bin/bash
#
# Tests for the verified-client system:
#
#   1. the client in client/1.12.html really reports the brand that start.sh
#      expects (so client and server can never drift apart silently)
#   2. the log-parsing / detection helpers in start.sh classify console answers
#      from EaglerXBungee correctly (VERIFIED / UNVERIFIED / VANILLA)
#   3. the verified client's IP/brand/UUID are hidden while the explicit
#      VERIFIED CLIENT marker is retained; everyone else's resolved IP is logged
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
export TZ=America/New_York LC_ALL=C
PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
check_at_least(){ if [ "${2:-0}" -ge "${3:-1}" ] 2>/dev/null; then ok "$1"; else bad "$1 (expected >= $3, got '$2')"; fi; }

# --------------------------------------------------------------------------- #
echo "== 1. the client, and the pair that identifies it =="
# The pair is never written down in readable text: start.sh carries it XOR'd +
# base64, the client only carries a PBKDF2 verifier of the brand, and both can
# be overridden by the environment (Space secrets) or .verified-client.env.
BUILTIN_B64=$(sed -n 's/^VERIFIED_CLIENT_PAIR_B64="\(.*\)"$/\1/p' "$ROOT/start.sh" | head -1)
BUILTIN_KEY=$(sed -n 's/^VERIFIED_CLIENT_PAIR_KEY="\(.*\)"$/\1/p' "$ROOT/start.sh" | head -1)
decode_pair() {
    python3 -c '
import base64, sys
blob = base64.b64decode(sys.argv[1])
key = bytes.fromhex(sys.argv[2])
sys.stdout.write(bytes(b ^ key[i % len(key)] for i, b in enumerate(blob)).decode("utf-8"))
' "$1" "$2"
}
BUILTIN_PAIR=$(decode_pair "$BUILTIN_B64" "$BUILTIN_KEY" 2>/dev/null)
BUILTIN_BRAND="${BUILTIN_PAIR%%|*}"
BUILTIN_UUID="${BUILTIN_PAIR##*|}"

check "start.sh carries an obfuscated pair that decodes" \
      "$([ -n "$BUILTIN_BRAND" ] && [ -n "$BUILTIN_UUID" ] && [ "$BUILTIN_BRAND" != "$BUILTIN_PAIR" ] && echo yes)" "yes"
check "…and it is not readable in start.sh" \
      "$([ -n "$BUILTIN_BRAND" ] && grep -qF "$BUILTIN_BRAND" "$ROOT/start.sh" && echo readable || echo hidden)" "hidden"

[ -z "${VERIFIED_CLIENT_BRAND:-}" ] && [ -s "$ROOT/.verified-client.env" ] && \
    . "$ROOT/.verified-client.env"
EXPECTED_BRAND="${VERIFIED_CLIENT_BRAND:-$BUILTIN_BRAND}"
EXPECTED_UUID="${VERIFIED_CLIENT_UUID:-$BUILTIN_UUID}"
echo "  brand        : $EXPECTED_BRAND"
echo "  uuid         : $EXPECTED_UUID"

check "the built-in pair and the configured pair are the same client" \
      "$(skip=no; if [ -s "$ROOT/.verified-client.env" ]; then
             [ "$EXPECTED_BRAND" = "$BUILTIN_BRAND" ] && [ "$EXPECTED_UUID" = "$BUILTIN_UUID" ] && echo same || echo different
         else echo same; fi)" "same"

# that pair must never have been public
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    HITS=$(git -C "$ROOT" log --all --format=%h -S"$EXPECTED_BRAND" 2>/dev/null | head -3)
    HITS="$HITS $(git -C "$ROOT" log --all --format=%h -S"$EXPECTED_UUID" 2>/dev/null | head -3)"
    check "the pair never appears in git history" "$(echo $HITS | tr -d ' ')" ""
    check "client/1.12.html is committed (it is the client you hand out)" \
          "$(git -C "$ROOT" ls-files --error-unmatch client/1.12.html >/dev/null 2>&1 && echo tracked || echo untracked)" \
          "tracked"
    check "…and does not leak the brand" \
          "$(grep -qF "$EXPECTED_BRAND" "$ROOT/client/1.12.html" && echo leaks || echo hidden)" "hidden"
    check ".verified-client.env stays out of the repository" \
          "$(git -C "$ROOT" check-ignore -q .verified-client.env && echo ignored || echo not-ignored)" "ignored"
    check "…and is not tracked" \
          "$(git -C "$ROOT" ls-files --error-unmatch .verified-client.env >/dev/null 2>&1 && echo tracked || echo untracked)" \
          "untracked"
else
    echo "  skip - not a git checkout, cannot check the history"
fi

if [ ! -s "$ROOT/client/1.12.html" ]; then
    echo "  skip - client/1.12.html is not built here (tools/setup-verified-client.sh)"
else
    # without the credentials: the file's own verifier says whether this is the
    # configured brand
    VERIFY=$(python3 "$ROOT/tools/patch_verified_client.py" --check "$ROOT/client/1.12.html" \
             --expect-brand "$EXPECTED_BRAND" 2>&1)
    check "the client's brand verifier matches the configured brand" \
          "$(grep -c 'matches   : YES' <<<"$VERIFY")" "1"
    check "…and the file keeps the brand hidden" \
          "$(grep -c 'brand     : hidden' <<<"$VERIFY")" "1"
    check "the client carries the login gate" \
          "$(grep -c 'verified-client gate' "$ROOT/client/1.12.html")" "1"

    if [ -n "${VER_CLIENT_USER:-}" ] && [ -n "${VER_CLIENT_PASS:-}" ]; then
        # with the credentials: the real brand inside the sealed payload
        CLIENT_INFO=$(python3 "$ROOT/tools/patch_verified_client.py" --check "$ROOT/client/1.12.html" \
                      --gate-user "$VER_CLIENT_USER" --gate-pass "$VER_CLIENT_PASS" 2>&1)
        CLIENT_BRAND=$(sed -n "s/.*brand     : '\(.*\)'.*/\1/p" <<<"$CLIENT_INFO" | head -1)
        CLIENT_UUID=$(sed -n 's/.*brandUUID *: *//p' <<<"$CLIENT_INFO" | head -1)
        check "the payload's real brand is the configured one" "$CLIENT_BRAND" "$EXPECTED_BRAND"
        check "…and its brand UUID is the configured one" "$CLIENT_UUID" "$EXPECTED_UUID"
        check "the file's verifier agrees with the payload" \
              "$(grep -c 'verifier  : matches the brand in the payload' <<<"$CLIENT_INFO")" "1"
    else
        echo "  skip - set VER_CLIENT_USER / VER_CLIENT_PASS to read the brand inside the payload"
    fi

    for BURNED in "Eaglercraft 1.12" "Eaglercraft[VER]" "EaglercraftX[V2]" "EaglercraftX[SV]"; do
        if [ "$BURNED" = "$EXPECTED_BRAND" ]; then
            bad "the client must not use the burned brand '$BURNED'"
        else
            ok "burned brand '$BURNED' is not the verified client"
        fi
    done
fi

# a brand that is already public must be refused by the builder
REFUSED=$(python3 "$ROOT/tools/patch_verified_client.py" --brand "Eaglercraft[VER]" \
          /dev/null --output /tmp/should-not-exist.html 2>&1)
check "the builder refuses a public (revoked) brand" \
      "$(grep -c 'refusing brand' <<<"$REFUSED")" "1"

echo "== 2. start.sh detection helpers =="
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; kill ${MOCK_PID:-0} 2>/dev/null' EXIT
BLOG="$WORK/bungee.log"
FIFO="$WORK/console.pipe"
PIDFILE="$WORK/bungee.pid"
export ACTIVITY_LOG="$WORK/activity.log"
export CLIENT_LOG="$WORK/client-checks.log"
export LOGIN_LOG="$WORK/logins.log"
export CMD_LOG="$WORK/commands.log"
export ADDRESS_REPORT="$WORK/security/addresses.txt"
export STATUS_FILE="$WORK/security/status.txt"
export PRIVATE_ADDRESS_REPORT="$WORK/private/addresses.txt"
export AUTH_LOG="$WORK/auth.log"
export IP_MAP_FILE="$WORK/addresses.log"
export VERIFIED_PLAYER_STATE="$WORK/verified-players.txt"
export REPORT_STATE="$WORK/report-last-update"
export REPORT_INTERVAL=0
export BUCKET_SYNC_LOCK="$WORK/bucket-sync.lock"
export LOG_MIGRATOR_PY="$WORK/log_migrate.py"
export BG_PRIORITY=()
export IP_MAP="$WORK/client-ips.txt"
export VERDICT_CACHE="$WORK/client-verdicts.txt"
export PENDING_AUTH="$WORK/pending-auth.tsv"
export AUTH_SEEN="$WORK/auth-seen.tsv"
export PRIV_DIR="$WORK/private"
export SEC_DIR="$WORK/security"
mkdir -p "$PRIV_DIR" "$SEC_DIR"
export VERIFIED_CLIENT_BRAND="TestBrand[...]"   # never in this repo: the tests
export VERIFIED_CLIENT_UUID="$(python3 "$ROOT/tools/patch_verified_client.py" \
        --print-uuid --brand "TestBrand[...]" | sed -n 's/^brandUUID *: *//p')"
export VERIFIED_CLIENT_CONFIGURED=true
export VERIFIED_CLIENT_PUBLISHED=false
PUBLISHED_CLIENT_BRANDS=$(sed -n 's/^PUBLISHED_CLIENT_BRANDS="\(.*\)"$/\1/p' "$ROOT/start.sh")
export PUBLISHED_CLIENT_BRANDS
export BUNGEE_CONSOLE="$FIFO"
export BUNGEE_PID_FILE="$PIDFILE"
export BUNGEE_CONSOLE_OK=true
export ENFORCE_VERIFIED_CLIENT=true
export ENFORCE_KICK_VANILLA=true
export ENFORCE_KICK_ON_UNKNOWN=false
export ENFORCE_BYPASS_PLAYERS=""
export HIDE_VERIFIED_IP=true
export PRIVATE_IP_LOG=true
export SYNC_CONSOLE_LOGS=false   # turned on in section 6

export VERIFIED_CLIENT_KICK_MESSAGE="This server only allows the verified client."
export ONLINE_STATE="$WORK/online-players.txt"
export PLAYERLIST_POLL=1
export SCRIPT_VERSION="test"
export BUCKET_METHOD="auto"
export BUCKET_SYNC_PY="$WORK/bucket_sync.py"
export BUCKET_VIA=""
export BUCKET_ERROR=""
export LOGIN_CLIENT_FIELD=" | client=CHECK PENDING"
export PROXY_PEERS_PY="$WORK/proxy_peers.py"
export PROXY_PEERS_STATE="$WORK/proxy-peers.log"
export GAME_PORT=7860
export FORWARD_IP_RETRY_INTERVAL=600
export FORWARD_IP_STATE="$WORK/forward-ip.state"
: > "$VERDICT_CACHE"; : > "$IP_MAP"; : > "$PENDING_AUTH"; : > "$AUTH_SEEN"
touch "$BLOG" "$ACTIVITY_LOG" "$CLIENT_LOG" "$LOGIN_LOG" "$CMD_LOG" "$AUTH_LOG" "$IP_MAP_FILE"
: > "$WORK/kicks"

extract() { awk "/^$1\(\) \{/,/^\}/" "$ROOT/start.sh"; }
FUNCS="$WORK/funcs.sh"
for f in strip_colours bungee_console bungee_alive query_client_brand check_player_client \
         is_real_ip record_ip restore_ip_map last_ip_for ips_for ip_report_body write_logger_status \
         now_eastern format_epoch_eastern append_dated_log remember_verified_player \
         mask_cmd write_auth_masked is_auth_cmd queue_auth auth_seen_recently record_auth_seen \
         flush_pending_auth ip_field hide_ip_for client_field forward_ip_setting \
         set_forward_ip_in_listeners read_forward_ip_state write_forward_ip_state \
         verified_client_problem warn_verified_client_problem \
         forward_ip_start_line forward_ip_was_refused apply_forward_ip_choice \
         bungee_restart discover_forward_ip_header forward_ip_probe_once \
         write_forward_ip_probe_py ensure_forward_ip_probe_py \
         set_verdict verdict_for verdict_label is_bypassed enforce_client_policy \
         report_shared_ips hf_push_logs hf_push_saves write_console_snapshot \
         bucket_sync_lock bucket_sync_unlock \
         is_online mark_online mark_offline record_login record_logout \
         playerlist_names playerlist_check playerlist_loop \
         bucket_id_of bucket_prefix_of bucket_sync_dir bucket_write_probe bucket_py \
         write_bucket_sync_py ensure_bucket_sync_py \
         write_auth_filter_patch_py ensure_auth_filter_patch_py auth_patch_one \
         javap_dump javap_verify_patch apply_auth_filter_patch \
         auth_patch_post_start_check mask_console_tail real_client_ip_line \
         write_proxy_peers_py ensure_proxy_peers_py proxy_peer_addrs proxy_peers_record \
         proxy_peer_list is_proxy_addr logged_ip_is_proxy ip_evidence_line \
         forward_ip_retry_needed forward_ip_retry_due \
         wait_for_paper_ready \
         handle_paper_line handle_bungee_line; do
    extract "$f"
done | sed "s|/tmp/bungee.log|$BLOG|g" > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

# The timestamp function is explicit about Eastern time, uses a 12-hour clock,
# and inserts exactly one spaced divider when the local calendar date changes.
DATE_LOG="$WORK/date-dividers.log"
EPOCH_A=$(TZ=UTC date -d '2024-01-01 12:00:00' +%s)
EPOCH_B=$(TZ=UTC date -d '2024-01-01 16:30:00' +%s)
EPOCH_C=$(TZ=UTC date -d '2024-01-02 12:00:00' +%s)
append_dated_log "$DATE_LOG" "$EPOCH_A" 'LOGIN | Alice | hidden'
append_dated_log "$DATE_LOG" "$EPOCH_B" 'COMMAND | Alice | /spawn'
append_dated_log "$DATE_LOG" "$EPOCH_C" 'LOGOUT | Alice | hidden'
check "log timestamps use the Eastern 12-hour format" \
      "$(grep -Fc '2024-01-01 07:00:00 AM EST | LOGIN | Alice | hidden' "$DATE_LOG")" "1"
check "the day divider appears once for each Eastern date" \
      "$(grep -c '^==================== ' "$DATE_LOG")" "2"
python3 - "$DATE_LOG" <<'PYDATE'
import pathlib, re, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
headers = [i for i, line in enumerate(lines) if line.startswith('==================== ')]
assert len(headers) == 2
for i in headers:
    assert i + 2 < len(lines) and lines[i + 1] == ""
    assert re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} (AM|PM) (EST|EDT) \| ", lines[i + 2])
assert headers[1] > 0 and lines[headers[1] - 1] == ""
assert sum("| COMMAND | Alice | /spawn" in line for line in lines) == 1
print("ok")
PYDATE
check "date dividers and event spacing remain readable" \
      "$(python3 - "$DATE_LOG" <<'PYDATE'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
headers = [i for i, line in enumerate(lines) if line.startswith('==================== ')]
print("yes" if len(headers) == 2 and all(lines[i+1] == "" for i in headers)
      and lines[headers[1]-1] == "" else "no")
PYDATE
)" "yes"

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

brand_answer "$VERIFIED_CLIENT_BRAND" "$VERIFIED_CLIENT_UUID"
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
brand_answer "$VERIFIED_CLIENT_BRAND" "$VERIFIED_CLIENT_UUID"
login CreppyBitch 1.2.3.4
sleep 4.5
played CreppyBitch "/gamemode 1"
check "login recorded" "$(grep -c '| LOGIN | CreppyBitch' "$LOGIN_LOG")" "1"
check "the verified client's IP is hidden while its check is pending" \
      "$(grep -c '| LOGIN | CreppyBitch | hidden | client=CHECK PENDING' "$LOGIN_LOG")" "1"
check "there is no redundant VERIFY row in the login stream" "$(grep -c '| VERIFY | CreppyBitch' "$LOGIN_LOG")" "0"
check "the client check clearly marks the owner and hides the IP" \
      "$(grep -c '| CHECK | CreppyBitch | hidden | client=VERIFIED CLIENT' "$CLIENT_LOG")" "1"
check "the owner brand and UUID are redacted from the synced check" \
      "$(grep -c 'brand=redacted.*uuid=redacted' "$CLIENT_LOG")" "1"
check "commands are logged, hidden and marked as verified" \
      "$(grep -c '| COMMAND | CreppyBitch | hidden | /gamemode 1 | client=VERIFIED CLIENT$' "$CMD_LOG")" "1"
check "the verified client is NOT kicked" "$(kick_count CreppyBitch)" "0"
check_at_least "the hidden IP was kept in private-logs/addresses.log" \
      "$(grep -c '| IP | CreppyBitch | 1.2.3.4' "$IP_MAP_FILE")" 1

# a stock Eaglercraft client: visible + kicked
stock_answer
login RandomGuy 5.6.7.8
sleep 4.5
played RandomGuy "/gamemode 1"
check "the stranger's login row stays hidden while CHECK carries the real IP" \
      "$(grep -Fc '| LOGIN | RandomGuy | hidden' "$LOGIN_LOG")" "1"
check "the stranger gets a client-check row with the real IP" \
      "$(grep -c '| CHECK | RandomGuy | 5.6.7.8 | client=OTHER EAGLERCRAFT CLIENT |' "$CLIENT_LOG")" "1"
check "the stranger's commands are tagged" \
      "$(grep -c '| COMMAND | RandomGuy | 5.6.7.8 | /gamemode 1 | client=OTHER EAGLERCRAFT CLIENT$' "$CMD_LOG")" "1"
check "the stranger is kicked" "$(kick_count RandomGuy)" "1"

# a Java client
vanilla_answer
login Notch 9.9.9.9
sleep 4.5
check "the Java client gets a client-check row" \
      "$(grep -c '| CHECK | Notch | 9.9.9.9 | client=JAVA CLIENT |' "$CLIENT_LOG")" "1"
check "the Java client is kicked (ENFORCE_KICK_VANILLA=true)" "$(kick_count Notch)" "1"

# a check that never resolves: logged, but not kicked
rm -f "$PIDFILE"
login Ghost 6.6.6.6
sleep 4.5
check "unresolved check is logged as UNKNOWN" \
      "$(grep -c '| CHECK | Ghost | hidden | client=UNKNOWN CLIENT |' "$CLIENT_LOG")" "1"
check "unresolved check does not kick" "$(kick_count Ghost)" "0"
echo $MOCK_PID > "$PIDFILE"

# the clients handed out before (and public in the git history) are just "some
# other Eaglercraft client" now - they cannot make anybody look like the owner
brand_answer "Eaglercraft[VER]" "51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"
login OldV1 8.8.8.1
sleep 4.5
check "the revoked V1 client is not verified" \
      "$(grep -c '| CHECK | OldV1 | 8.8.8.1 | client=OTHER EAGLERCRAFT CLIENT | brand=Eaglercraft\[VER\] |' "$CLIENT_LOG")" "1"
brand_answer "EaglercraftX[V2]" "355d0b9f-14ce-359f-8c9f-97cc1a7c92ca"
login OldV2 8.8.8.2
sleep 4.5
check "the revoked V2 client is not verified either" \
      "$(grep -c '| CHECK | OldV2 | 8.8.8.2 | client=OTHER EAGLERCRAFT CLIENT | brand=EaglercraftX\[V2\] |' "$CLIENT_LOG")" "1"
check "…and nothing in the logs calls either of them the verified client" \
      "$(grep -c 'VERIFIED CLIENT' "$CLIENT_LOG")" "1"

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
check "the verified-client marker remains present when IP hiding is disabled" \
      "$( HIDE_VERIFIED_IP=false; client_field VERIFIED )" " | client=VERIFIED CLIENT"
check "client= tags for others are unaffected by the hiding" \
      "$( client_field UNVERIFIED )" " | client=OTHER EAGLERCRAFT CLIENT"
check "an unresolved verdict is labeled without revealing the IP" \
      "$( client_field UNKNOWN )" " | client=UNKNOWN CLIENT"

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
check "the verified client's /login is masked and marked in activity.log" \
      "$(grep -Fc '| COMMAND | CreppyBitch | hidden | /login ******** | client=VERIFIED CLIENT' "$CMD_LOG")" "1"

# a stranger whose verdict is already known: logged immediately, in full
played RandomGuy "/login strangerpass"
sleep 0.3
check "the stranger's /login is kept in full in private-logs/auth.log" \
      "$(grep -c '| RandomGuy | 5.6.7.8 | /login strangerpass | client=OTHER EAGLERCRAFT CLIENT$' "$AUTH_LOG")" "1"
check "the stranger's /login is masked in activity.log" \
      "$(grep -Fc '/login ********' "$CMD_LOG")" "2"

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
# --------------------------------------------------------------------------- #
echo "== 4b. everybody may join; only a real, secret brand counts as verified =="
check "start.sh ships with enforcement OFF (everybody can join)" \
      "$(grep -c '^ENFORCE_VERIFIED_CLIENT=false' "$ROOT/start.sh")" "1"
check "…and the kick switch is still there for later" \
      "$(grep -c '^ENFORCE_VERIFIED_CLIENT=' "$ROOT/start.sh")" "1"

: > "$WORK/kicks"
ENFORCE_VERIFIED_CLIENT=false
enforce_client_policy Somebody UNVERIFIED
enforce_client_policy Somebody VANILLA
enforce_client_policy Somebody UNKNOWN
check "with enforcement off nobody is kicked, whatever client they use" \
      "$(wc -l < "$WORK/kicks" | tr -d ' ')" "0"

ENFORCE_VERIFIED_CLIENT=true
enforce_client_policy Somebody UNVERIFIED
check "turning it on still kicks (the switch works both ways)" \
      "$(grep -c 'kick Somebody' "$WORK/kicks")" "1"
ENFORCE_VERIFIED_CLIENT=false
: > "$WORK/kicks"

# a brand that was committed to this (public) repo can be copied by anybody,
# so it must not be treated as the verified client any more
ENFORCE_VERIFIED_CLIENT=true
for pair in "Eaglercraft[VER]" "EaglercraftX[V2]"; do
    VERIFIED_CLIENT_BRAND="$pair"
    VERIFIED_CLIENT_UUID=$(python3 "$ROOT/tools/patch_verified_client.py" --print-uuid --brand "$pair" |
                           sed -n 's/^brandUUID *: *//p')
    VERIFIED_CLIENT_CONFIGURED=true
    VERIFIED_CLIENT_PUBLISHED=false
    for _p in $PUBLISHED_CLIENT_BRANDS; do
        if [ "$VERIFIED_CLIENT_BRAND" = "${_p%%|*}" ] || [ "$VERIFIED_CLIENT_UUID" = "${_p##*|}" ]; then
            VERIFIED_CLIENT_PUBLISHED=true
        fi
    done
    check "a public brand ($pair) is recognised as public" "$VERIFIED_CLIENT_PUBLISHED" "true"
    brand_answer "$pair" "$VERIFIED_CLIENT_UUID"
    check "…and even when configured it is NOT verified" \
          "$(query_client_brand PublicGuy | cut -d'|' -f1)" "UNVERIFIED"
    check "…and the boot log explains it" \
          "$(grep -c 'PUBLIC BRAND' <<<"$(verified_client_problem)")" "1"
done

# an unconfigured server must not pretend anything is verified
VERIFIED_CLIENT_BRAND=""; VERIFIED_CLIENT_UUID=""
VERIFIED_CLIENT_CONFIGURED=false; VERIFIED_CLIENT_PUBLISHED=false
check "without a configured pair the boot log says so" \
      "$(grep -c 'NOT CONFIGURED' <<<"$(verified_client_problem)")" "1"

# ... and then no password is attributed: everything is masked in auth.log
: > "$AUTH_LOG"; : > "$AUTH_SEEN"; : > "$PENDING_AUTH"; : > "$VERDICT_CACHE"
record_ip Somebody 9.9.9.9 paper
mask_cmd Somebody "/login hunter2" UNKNOWN > /dev/null
check "unconfigured: the password is not written in clear" "$(grep -c 'hunter2' "$AUTH_LOG")" "0"
check "…but the command is still recorded (masked)" "$(grep -Fc '| /login ******** |' "$AUTH_LOG")" "1"
check "…and marked as unconfigured" "$(grep -c 'client=UNCONFIGURED' "$AUTH_LOG")" "1"
printf '%s\t%s\t%s\n' "$(date +%s)" QueuedGuy "/login queuedpw" >> "$PENDING_AUTH"
set_verdict QueuedGuy UNVERIFIED
flush_pending_auth
check "…and a command queued earlier is masked too" \
      "$(grep -Fc '| QueuedGuy | ' "$AUTH_LOG")" "1"
check "…still without the password" "$(grep -c 'queuedpw' "$AUTH_LOG")" "0"

# back to the normal test configuration
export VERIFIED_CLIENT_BRAND="TestBrand[...]"
export VERIFIED_CLIENT_UUID="$(python3 "$ROOT/tools/patch_verified_client.py" \
        --print-uuid --brand "TestBrand[...]" | sed -n 's/^brandUUID *: *//p')"
export VERIFIED_CLIENT_CONFIGURED=true
export VERIFIED_CLIENT_PUBLISHED=false
PUBLISHED_CLIENT_BRANDS=$(sed -n 's/^PUBLISHED_CLIENT_BRANDS="\(.*\)"$/\1/p' "$ROOT/start.sh")
export PUBLISHED_CLIENT_BRANDS
ENFORCE_VERIFIED_CLIENT=true
: > "$WORK/kicks"

echo "== 5. address reports =="
report_shared_ips
check "the public address report hides the verified client's IP" \
      "$(grep -Fc '1.2.3.4' "$ADDRESS_REPORT")" "0"
check "the private address report keeps the verified client's IP" \
      "$(grep -Fxc $'CreppyBitch\t1.2.3.4\tpaper (seen 1 time(s))' "$PRIVATE_ADDRESS_REPORT")" "1"
check "the public report is clearly titled and timestamped in Eastern time" \
      "$(grep -c 'IP ADDRESS REPORT' "$ADDRESS_REPORT")$(grep -c 'Updated: .* EDT' "$ADDRESS_REPORT")" "11"
check "the redundant public report variables are gone" \
      "$(grep -Ec '^SHARED_REPORT=|^VERIFICATION_REPORT=' "$ROOT/start.sh")" "0"

for pair in "VERIFIED:VERIFIED CLIENT" "UNVERIFIED:OTHER EAGLERCRAFT CLIENT" \
            "VANILLA:JAVA CLIENT" "PENDING:CHECK PENDING" "GARBAGE:UNKNOWN CLIENT"; do
    check "label for ${pair%%:*} is right" "$(verdict_label "${pair%%:*}")" "${pair#*:}"
done

# --------------------------------------------------------------------------- #
echo "== 6. every log reaches the bucket =="
export BACKEND_DIR="$WORK/backend"
export SEC_DIR="$BACKEND_DIR/security-logs"
export PRIV_DIR="$BACKEND_DIR/private-logs"
export HF_BUCKET_HANDLE="hf://buckets/test/1.12"
export FULL_STAGING="$WORK/stage-full"
export LOG_STAGING="$WORK/stage-logs"
export SAVE_DIRS="security-logs private-logs"
export ACTIVITY_LOG="$SEC_DIR/activity.log"
export LOGIN_LOG="$ACTIVITY_LOG" CMD_LOG="$ACTIVITY_LOG" CLIENT_LOG="$ACTIVITY_LOG"
export AUTH_LOG="$PRIV_DIR/auth.log"
export IP_MAP_FILE="$PRIV_DIR/addresses.log"
export ADDRESS_REPORT="$SEC_DIR/addresses.txt" STATUS_FILE="$SEC_DIR/status.txt"
export PRIVATE_ADDRESS_REPORT="$PRIV_DIR/addresses.txt"
export VERIFIED_PLAYER_STATE="$PRIV_DIR/verified-players.txt"
export PROXY_PEERS_STATE="$PRIV_DIR/proxy-peers.log"
export REPORT_STATE="$WORK/report-last-update" REPORT_INTERVAL=0
export BUCKET_SYNC_LOCK="$WORK/bucket-sync.lock"
mkdir -p "$SEC_DIR" "$PRIV_DIR"
touch "$ACTIVITY_LOG" "$AUTH_LOG" "$IP_MAP_FILE" "$VERIFIED_PLAYER_STATE" "$PROXY_PEERS_STATE"
check "LOGIN, COMMAND and CHECK handlers share one physical activity log" \
      "$( [ "$LOGIN_LOG" = "$ACTIVITY_LOG" ] && [ "$CMD_LOG" = "$ACTIVITY_LOG" ] && [ "$CLIENT_LOG" = "$ACTIVITY_LOG" ] && echo yes )" "yes"
HF_CALLS="$WORK/hf-calls.txt"; HF_STAGED="$WORK/hf-staged.txt"
: > "$HF_CALLS"; : > "$HF_STAGED"
hf() {   # fake the HF CLI: record each scoped upload and staged file list
    printf 'hf %s\n' "$*" >> "$HF_CALLS"
    [ -d "${3:-}" ] && find "$3" -type f -printf '%P\n' | sort >> "$HF_STAGED"
    if [ -f "${3:-}/console.log" ]; then cp "$3/console.log" "$WORK/staged-console.log"; fi
    return 0
}

: > "$HF_CALLS"; : > "$HF_STAGED"
SYNC_PRIVATE_LOGS=true hf_push_logs
check "log sync uploads the security prefix, not the whole world" \
      "$(grep -c "hf buckets sync $LOG_STAGING/security-logs $HF_BUCKET_HANDLE/game-data/security-logs --delete" "$HF_CALLS")" "1"
check "log sync serializes three small, deletable prefixes" "$(grep -c 'hf buckets sync' "$HF_CALLS")$(grep -c -- '--delete' "$HF_CALLS")" "33"
check "the single activity log is staged" "$(grep -c '^activity.log$' "$HF_STAGED")" "1"
check "public and private address summaries plus one status snapshot are staged" \
      "$(grep -c '^addresses.txt$' "$HF_STAGED")$(grep -c '^status.txt$' "$HF_STAGED")" "21"
check "security-logs contains only its three curated files" \
      "$(find "$SEC_DIR" -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' ')" "activity.log addresses.txt status.txt "
check "the full /login file is staged privately" "$(grep -c '^auth.log$' "$HF_STAGED")" "1"
check "the full private address history is staged" "$(grep -c '^addresses.log$' "$HF_STAGED")" "1"
check "the log staging dir is cleaned up" "$([ -d "$LOG_STAGING" ] && echo yes || echo no)" "no"

: > "$HF_CALLS"; : > "$HF_STAGED"
SYNC_PRIVATE_LOGS=false hf_push_logs
check "SYNC_PRIVATE_LOGS=false clears the private bucket prefix" \
      "$(grep -c "hf buckets sync $LOG_STAGING/private-logs $HF_BUCKET_HANDLE/game-data/private-logs --delete" "$HF_CALLS")" "1"
check "…and uploads no private files" "$(grep -c 'auth.log\\|addresses.log' "$HF_STAGED")" "0"
check "…while the sanitized activity log is still uploaded" "$(grep -c '^activity.log$' "$HF_STAGED")" "1"

# One masked console snapshot replaces separate Paper and Bungee files.
export CONSOLE_LOG_LINES=1000
printf 'line1\n%s\n' "$(seq 1 5 | tr '\n' ' ')" > /tmp/paper.log
printf 'bungee line\n' > "$BLOG"
: > "$HF_STAGED"
SYNC_CONSOLE_LOGS=true SYNC_PRIVATE_LOGS=true hf_push_logs
check "one combined console.log snapshot is uploaded" "$(grep -c '^console.log$' "$HF_STAGED")" "1"
check "the combined snapshot contains both labeled console sources" \
      "$(grep -Fc '[PAPER]' "$WORK/staged-console.log")$(grep -Fc '[BUNGEE]' "$WORK/staged-console.log")" "21"
: > "$HF_STAGED"
SYNC_CONSOLE_LOGS=false SYNC_PRIVATE_LOGS=true hf_push_logs
check "SYNC_CONSOLE_LOGS=false uploads no console snapshot" "$(grep -c '^console.log$' "$HF_STAGED")" "0"

: > "$HF_CALLS"; : > "$HF_STAGED"
SYNC_CONSOLE_LOGS=true hf_push_saves
check "the full game-data sync still mirrors with --delete" "$(grep -c -- '--delete' "$HF_CALLS")" "1"
check "the full sync preserves the curated activity log" "$(grep -c '^security-logs/activity.log$' "$HF_STAGED")" "1"
check "the full sync preserves private auth logs" "$(grep -c '^private-logs/auth.log$' "$HF_STAGED")" "1"
check "the full mirror includes a console snapshot, not separate tails" "$(grep -c '^logs/console.log$' "$HF_STAGED")" "1"
check "the full staging dir is cleaned up" "$([ -d "$FULL_STAGING" ] && echo yes || echo no)" "no"

# the real SAVE_DIRS from start.sh must contain private-logs (and follow the switch)
save_dirs_from_start_sh() {
    ( SYNC_PRIVATE_LOGS="$1"; unset SAVE_DIRS
      eval "$(grep -m1 -F 'SAVE_DIRS="world' "$ROOT/start.sh")"
      eval "$(grep -m1 -F '[ "$SYNC_PRIVATE_LOGS" = true ] && SAVE_DIRS=' "$ROOT/start.sh")"
      echo "$SAVE_DIRS" )
}
check "start.sh syncs private-logs by default" \
      "$(save_dirs_from_start_sh true | tr ' ' '\n' | grep -c '^private-logs$')" "1"
check "start.sh honours SYNC_PRIVATE_LOGS=false" \
      "$(save_dirs_from_start_sh false | tr ' ' '\n' | grep -c '^private-logs$')" "0"
check "start.sh still syncs the security-logs" \
      "$(save_dirs_from_start_sh true | tr ' ' '\n' | grep -c '^security-logs$')" "1"
check "start.sh has a dedicated fast log sync loop" \
      "$(grep -c '^log_sync_loop &\?$' "$ROOT/start.sh")" "1"
check "the log sync interval defaults to 60s" \
      "$(grep -c '^LOG_SYNC_INTERVAL="\${LOG_SYNC_INTERVAL:-60}"$' "$ROOT/start.sh")" "1"
check "the full world snapshot defaults to 600s" \
      "$(grep -c '^SYNC_INTERVAL="\${SYNC_INTERVAL:-600}"$' "$ROOT/start.sh")" "1"
check "the player-list polling default is 60s" \
      "$(grep -c '^PLAYERLIST_POLL="\${PLAYERLIST_POLL:-60}"$' "$ROOT/start.sh")" "1"
check "the shutdown pushes the last log lines" \
      "$(grep -c 'hf_push_logs     # make sure the last log lines reached the bucket' "$ROOT/start.sh")" "1"

# A one-time fixture for legacy files verifies conversion, privacy and
# idempotence before the compact layout is deployed to the bucket.
echo "== 6b. legacy logs migrate once without leaking the verified client =="
MIG_SEC="$WORK/migration/security-logs"; MIG_PRIV="$WORK/migration/private-logs"
mkdir -p "$MIG_SEC" "$MIG_PRIV"
cat > "$MIG_SEC/logins.log" <<'LEGACY_LOGIN'
2024-01-01 12:00:00 | LOGIN | Owner | hidden | client=CHECK PENDING
2024-01-01 12:02:00 | VERIFY | Owner | VERIFIED | brand=SecretBrand | uuid=SecretUUID
2024-01-01 12:03:00 | LOGIN | Stranger | 5.6.7.8 | client=OTHER EAGLERCRAFT CLIENT
LEGACY_LOGIN
cat > "$MIG_SEC/commands.log" <<'LEGACY_COMMAND'
2024-01-01 12:04:00 | Owner | hidden | /spawn | client=VERIFIED CLIENT
LEGACY_COMMAND
cat > "$MIG_SEC/client-checks.log" <<'LEGACY_CHECK'
2024-01-01 12:02:00 | VERIFIED | Owner | 1.2.3.4 | brand=SecretBrand | version=1.12 | uuid=SecretUUID
LEGACY_CHECK
cat > "$MIG_PRIV/auth.log" <<'LEGACY_AUTH'
2024-01-01 12:05:00 | Owner | 1.2.3.4 | /login ownersecret | client=VERIFIED CLIENT
2024-01-01 12:06:00 | Stranger | 5.6.7.8 | /login othersecret | client=OTHER EAGLERCRAFT CLIENT
LEGACY_AUTH
cat > "$MIG_PRIV/player-ips.log" <<'LEGACY_IPS'
2024-01-01 12:00:01 | Owner | 1.2.3.4 | paper
2024-01-01 12:03:01 | Stranger | 5.6.7.8 | paper
LEGACY_IPS
cat > "$MIG_PRIV/logins-real-ips.log" <<'LEGACY_REAL_IPS'
2024-01-01 12:00:01 | LOGIN | Owner | 1.2.3.4 | source=paper
LEGACY_REAL_IPS
for old in "$MIG_SEC/shared-ips.txt" "$MIG_SEC/ip-report.log" \
           "$MIG_SEC/logger-status.log" "$MIG_SEC/proxy-peers.txt" \
           "$MIG_PRIV/ip-report-private.log" "$MIG_PRIV/shared-ips-private.txt"; do
    : > "$old"
done
MIGRATION_RESULT=$(python3 "$ROOT/tools/log_migrate.py" "$MIG_SEC" "$MIG_PRIV")
check "legacy events and unique IP sightings are migrated" \
      "$(printf '%s' "$MIGRATION_RESULT" | grep -o 'activity_rows=[0-9]* address_rows=[0-9]*')" "activity_rows=4 address_rows=2"
check "old UTC wall time becomes 07:00 AM Eastern in winter" \
      "$(grep -Fc '2024-01-01 07:00:00 AM EST | LOGIN | Owner' "$MIG_SEC/activity.log")" "1"
check "the richer client check replaces the duplicate VERIFY row" \
      "$(grep -Fc 'CHECK | Owner | hidden | client=VERIFIED CLIENT' "$MIG_SEC/activity.log")" "1"
check "the legacy activity copy redacts owner brand, UUID and IP" \
      "$(grep -Ec 'SecretBrand|SecretUUID|1\.2\.3\.4' "$MIG_SEC/activity.log")" "0"
check "the verified owner's old password is masked in private auth history" \
      "$(grep -Fc 'Owner | hidden | /login ******** | client=VERIFIED CLIENT (password not recorded)' "$MIG_PRIV/auth.log")" "1"
check "other players' private auth history is preserved in full" \
      "$(grep -Fc 'Stranger | 5.6.7.8 | /login othersecret' "$MIG_PRIV/auth.log")" "1"
check "the private address history keeps both real addresses" \
      "$(grep -c '^2024-01-01 07:.* | IP | ' "$MIG_PRIV/addresses.log")" "2"
check "all redundant legacy report/log copies are removed" \
      "$(find "$MIG_SEC" "$MIG_PRIV" -type f \
            \( -name 'logins.log' -o -name 'commands.log' -o -name 'client-checks.log' \
               -o -name 'shared-ips*' -o -name 'ip-report*' -o -name 'logger-status.log' \
               -o -name 'proxy-peers.txt' -o -name 'player-ips.log' -o -name 'logins-real-ips.log' \) | wc -l | tr -d ' ')" "0"
MIGRATION_BEFORE=$(sha256sum "$MIG_SEC/activity.log" "$MIG_PRIV/auth.log" "$MIG_PRIV/addresses.log" | sha256sum | cut -d' ' -f1)
MIGRATION_SECOND=$(python3 "$ROOT/tools/log_migrate.py" "$MIG_SEC" "$MIG_PRIV")
MIGRATION_AFTER=$(sha256sum "$MIG_SEC/activity.log" "$MIG_PRIV/auth.log" "$MIG_PRIV/addresses.log" | sha256sum | cut -d' ' -f1)
check "a repeat migration leaves all curated logs unchanged" \
      "$( [ "$MIGRATION_BEFORE" = "$MIGRATION_AFTER" ] && echo yes )" "yes"
check "the repeat run reports no migrated rows" \
      "$(printf '%s' "$MIGRATION_SECOND" | grep -o 'activity_rows=[0-9]* address_rows=[0-9]*')" "activity_rows=0 address_rows=0"

# --------------------------------------------------------------------------- #
echo "== 7. the Space only needs a couple of files =="
check "the Dockerfile pins the container to Eastern time" \
      "$(grep -c '^ENV TZ=America/New_York$' "$ROOT/Dockerfile")" "1"
check "the Dockerfile installs timezone data and ionice support" \
      "$(grep -c 'tzdata' "$ROOT/Dockerfile")$(grep -c 'util-linux' "$ROOT/Dockerfile")" "11"
check "the Dockerfile does not depend on client/ (kept out of the Space)" \
      "$(grep -c '^COPY client/' "$ROOT/Dockerfile")" "0"
check "the Dockerfile copies the files the Space has" \
      "$(grep -c '^COPY start.sh ' "$ROOT/Dockerfile")" "1"
check "…plugins/ (AuthMe jars live on the Space)" \
      "$(grep -c '^COPY plugins/ ' "$ROOT/Dockerfile")" "1"
check "…and EaglerXBungee.jar (already on the Space)" \
      "$(grep -c '^COPY config/bungee/EaglerXBungee.jar ' "$ROOT/Dockerfile")" "1"
FILES=$(bash "$ROOT/tools/push-to-space.sh" --help >/dev/null 2>&1; \
        grep -oE '"\$ROOT/[A-Za-z.]+"' "$ROOT/tools/push-to-space.sh" | sed 's|"\$ROOT/||;s|"||' | sort -u | tr '\n' ' ')
check "the push helper uploads exactly Dockerfile + start.sh (+ README on flag)" \
      "$FILES" "Dockerfile README.md start.sh "
check "nothing in the repo references a client file at runtime" \
      "$(grep -c '/opt/server/client' "$ROOT/start.sh" "$ROOT/Dockerfile" | grep -c ':0$')" "2"

# --------------------------------------------------------------------------- #
echo "== 8. the client really boots (gate + its own EPW loader) =="
# The client that ships is gated: its EPW is sealed and only unseals with the
# credentials. Those are never stored in the repo, so this section runs the
# full end-to-end check when they are supplied (VER_CLIENT_USER/VER_CLIENT_PASS)
# and says so plainly when they are not - it must never look "passed" while
# nothing was tested.
if ! command -v node >/dev/null 2>&1; then
    echo "  skip - node is not installed (cannot run the client's own EPW loader)"
elif [ -z "${VER_CLIENT_USER:-}" ] || [ -z "${VER_CLIENT_PASS:-}" ]; then
    echo "  skip - set VER_CLIENT_USER / VER_CLIENT_PASS to run the boot test"
    echo "         node tools/verify_gated_client.mjs client/1.12.html --user U --pass P"
else
    UNSEALED="$WORK/unsealed.epw"
    VERIFY_OUT=$(node "$ROOT/tools/verify_gated_client.mjs" "$ROOT/client/1.12.html" \
                    --user "$VER_CLIENT_USER" --pass "$VER_CLIENT_PASS" \
                    --dump-epw "$UNSEALED" 2>&1)
    VERIFY_RC=$?
    check "the gate + the client's own loader boot the released client" "$VERIFY_RC" "0"
    check "…every end-to-end check passed" "$(grep -c 'ALL CHECKS PASSED' <<<"$VERIFY_OUT")" "1"
    check "…no boot before the credentials are accepted" \
          "$(grep -c 'the game does not boot before login' <<<"$VERIFY_OUT")" "1"
    check "…the wrong username is rejected" "$(grep -c 'a wrong username is rejected' <<<"$VERIFY_OUT")" "1"
    check "…the wrong password is rejected" "$(grep -c 'a wrong password is rejected' <<<"$VERIFY_OUT")" "1"
    check "…plaintext credentials are not in the file" \
          "$(grep -c 'the plaintext password is not in the file' <<<"$VERIFY_OUT")" "1"

    # the unsealed container is what a player's browser ends up with: the
    # client's own loader must still accept it
    LOADER_OUT=$(node "$ROOT/tools/run_epw_loader.mjs" "$UNSEALED" 2>&1); LOADER_RC=$?
    check "the unsealed EPW is accepted by the client's own loader.wasm" "$LOADER_RC" "0"
    check "…and reports success" "$(grep -c 'resultSuccess *: true' <<<"$LOADER_OUT")" "1"
    check "…after decompressing classes.wasm" \
          "$(grep -c 'Decompressing classes.wasm\.\.\.$' <<<"$LOADER_OUT")" "1"
    check "…and both asset EPKs" "$(grep -c 'Decompressing assets EPK' <<<"$LOADER_OUT")" "2"

    # negative control: a corrupted container must be rejected by the same test
    cp "$UNSEALED" "$WORK/epw.bin"
    python3 - "$WORK/epw.bin" <<'PY'
import struct, sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
struct.pack_into("<I", b, 12, struct.unpack_from("<I", b, 12)[0] ^ 0xFF)   # break fileCRC32
open(p, "wb").write(b)
PY
    BAD_OUT=$(node "$ROOT/tools/run_epw_loader.mjs" "$WORK/epw.bin" 2>&1); BAD_RC=$?
    check "a corrupted EPW is rejected by the same test" "$([ "$BAD_RC" -ne 0 ] && echo yes)" "yes"
    check "…with the loader's checksum error" "$(grep -c 'invalid checksum' <<<"$BAD_OUT")" "1"
fi

# the tool must know the loader's hard limits (this is what broke the first build:
# xz preset 9 uses a 64 MiB dictionary, the loader only allows 32 MiB)
LIMITS=$(python3 - "$ROOT" <<'PY'
import importlib.util, lzma, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("pvc", root + "/tools/patch_verified_client.py")
pvc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pvc)

big = lzma.compress(b"x" * 1000, format=lzma.FORMAT_XZ,
                    filters=[{"id": lzma.FILTER_LZMA2, "preset": 9}])   # preset 9 = 64 MiB dict
info = pvc.xz_stream_info(big)
ok1 = info["dict_size"] == 64 * 1024 * 1024 and pvc.EAGLER_MAX_DICT == 32 * 1024 * 1024

small = pvc.compress_component(b"x" * 1000, {"dict_size": info["dict_size"], "check": 0})
ok2 = pvc.xz_stream_info(small)["dict_size"] == 32 * 1024 * 1024

class Fake:
    name = "test"; data = big; decompressed_length = 1000
try:
    pvc.decompress_component(Fake())
    ok3 = False
except ValueError as exc:
    ok3 = "limit" in str(exc)
print("yes" if (ok1 and ok2 and ok3) else f"no {ok1} {ok2} {ok3}")
PY
)
check "the tool enforces the loader's 32 MiB dictionary limit" "$LIMITS" "yes"

# --------------------------------------------------------------------------- #
echo "== 9. logins are logged whatever the console looks like =="
# The complaint this section exists for: "it's not logging logins".  The old
# patterns only matched one Paper console format and a grep pre-filter dropped
# everything else, so a different version - or a login the proxy reported
# first - wrote no row at all. Section 9 only tests detection, so the client
# check (which talks to the mock proxy) is stubbed out here.
check_player_client() { :; }
: > "$ONLINE_STATE"; : > "$LOGIN_LOG"; : > "$CMD_LOG"; : > "$IP_MAP"

# (a) the modern Paper line ([time] [thread/INFO]) and the old one
handle_paper_line "[15:04:11] [Server thread/INFO]: ModernGuy[/10.0.0.1:5000] logged in with entity id 42 at ([world]0.0, 0.0, 0.0)"
handle_paper_line "[15:04:11 INFO]: OldGuy[/10.0.0.4:5004] logged in with entity id 43 at (0.0, 0.0, 0.0)"
check "a modern Paper login line is logged" "$(grep -c '| LOGIN | ModernGuy |' "$LOGIN_LOG")" "1"
check "…and the IP is recorded (hidden in the row until the check resolves)" \
      "$(grep -c '^ModernGuy	10\.0\.0\.1	paper	' "$IP_MAP")" "1"
check "the older Paper format still works" "$(grep -c '| LOGIN | OldGuy |' "$LOGIN_LOG")" "1"

# (b) no console prefix at all (other log backends / log formats)
handle_paper_line "BareGuy[/10.0.0.2:5001] logged in with entity id 7"
check "a bare login line is logged" "$(grep -c '| LOGIN | BareGuy |' "$LOGIN_LOG")" "1"

# (c) the proxy reports the join before Paper ever sees it
handle_bungee_line "[15:04:12 INFO] [UserConnection] ProxyGuy[/10.0.0.3:5002] <-> InitialHandler has connected"
check "the proxy handshake alone is not a login yet" "$(grep -c '| LOGIN | ProxyGuy' "$LOGIN_LOG")" "0"
handle_bungee_line "[15:04:13 INFO] ProxyGuy[/10.0.0.3:5002] <-> ServerConnector [lobby] has connected"
check "a proxy-only login is logged" "$(grep -c '| LOGIN | ProxyGuy |' "$LOGIN_LOG")" "1"
check "…with the IP from the proxy" \
      "$(awk -F'\t' '$1=="ProxyGuy"{print $2}' "$IP_MAP" | sort -u | wc -l | tr -d ' ')" "1"
check "…and the handshake row says where it came from" \
      "$(grep -c '^ProxyGuy	10\.0\.0\.3	bungee-handshake	' "$IP_MAP")" "1"

# (d) the same join seen by everything stays one row
handle_paper_line "[15:04:13] [Server thread/INFO]: ProxyGuy[/10.0.0.3:5002] logged in with entity id 9"
handle_bungee_line "[15:04:14 INFO] ProxyGuy[/10.0.0.3:5002] <-> ServerConnector [lobby] has connected"
check "paper + proxy = one LOGIN row" "$(grep -c '| LOGIN | ProxyGuy' "$LOGIN_LOG")" "1"

# (e) logouts, in either wording, exactly once
handle_paper_line "[15:10:00] [Server thread/INFO]: ModernGuy lost connection: Disconnected"
check "'lost connection' logs a LOGOUT" "$(grep -c '| LOGOUT | ModernGuy |' "$LOGIN_LOG")" "1"
handle_paper_line "[15:10:01 INFO]: ModernGuy left the game"
check "…and the duplicate 'left the game' does not" "$(grep -c '| LOGOUT | ModernGuy |' "$LOGIN_LOG")" "1"

# (f) the safety net: the server itself is asked who is online
# colour codes and a different wording must not hide anybody
mc_command() { printf '%s' "There are 2 of a max 20 players online: §aRconGuy§r, A_b-c"; }
check "the player list is parsed" "$(mc_command 'list' | playerlist_names | tr '\n' ' ')" "RconGuy A_b-c "
PLOUT=$(playerlist_check 2>&1)
check "a player the logs never showed still gets a LOGIN row" \
      "$(grep -c '| LOGIN | RconGuy |' "$LOGIN_LOG")" "1"
check "…and a proxy login is not logged twice by the player list" \
      "$(grep -c '| LOGIN | ProxyGuy |' "$LOGIN_LOG")" "1"
check "…with a note in the console (visible in the Space Logs tab)" \
      "$(grep -c 'RconGuy is online without a LOGIN row' <<<"$PLOUT")" "1"
check "a repeat poll does not duplicate the row" \
      "$(playerlist_check; grep -c '| LOGIN | RconGuy |' "$LOGIN_LOG")" "1"
mc_command() { printf '%s' "There are 0 of a max 20 players online:"; }
playerlist_check
check "leaving is logged from the player list as well" "$(grep -c '| LOGOUT | RconGuy |' "$LOGIN_LOG")" "1"
check "…and the online state is empty again" "$(grep -c . "$ONLINE_STATE")" "0"
# an RCON hiccup must not be read as "everybody left"
mc_command() { return 1; }
handle_bungee_line "[15:14:00 INFO] ProxyGuy[/10.0.0.3:5002] <-> ServerConnector [lobby] has connected"
BEFORE_LOGOUTS=$(grep -c '| LOGOUT | ProxyGuy |' "$LOGIN_LOG")
playerlist_check
check "an RCON failure never logs everybody out" \
      "$(( $(grep -c '| LOGOUT | ProxyGuy |' "$LOGIN_LOG") - BEFORE_LOGOUTS ))" "0"
check "…and the online state survives it" "$(grep -c '^ProxyGuy$' "$ONLINE_STATE")" "1"
mc_command() { printf '%s\n' "$*" >> "$WORK/kicks"; }

# the console gets a line per login/logout, so the Space Logs tab shows them
: > "$ONLINE_STATE"
LOGOUT=$( { handle_paper_line "[15:15:00] [Server thread/INFO]: EchoGuy[/10.0.0.9:5009] logged in with entity id 3"; } 2>&1 )
check "logins are echoed to the console" "$(grep -c '\[LOG\] LOGIN  EchoGuy' <<<"$LOGOUT")" "1"

# --------------------------------------------------------------------------- #
echo "== 10. the bucket upload cannot silently stop =="
# the embedded copy of the uploader must be the tested file, byte for byte
EMBEDDED=$(python3 - "$ROOT" <<'PYSAME'
import re, sys
root = sys.argv[1]
start = open(root + "/start.sh").read()
m = re.search(r"<<'BUCKET_SYNC_PY_EOF'\n(.*?)\nBUCKET_SYNC_PY_EOF", start, re.S)
src = open(root + "/tools/bucket_sync.py").read()
print("same" if m and m.group(1) + "\n" == src else "different")
PYSAME
)
check "start.sh ships the same bucket uploader as tools/bucket_sync.py" "$EMBEDDED" "same"

FAKE_LIB="$WORK/fakelib"; mkdir -p "$FAKE_LIB"
cat > "$FAKE_LIB/huggingface_hub.py" <<'PYFAKE'
"""Minimal stand-in for the real library, used to test the upload path."""
import os


class HfApi:
    def __init__(self, token=None):
        pass

    def whoami(self):
        return {"name": "tester", "auth": {"accessToken": {"role": "write"}}}

    def create_bucket(self, bucket_id, private=None, exist_ok=False, **kw):
        pass

    def list_bucket_tree(self, bucket_id, prefix=None, recursive=False):
        return []

    def batch_bucket_files(self, bucket_id, add=None, delete=None, **kw):
        with open(os.environ.get("FAKE_HF_LOG", "/tmp/fake-hf.log"), "a") as fh:
            for src, dst in (add or []):
                data = src if isinstance(src, bytes) else open(src, "rb").read()
                fh.write(f"add {bucket_id} {dst} {len(data)}\n")
            for path in (delete or []):
                fh.write(f"delete {bucket_id} {path}\n")
PYFAKE
export PYTHONPATH="$FAKE_LIB${PYTHONPATH:+:$PYTHONPATH}"
export FAKE_HF_LOG="$WORK/fake-hf.log"

# force the CLI to fail: the uploader has to fall back to the Python API
hf() { printf 'hf %s\n' "$*" >> "$HF_CALLS"; return 1; }   # missing / read-only / too old
STAGING="$WORK/stage-bucket"; mkdir -p "$STAGING/security-logs" "$STAGING/private-logs"
echo "a login"    > "$STAGING/security-logs/activity.log"
echo "a password" > "$STAGING/private-logs/auth.log"
: > "$FAKE_HF_LOG"; : > "$HF_CALLS"
BUCKET_METHOD=auto
if bucket_sync_dir "$STAGING" "hf://buckets/tester/1.12/game-data" > "$WORK/sync.out" 2>&1; then
    ok "the upload falls back to the Python API when hf fails"
else
    bad "the upload falls back to the Python API when hf fails"
fi
check "…and says so" "$(grep -c 'retrying with the Python API' "$WORK/sync.out")" "1"
check "…and reports the CLI error instead of swallowing it" \
      "$(grep -c 'hf buckets sync failed' "$WORK/sync.out")" "1"
check "…the consolidated activity log lands in the bucket" \
      "$(grep -c '^add tester/1.12 game-data/security-logs/activity.log ' "$FAKE_HF_LOG")" "1"
check "…the private log (passwords) lands in the bucket too" \
      "$(grep -c '^add tester/1.12 game-data/private-logs/auth.log ' "$FAKE_HF_LOG")" "1"
check "…and the sync line says which path was used" \
      "$(grep -c 'bucket-sync:' "$WORK/sync.out")" "1"
check "BUCKET_VIA reports python for the caller" "$BUCKET_VIA" "python"

# The Python fallback should walk/stat the immutable staging tree once, not
# twice. Also make sure its --delete list still contains stale remote objects.
WALK_TEST=$(python3 - "$ROOT" "$STAGING" <<'PYWALK'
import sys
from argparse import Namespace
sys.path.insert(0, sys.argv[1] + "/tools")
import bucket_sync

calls = 0
original = bucket_sync.iter_local
def counted(root):
    global calls
    calls += 1
    yield from original(root)
bucket_sync.iter_local = counted
bucket_sync.list_remote = lambda *args: {"stale.log": 12}
args = Namespace(local_dir=sys.argv[2], bucket_id="tester/1.12", prefix="game-data",
                 token=None, delete=True)
bucket_sync.cmd_sync(args)
print(f"iter_local_calls={calls}")
PYWALK
)
check "the Python fallback walks the staged tree once" \
      "$(grep -c '^iter_local_calls=1$' <<<"$WALK_TEST")" "1"
check "the one-pass Python sync still removes stale remote files" \
      "$(grep -c 'deleted=1' <<<"$WALK_TEST")" "1"
check "the stale remote object is named in the delete request" \
      "$(grep -c '^delete tester/1.12 game-data/stale.log$' "$FAKE_HF_LOG")" "1"

# the write probe: CLI broken -> the Python API, and the banner can say OK
: > "$FAKE_HF_LOG"
bucket_write_probe > "$WORK/probe.out" 2>&1
check "the write probe finds the working path" \
      "$(grep -c 'write test OK (Python API)' "$WORK/probe.out")" "1"
check "…and switches the sync over to it" "$BUCKET_METHOD" "python"
check "…after reporting the token role" "$(grep -c 'token role: write' "$WORK/probe.out")" "1"

# nothing works: the user is told exactly what to do, in the Space logs
python3() { return 1; }        # pretend the image has no usable huggingface_hub
hf() { return 1; }
BUCKET_METHOD=auto
bucket_write_probe > "$WORK/probe-fail.out" 2>&1
check "a dead bucket path is called out" \
      "$(grep -c 'NOTHING will reach the bucket' "$WORK/probe-fail.out")" "1"
check "…with the fix (a Write token as HF_TOKEN)" \
      "$(grep -c 'name HF_TOKEN' "$WORK/probe-fail.out")" "1"
unset -f python3
# back to the fake CLI that works, so nothing after this inherits the failure
hf() {   # fake the HF CLI: record the call and the staged files
    printf 'hf %s\n' "$*" >> "$HF_CALLS"
    [ -d "${3:-}" ] && find "$3" -type f -printf '%P\n' | sort >> "$HF_STAGED"
    if [ -f "${3:-}/console.log" ]; then cp "$3/console.log" "$WORK/staged-console.log"; fi
    return 0
}

if [ "${PRINT_LOGS:-0}" = "1" ]; then
    echo
    echo "############ security-logs/activity.log"
    cat "$ACTIVITY_LOG"
    echo
    echo "############ private-logs/auth.log   (full other-player passwords)"
    cat "$AUTH_LOG"
    echo
    echo "############ private-logs/addresses.log   (real IP history)"
    sort -u "$IP_MAP_FILE"
fi


# --------------------------------------------------------------------------- #
echo "== 11. the owner's own /login is recorded (masked) so auth.log fills =="
: > "$AUTH_LOG"; : > "$AUTH_SEEN"; : > "$PENDING_AUTH"
: > "$VERDICT_CACHE"; : > "$IP_MAP"
set_verdict CreppyBitch VERIFIED
printf '%s\t%s\n' CreppyBitch 1.2.3.4 >> "$IP_MAP"

# (a) verdict already known - the masked row is written straight away
mask_cmd CreppyBitch "/login hunter2" VERIFIED > /dev/null
check "the owner's /login reaches auth.log" "$(grep -c '| CreppyBitch |' "$AUTH_LOG")" "1"
check "…with the password masked" "$(grep -c '| /login \*\*\*\*\*\*\*\* |' "$AUTH_LOG")" "1"
check "…and never in clear" "$(grep -c 'hunter2' "$AUTH_LOG")" "0"
check "…with the IP hidden (auth.log is synced)" \
      "$(grep -c '| CreppyBitch | hidden |' "$AUTH_LOG")" "1"
check "…and it is marked as the verified client" \
      "$(grep -c 'client=VERIFIED CLIENT (password not recorded)' "$AUTH_LOG")" "1"

# (b) verdict still pending when the command is typed
: > "$AUTH_LOG"; : > "$AUTH_SEEN"; : > "$PENDING_AUTH"
mask_cmd CreppyBitch "/login swordfish" PENDING > /dev/null
check "a pending /login waits in the queue" "$(wc -l < "$PENDING_AUTH" | tr -d ' ')" "1"
set_verdict CreppyBitch VERIFIED
flush_pending_auth
check "…and is written (masked) once the verdict resolves" \
      "$(grep -c '| /login \*\*\*\*\*\*\*\* |' "$AUTH_LOG")" "1"
check "…without the password" "$(grep -c 'swordfish' "$AUTH_LOG")" "0"
check "…and the queue is empty again" "$(wc -l < "$PENDING_AUTH" | tr -d ' ')" "0"

# (c) somebody else's /login still keeps the full line (that is the point of it)
record_ip Ghost 1.2.3.4 paper
mask_cmd Ghost "/login hunter2" UNVERIFIED > /dev/null
check "another player's /login is kept in full" "$(grep -c '| Ghost | 1.2.3.4 | /login hunter2 |' "$AUTH_LOG")" "1"

# --------------------------------------------------------------------------- #
echo "== 12. IPs are truthful =="
: > "$IP_MAP"; : > "$IP_MAP_FILE"
record_ip Alice 1.2.3.4 paper
record_ip Alice 9.9.9.9 bungee-handshake
record_ip Bob 1.2.3.4 paper
record_ip Carol unknown "rcon list"
record_ip Carol 5.5.5.5 paper
check "a placeholder is not a real address" "$(is_real_ip unknown && echo yes || echo no)" "no"
check "…and cannot overtake a real one" "$(last_ip_for Carol)" "5.5.5.5"
check "the newest real address wins" "$(last_ip_for Alice)" "9.9.9.9"
check "every sighting is kept with its source" \
      "$(awk -F'\t' '$1=="Alice"{print $3}' "$IP_MAP" | sort | tr '\n' ',' )" "bungee-handshake,paper,"
check "the private IP log lists them too" "$(grep -c 'Alice' "$IP_MAP_FILE")" "2"

ip_report_body "$IP_MAP" "$WORK/private-address-report.txt" no
check "the report lists both Alice IPs and their sources" \
      "$(grep -Fxc $'Alice\t1.2.3.4\tpaper (seen 1 time(s))' "$WORK/private-address-report.txt")$(grep -Fxc $'Alice\t9.9.9.9\tbungee-handshake (seen 1 time(s))' "$WORK/private-address-report.txt")" "11"
check "the shared-address section names both accounts once" \
      "$(grep -Fxc $'1.2.3.4\tAlice, Bob' "$WORK/private-address-report.txt")" "1"
check "the report has an Eastern, 12-hour timestamp" \
      "$(grep -Ec '^Updated: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (AM|PM) (EDT|EST)$' "$WORK/private-address-report.txt")" "1"
check "the report has no placeholder address" "$(grep -c 'unknown' "$WORK/private-address-report.txt")" "0"

# Public snapshot omits the verified account; private snapshot retains it.
: > "$IP_MAP"
record_ip CreppyBitch 7.7.7.7 paper
record_ip Alice 1.2.3.4 paper
: > "$VERDICT_CACHE"; set_verdict CreppyBitch VERIFIED
ip_report_body "$IP_MAP" "$ADDRESS_REPORT" yes
check "the synced address summary has other players" "$(grep -c 'Alice' "$ADDRESS_REPORT")" "1"
check "the synced summary omits the verified account and its address" \
      "$(grep -Ec 'CreppyBitch|7\.7\.7\.7' "$ADDRESS_REPORT")" "0"
ip_report_body "$IP_MAP" "$PRIVATE_ADDRESS_REPORT" no
check "the private address summary retains the verified account" \
      "$(grep -Fxc $'CreppyBitch\t7.7.7.7\tpaper (seen 1 time(s))' "$PRIVATE_ADDRESS_REPORT")" "1"
check "an empty map still produces a readable report" \
      "$( : > "$WORK/empty-map.tsv"; ip_report_body "$WORK/empty-map.tsv" "$WORK/empty-report.txt" no; grep -c '(no real addresses recorded yet)' "$WORK/empty-report.txt" )" \
      "1"
check "report entries are date/time-prefixed, not split into duplicate files" \
      "$(grep -c '^IP ADDRESS REPORT$' "$PRIVATE_ADDRESS_REPORT")$(grep -c '^Updated: ' "$PRIVATE_ADDRESS_REPORT")" "11"

# --------------------------------------------------------------------------- #
echo "== 13. real client IPs: the header is proven before it is trusted =="
LISTENERS="$WORK/listeners.yml"
cat > "$LISTENERS" <<'YML'
listener_01:
  address: 0.0.0.0:8081
  forward_ip: false
  forward_ip_header: X-Real-IP
  default_server: default
YML
find_listeners_yml() { echo "$LISTENERS"; }
FORWARD_IP_STATE="$WORK/forward-ip.state"
FORWARD_IP_CANDIDATES="X-Real-IP X-Forwarded-For"
PUBLIC_URL="http://localhost:1/"
: > "$FORWARD_IP_STATE"

set_forward_ip_in_listeners true X-Forwarded-For
check "the header can be switched on" "$(sed -n 's/.*forward_ip: *//p' "$LISTENERS")" "true"
check "…and the header name with it" "$(sed -n 's/.*forward_ip_header: *//p' "$LISTENERS")" "X-Forwarded-For"
check "forward_ip_setting reads it back" "$(forward_ip_setting)" "true X-Forwarded-For"
set_forward_ip_in_listeners false X-Real-IP
check "…and back off" "$(forward_ip_setting)" "false X-Real-IP"

# the plugin closes connections when the header is missing - the probe must
# recognise that in the Bungee log, not just trust the exit code
: > "$BLOG"
printf '[INFO] Player[/1.2.3.4:5555] <-> InitialHandler has connected\n' >> "$BLOG"
forward_ip_start_line
printf '[INFO] Connected without X-Real-IP header, disconnecting...\n' >> "$BLOG"
check "the plugin's refusal is recognised" "$(forward_ip_was_refused && echo yes || echo no)" "yes"
forward_ip_start_line
printf '[INFO] Player[/1.2.3.4:5555] <-> InitialHandler has connected\n' >> "$BLOG"
check "…and a normal join is not mistaken for a refusal" "$(forward_ip_was_refused && echo yes || echo no)" "no"

# a saved answer is used without probing
echo "CF-Connecting-IP" > "$FORWARD_IP_STATE"
FORWARD_IP=auto; FORWARD_IP_HEADER=""; FORWARD_IP_DECISION=""
apply_forward_ip_choice
check "a remembered header is applied on the next boot" "$(forward_ip_setting)" "true CF-Connecting-IP"
check "…and nothing is probed again" "$FORWARD_IP_DECISION" ""

# nothing worked last time -> stay on the safe setting
echo "off" > "$FORWARD_IP_STATE"
FORWARD_IP=auto; FORWARD_IP_HEADER=""; FORWARD_IP_DECISION=""
apply_forward_ip_choice
check "a known-bad header is not retried blindly" "$(forward_ip_setting)" "false X-Real-IP"
check "…and the failure is remembered" "$(cat "$FORWARD_IP_STATE")" "off"

# FORWARD_IP=off and =on are honoured
FORWARD_IP=off; FORWARD_IP_HEADER=""; FORWARD_IP_DECISION=""
apply_forward_ip_choice
check "FORWARD_IP=off keeps the proxy address" "$(forward_ip_setting)" "false X-Real-IP"
FORWARD_IP=on; FORWARD_IP_HEADER="X-Forwarded-For"; FORWARD_IP_DECISION=""
apply_forward_ip_choice
check "FORWARD_IP=on + a header name trusts it without a probe" "$(forward_ip_setting)" "true X-Forwarded-For"

# the discovery loop. The fake proxy answers the probe and logs the plugin's own
# refusal line at the moment of the connection, exactly like EaglerXBungee does.
cat > "$WORK/fake-probe.py" <<'PY'
import os, sys
with open(os.environ.get("FAKE_PROBE_LOG", "/dev/null"), "a") as fh:
    fh.write("probe\n")
header = ""
for line in open(os.environ.get("FAKE_LISTENERS", "/dev/null")).read().splitlines():
    if "forward_ip_header:" in line:
        header = line.split(":", 1)[1].strip()
refused = header in os.environ.get("FAKE_REFUSE", "").split(",")
if refused:
    with open(os.environ["FAKE_BLOG"], "a") as fh:
        fh.write("[INFO] Connected without %s header, disconnecting...\n" % header)
sys.exit(0 if header and header == os.environ.get("FAKE_PROBE_ACCEPT", "") else 1)
PY
export FAKE_PROBE_LOG="$WORK/probe.log" FAKE_LISTENERS="$LISTENERS" FAKE_BLOG="$BLOG"
FORWARD_IP_PROBE_PY="$WORK/fake-probe.py"
bungee_restart() { : > "$BLOG"; return 0; }   # the stub proxy comes straight back

# (a) no candidate works -> the safe setting stays and is remembered
FAKE_PROBE_ACCEPT="NoSuchHeader"; FAKE_REFUSE=""; export FAKE_PROBE_ACCEPT FAKE_REFUSE
: > "$FAKE_PROBE_LOG"; : > "$FORWARD_IP_STATE"
FORWARD_IP=auto; FORWARD_IP_HEADER=""; FORWARD_IP_DECISION=""
discover_forward_ip_header >/dev/null 2>&1
check "every candidate was tried" "$(wc -l < "$FAKE_PROBE_LOG" | tr -d ' ')" "2"
check "…none of them was trusted" "$(cat "$FORWARD_IP_STATE")" "off"
check "…leaving the safe setting in place" "$(forward_ip_setting)" "false X-Real-IP"

# (b) the proxy really sends the second one -> it is saved and used
FAKE_PROBE_ACCEPT="X-Forwarded-For"; FAKE_REFUSE=""; export FAKE_PROBE_ACCEPT FAKE_REFUSE
: > "$FAKE_PROBE_LOG"; : > "$FORWARD_IP_STATE"
FORWARD_IP=auto; FORWARD_IP_HEADER=""; FORWARD_IP_DECISION=""
discover_forward_ip_header >/dev/null 2>&1
check "a header the proxy does send is saved" "$(cat "$FORWARD_IP_STATE")" "X-Forwarded-For"
check "…and switched on for real" "$(forward_ip_setting)" "true X-Forwarded-For"
check "…so it will not be probed again" "$FORWARD_IP_DECISION" "done"

# (c) the probe answers, but the plugin refuses that header anyway: this is the
# trap that would disconnect every player, so it must never be trusted
FAKE_PROBE_ACCEPT="X-Real-IP"; FAKE_REFUSE="X-Real-IP"; export FAKE_PROBE_ACCEPT FAKE_REFUSE
: > "$FAKE_PROBE_LOG"; : > "$FORWARD_IP_STATE"
FORWARD_IP=auto; FORWARD_IP_HEADER=""; FORWARD_IP_DECISION=""
discover_forward_ip_header >/dev/null 2>&1
check "a header the plugin refuses is not trusted, even when the probe passes" \
      "$(cat "$FORWARD_IP_STATE")" "off"
check "…and the listeners file is left safe" "$(forward_ip_setting)" "false X-Real-IP"

# --------------------------------------------------------------------------- #
echo "== 14. the tools embedded in start.sh cannot drift from tools/ =="
python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
s = (root / "start.sh").read_text()
def extract(marker):
    tag = "<<'%s'\n" % marker
    i = s.index(tag) + len(tag)
    j = s.index("\n%s\n" % marker, i)
    return s[i:j] + "\n"
bad = []
for name, marker in [("bucket_sync.py", "BUCKET_SYNC_PY_EOF"),
                     ("forward_ip_probe.py", "FORWARD_IP_PROBE_EOF"),
                     ("proxy_peers.py", "PROXY_PEERS_EOF"),
                     ("patch_auth_filter.py", "AUTH_FILTER_PATCH_PY_EOF")]:
    if extract(marker) != (root / "tools" / name).read_text():
        bad.append(name)
print("MISMATCH:" + ",".join(bad) if bad else "OK")
PY
check "bucket_sync.py + forward_ip_probe.py in start.sh match tools/" \
      "$(python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
s = (root / "start.sh").read_text()
def extract(marker):
    tag = "<<'%s'\n" % marker
    i = s.index(tag) + len(tag)
    j = s.index("\n%s\n" % marker, i)
    return s[i:j] + "\n"
bad = [n for n, m in [("bucket_sync.py", "BUCKET_SYNC_PY_EOF"),
                      ("forward_ip_probe.py", "FORWARD_IP_PROBE_EOF"),
                      ("proxy_peers.py", "PROXY_PEERS_EOF"),
                      ("log_migrate.py", "LOG_MIGRATOR_PY_EOF"),
                      ("patch_auth_filter.py", "AUTH_FILTER_PATCH_PY_EOF")]
       if extract(m) != (root / "tools" / n).read_text()]
print("MISMATCH:" + ",".join(bad) if bad else "OK")
PY
)" "OK"
check "the embedded probe is valid Python" \
      "$(python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
s = (root / "start.sh").read_text()
tag = "<<'FORWARD_IP_PROBE_EOF'\n"
i = s.index(tag) + len(tag)
j = s.index("\nFORWARD_IP_PROBE_EOF\n", i)
src = s[i:j] + "\n"
try:
    compile(src, "probe", "exec")
    print("OK")
except SyntaxError as e:
    print("SYNTAX:" + str(e))
PY
)" "OK"

# --------------------------------------------------------------------------- #
echo "== 15. logger status says why a log may be empty =="
BLOG="$WORK/bungee.log"
export ONLINE_STATE="$WORK/online-state.txt"
printf 'Alice\n' > "$ONLINE_STATE"
printf '[12:00:00 INFO]: Alice[/1.2.3.4:5555] logged in with entity id 42\n' > /tmp/paper.log
printf '[12:00:01 INFO] Alice[/1.2.3.4:5555] <-> InitialHandler has connected\n' > "$BLOG"
ACTIVITY_LOG="$WORK/activity-status.log"
printf '%s | LOGIN | Alice | 1.2.3.4\n' "$(now_eastern)" > "$ACTIVITY_LOG"
PLAYERLIST_LAST="18:00:00 got: There are 1 of a max 20 players online: Alice"
FORWARD_IP="auto"; FORWARD_IP_HEADER=""; SEC_DIR="$WORK/security"; STATUS_FILE="$SEC_DIR/status.txt"; PRIVATE_IP_LOG=true
write_logger_status
STATUS="$STATUS_FILE"
check "the status snapshot is written at the curated path" "$([ -s "$STATUS" ] && echo yes)" "yes"
check "…with the Eastern timezone and 12-hour clock" \
      "$(grep -c '^Timezone      : America/New_York (EST/EDT), 12-hour clock$' "$STATUS")" "1"
check "…with the activity log byte count" "$(grep -c '^Activity log  : [0-9][0-9]* bytes$' "$STATUS")" "1"
check "…and the latest activity row" "$(grep -c '^Last activity : .* | LOGIN | Alice | 1.2.3.4$' "$STATUS")" "1"
check "…the player-list answer" "$(grep -c '^Player list   : 18:00:00 got: There are 1' "$STATUS")" "1"
check "…the forward-IP setting" "$(grep -c '^Client IPs    : ' "$STATUS")" "1"
check "…with the Paper console file size" \
      "$(grep -c '^Paper console : [0-9][0-9]* bytes in /tmp/paper.log$' "$STATUS")" "1"
check "…and the Bungee console file size" \
      "$(grep -F 'Bungee console:' "$STATUS" | grep -Fc "$BLOG")" "1"
check "the status timestamp is Eastern and uses a 12-hour clock" \
      "$(grep -Ec '^Updated       : [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (AM|PM) (EDT|EST)$' "$STATUS")" "1"


# --------------------------------------------------------------------------- #
echo "== 16. the auth plugins' password filter is neutralised (LoginSecurity 3.3.1) =="
PATCH_TOOL="$ROOT/tools/patch_auth_filter.py"

# LoginSecurity 3.3.1 adds com.lenis0012.bukkit.loginsecurity.util.LoggingFilter
# to the log4j ROOT logger in LoginSecurity.enable() and that class returns DENY
# for every message that starts with, or contains, "issued server command: "
# plus one of four hard-coded words.  That is why no /login line ever reached the
# console - so the patch has to name exactly that class and those strings.
check "the patch targets LoginSecurity 3.3.1's LoggingFilter" \
      "$(grep -c 'com/lenis0012/bukkit/loginsecurity/util/LoggingFilter.class' "$PATCH_TOOL")" "1"
check "…and AuthMe's LogFilterHelper (for the switch later)" \
      "$(grep -c 'fr/xephi/authme/output/LogFilterHelper.class' "$PATCH_TOOL")" "1"
for word in /login /register /changepassword /changepass; do
    check "the deny word $word is covered" \
          "$(grep -Ec "^[[:space:]]*\"$word\",$" "$PATCH_TOOL")" "1"
done
check "the console prefix LoginSecurity matches on is covered too" \
      "$(grep -c '"issued server command: ",' "$PATCH_TOOL")" "1"

# A fixture jar whose class holds exactly those strings, before and after the
# patch.  The model below is LoginSecurity's denyIfExposesPassword, run over the
# strings that are really in the class file (command-shortcut.enabled is false by
# default, so only the four words and the prefix matter).
AFX="$WORK/authfilter"
rm -rf "$AFX"
python3 "$PATCH_TOOL" --selftest --dir "$AFX" > /dev/null 2>&1
model() {   # $1 jar, $2 log line -> DENY / NEUTRAL, exactly like LoginSecurity
    python3 - "$1" "$2" "$PATCH_TOOL" <<'PY'
import sys, zipfile, importlib.util
jar, line, tool_path = sys.argv[1], sys.argv[2].lower(), sys.argv[3]
spec = importlib.util.spec_from_file_location("authpatch", tool_path)
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
with zipfile.ZipFile(jar) as zf:
    entry = [n for n in zf.namelist() if n.endswith(".class")][0]
    data = zf.read(entry)
strings = tool.ClassFile(data).strings()
# the commands the class compares against, and the console prefix it looks for
words = [x for x in strings
         if any(w in x for w in ("/login", "/register", "/changepassword", "/changepass"))]
prefix = next((x for x in strings if "issued server command" in x), "issued server command: ")
# LoginSecurity: startsWith(word) or contains("issued server command: " + word)
deny_ls = any(line.startswith(x.lower()) or (prefix + x).lower() in line for x in words)
# AuthMe: contains("issued server command:") and one of the commands it knows
# (its own list is built at runtime from LogFilterHelper.COMMANDS_TO_SKIP, so it
# is spelled out here; we only ever patch the prefix it looks for)
authme_cmds = ("/login ", "/l ", "/log ", "/register ", "/reg ", "/unregister ",
               "/unreg ", "/changepassword ", "/cp ", "/changepass ")
deny_authme = prefix.lower() in line and any(c in line for c in authme_cmds)
print("DENY" if (deny_ls or deny_authme) else "NEUTRAL")
PY
}
LOGIN_LINE="Steve issued server command: /login hunter2"
check "LoginSecurity's filter would have DENIED this line (that was the bug)" \
      "$(model "$AFX/LoginSecurity-original.jar" "$LOGIN_LINE")" "DENY"
check "…and after the patch the same filter can only answer NEUTRAL" \
      "$(model "$AFX/LoginSecurity-patched.jar" "$LOGIN_LINE")" "NEUTRAL"
check "the AuthMe filter is neutralised the same way" \
      "$(model "$AFX/AuthMe-patched.jar" "$LOGIN_LINE")" "NEUTRAL"
check "…while the AuthMe line would have been denied before" \
      "$(model "$AFX/AuthMe-original.jar" "$LOGIN_LINE")" "DENY"

# The patched class has to still be a class: a real JVM loads and runs it.
JAVA_BIN=""
for cand in "$(command -v java 2>/dev/null)" /usr/lib/jvm/*/bin/java; do
    [ -x "$cand" ] && { JAVA_BIN="$cand"; break; }
done
if [ -z "$JAVA_BIN" ] && python3 -c "import jdk4py" 2>/dev/null; then
    JAVA_BIN=$(python3 -c "import jdk4py,os;print(os.path.join(str(jdk4py.JAVA_HOME),'bin','java'))" 2>/dev/null)
    [ -x "$JAVA_BIN" ] || JAVA_BIN=""
fi
if [ -n "$JAVA_BIN" ]; then
    check "the patched class still loads and runs in a JVM" \
          "$("$JAVA_BIN" -cp "$AFX/LoginSecurity-patched.jar" com.lenis0012.bukkit.loginsecurity.util.LoggingFilter 2>&1 | grep -o 'authlog-patched' | wc -l | tr -d ' ')" "5"
    check "…and the untouched class prints the raw deny strings" \
          "$("$JAVA_BIN" -cp "$AFX/LoginSecurity-original.jar" com.lenis0012.bukkit.loginsecurity.util.LoggingFilter 2>&1 | grep -o 'authlog-patched' | wc -l | tr -d ' ')" "0"
else
    echo "  --   no JVM found here, the load test is skipped"
fi

# idempotent, and reversible if a plugin update needs the original back
python3 "$PATCH_TOOL" --apply --json "$AFX/LoginSecurity-patched.jar" > "$AFX/second.json" 2>/dev/null
check "patching an already patched jar does nothing" \
      "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$AFX/second.json")" "already-patched"
ORIG_MD5=$(md5sum "$AFX/LoginSecurity-original.jar" | cut -d' ' -f1)
python3 "$PATCH_TOOL" --restore --backup-dir "$AFX/backup" "$AFX/LoginSecurity-patched.jar" > /dev/null 2>&1
check "the original jar can be put back byte for byte" \
      "$(md5sum "$AFX/LoginSecurity-patched.jar" | cut -d' ' -f1)" "$ORIG_MD5"

# the patch has to be surgical: the plugin's own command class uses the same
# words for its real work and must stay untouched
DECOY_CHECK=$(python3 "$PATCH_TOOL" --selftest --dir "$AFX/decoy" --json > /dev/null 2>&1; python3 - "$AFX/decoy/LoginSecurity-original.jar" "$AFX/decoy/LoginSecurity-patched.jar" <<'PY'
import sys, zipfile
def decoy(path):
    with zipfile.ZipFile(path) as zf:
        return zf.read("com/lenis0012/bukkit/loginsecurity/commands/CommandLogin.class")
print("same" if decoy(sys.argv[1]) == decoy(sys.argv[2]) else "changed")
PY
)
check "…and the plugin's own command class is left alone" "$DECOY_CHECK" "same"

# start.sh patches the real jars in the plugins folder before Paper starts
export PLUGIN_DIR="$WORK/plugins"
export AUTH_FILTER_PATCH_PY="$WORK/patch_auth_filter.py"
export AUTH_PATCH_BACKUP_DIR="$WORK/jar-backups"
export AUTH_PATCH_JAR_GLOB='*LoginSecurity*.jar *AuthMe*.jar'
mkdir -p "$PLUGIN_DIR"
cp "$AFX/LoginSecurity-original.jar" "$PLUGIN_DIR/LoginSecurity-3.3.1.jar"
JAVA_HOME_DIR=""
apply_auth_filter_patch > "$WORK/authpatch.log" 2>&1
check "start.sh patches the LoginSecurity jar in the plugins folder" \
      "$(python3 "$PATCH_TOOL" --check --json "$PLUGIN_DIR/LoginSecurity-3.3.1.jar" | tail -1 | grep -c 'already-patched')" "1"
check "…keeps a backup of the untouched jar" \
      "$([ -f "$AUTH_PATCH_BACKUP_DIR/LoginSecurity-3.3.1.jar.authlog-orig" ] && echo yes || echo no)" "yes"
check "…records it for the synced status file" "$(printf '%s' "$AUTH_PATCH_STATUS" | grep -c 'LoginSecurity')" "1"
check "…and remembers that the plugin has to load" "$(printf '%s' "$AUTH_PATCH_EXPECT" | grep -c 'LoginSecurity')" "1"
check "without javap it says so instead of pretending" "$(grep -c 'not checked (no javap)' "$WORK/authpatch.log")" "1"
AUTH_FILTER_PATCH=false apply_auth_filter_patch > "$WORK/authpatch-off.log" 2>&1
check "the patch can be switched off" "$(printf '%s' "$AUTH_PATCH_STATUS" | grep -c 'disabled (AUTH_FILTER_PATCH=false)')" "1"
check "…and then it really does not touch the jar" "$(grep -c 'disabled by AUTH_FILTER_PATCH=false' "$WORK/authpatch-off.log")" "1"
check "start.sh applies the patch before Paper starts" \
      "$(awk '/^apply_auth_filter_patch$/{a=NR} /^start_paper$/{s=NR} END{print (a && s && a < s) ? "yes" : "no"}' "$ROOT/start.sh")" "yes"

# If javap ever reports a change the patch did not make, the jar must go back.
mkdir -p "$WORK/fakejdk/bin"
cat > "$WORK/fakejdk/bin/javap" <<'FAKEJAVAP'
#!/bin/bash
# pretend the patched class lost a method: a difference that has nothing to do
# with the deny strings
case "$*" in
    *authlog-orig*) echo "  5: invokevirtual #7 // Method helper:()V" ;;
    *)              echo "  5: invokevirtual #7 // Method" ;;
esac
FAKEJAVAP
chmod +x "$WORK/fakejdk/bin/javap"
cp "$AFX/LoginSecurity-original.jar" "$PLUGIN_DIR/LoginSecurity-javap.jar"
rm -rf "$AUTH_PATCH_BACKUP_DIR"
JAVA_HOME_DIR="$WORK/fakejdk" AUTH_PATCH_JAR_GLOB='*LoginSecurity-javap*.jar' apply_auth_filter_patch > "$WORK/authpatch2.log" 2>&1
check "a patch that fails the javap check is rolled back" \
      "$(python3 "$PATCH_TOOL" --check --json "$PLUGIN_DIR/LoginSecurity-javap.jar" | tail -1 | grep -c 'would-patch')" "1"
check "…and the status says the jar was left alone" \
      "$(printf '%s' "$AUTH_PATCH_STATUS" | grep -c 'javap check failed')" "1"

# …and a plugin that is patched but never enables must not leave the server
# without its auth plugin
start_paper() { :; }
wait_for_paper_ready() { return 0; }
BACKEND_PID=999999
AUTH_PATCH_BACKUP_DIR="$WORK/jar-backups"
cp "$AFX/LoginSecurity-original.jar" "$PLUGIN_DIR/LoginSecurity-3.3.1.jar"
JAVA_HOME_DIR="" apply_auth_filter_patch > /dev/null 2>&1
printf '[12:00:00 INFO]: no plugin lines here\n' > /tmp/paper.log
AUTH_PATCH_RESTART_DONE=false
auth_patch_post_start_check > "$WORK/poststart.log" 2>&1
check "a patched plugin that did not load gets the original jar back" \
      "$(python3 "$PATCH_TOOL" --check --json "$PLUGIN_DIR/LoginSecurity-3.3.1.jar" | tail -1 | grep -c 'would-patch')" "1"
check "…and the status explains the rollback" "$(printf '%s' "$AUTH_PATCH_STATUS" | grep -c 'ROLLED BACK')" "1"
check "…and Paper is restarted exactly once" "$(grep -c 'restarting Paper with the original plugin jar' "$WORK/poststart.log")" "1"
cp "$AFX/LoginSecurity-patched.jar" "$PLUGIN_DIR/LoginSecurity-3.3.1.jar"
printf '%s\n' '[12:00:00 INFO]: [LoginSecurity] Enabling LoginSecurity v3.3.1' > /tmp/paper.log
AUTH_PATCH_RESTART_DONE=false
auth_patch_post_start_check > "$WORK/poststart2.log" 2>&1
check "a patched plugin that does load is left alone" \
      "$(grep -c 'patched plugin(s) loaded' "$WORK/poststart2.log")" "1"
check "…and no restart is triggered" "$(grep -c 'restarting Paper' "$WORK/poststart2.log")" "0"

# --------------------------------------------------------------------------- #
echo "== 17. the /login line reaches auth.log now that nothing filters it =="
: > "$AUTH_LOG"; : > "$CMD_LOG"; : > "$AUTH_SEEN"; : > "$PENDING_AUTH"; : > "$VERDICT_CACHE"; : > "$IP_MAP"
set_verdict Steve UNVERIFIED
record_ip Steve 1.2.3.4 paper
handle_paper_line "[12:00:10 INFO]: Steve issued server command: /login Tr0ub4dor&3"
check "the password lands in private-logs/auth.log" \
      "$(grep -c '| Steve | 1.2.3.4 | /login Tr0ub4dor&3 | client=OTHER EAGLERCRAFT CLIENT' "$AUTH_LOG")" "1"
check "the synced activity.log only shows a masked command" \
      "$(grep -Fc '| COMMAND | Steve | 1.2.3.4 | /login ******** | client=OTHER EAGLERCRAFT CLIENT' "$CMD_LOG")" "1"
check "…and never the password" "$(grep -c 'Tr0ub4dor' "$CMD_LOG")" "0"
handle_paper_line "[12:00:20 INFO]: Steve issued server command: /register S3cret!"
handle_paper_line "[12:00:30 INFO]: Steve issued server command: /changepassword N3wPass"
check "…/register too" "$(grep -c '| /register S3cret! |' "$AUTH_LOG")" "1"
check "…and /changepassword" "$(grep -c '| /changepassword N3wPass |' "$AUTH_LOG")" "1"

# --------------------------------------------------------------------------- #
echo "== 18. the console copies in the bucket are masked =="
: > "$VERDICT_CACHE"
set_verdict CreppyBitch VERIFIED
set_verdict Steve UNVERIFIED
printf '%s\n' \
  "[12:00:10 INFO]: Steve issued server command: /login hunter2" \
  "[12:00:11 INFO]: Steve[/1.2.3.4:5555] logged in with entity id 42" \
  "[12:00:12 INFO]: CreppyBitch issued server command: /login hunter2" \
  "[12:00:13 INFO]: CreppyBitch[/7.7.7.7:4444] logged in with entity id 43" > "$WORK/tail.log"
mask_console_tail < "$WORK/tail.log" > "$WORK/tail-masked.log"
check "no password survives in the synced console copy" "$(grep -c 'hunter2' "$WORK/tail-masked.log")" "0"
check "…the command stays readable (masked)" \
      "$(grep -Fc 'issued server command: /login ********' "$WORK/tail-masked.log")" "2"
check "other players keep their address" "$(grep -c 'Steve\[/1\.2\.3\.4:5555\]' "$WORK/tail-masked.log")" "1"
check "the verified client's address is written as hidden" \
      "$(grep -c 'CreppyBitch\[/hidden\]' "$WORK/tail-masked.log")" "1"
check "…and never appears in the copy" "$(grep -c '7\.7\.7\.7' "$WORK/tail-masked.log")" "0"
check "both raw console sources pass through the masking filter" \
      "$(grep -Fc 'mask_console_tail | sed' "$ROOT/start.sh")" "2"
check "full and log sync use one combined console snapshot" \
      "$(grep -Fc 'write_console_snapshot "$STAGING/logs/console.log"' "$ROOT/start.sh")" "2"
check "the logger status reports the login capture state" \
      "$(grep -Fc 'Login capture : ${AUTH_PATCH_STATUS:-not run}' "$ROOT/start.sh")" "1"

# --------------------------------------------------------------------------- #
echo "== 19. three accounts, one device: the addresses stay put =="
# the address is recorded per account from the join line, and a login row stays
# "hidden" until the client check resolves - that is why the LOGIN row alone is
# not where you read an IP from
check_player_client() { :; }          # no background checks in this section
: > "$IP_MAP"; : > "$IP_MAP_FILE"; : > "$VERDICT_CACHE"; : > "$LOGIN_LOG"; : > "$ONLINE_STATE"
for n in Acc1 Acc2 Acc3; do
    set_verdict "$n" UNVERIFIED
    record_login "$n" 203.0.113.9 paper
done
check "each of the three accounts keeps the address the server saw" \
      "$(for n in Acc1 Acc2 Acc3; do last_ip_for "$n"; done | sort -u | tr -d '\n')" "203.0.113.9"
check "the private IP log has one row per login, all with that address" \
      "$(grep -c '203.0.113.9' "$IP_MAP_FILE")" "3"
check "the synced row stays hidden until the check resolves (by design)" \
      "$(grep -c '| LOGIN | Acc1 | hidden' "$LOGIN_LOG")" "1"
check "…while the address is kept privately meanwhile" "$(last_ip_for Acc1)" "203.0.113.9"
record_login Acc4 198.51.100.7 paper
check "a later login from a different address does not touch the others" \
      "$(last_ip_for Acc1)" "203.0.113.9"
check "…and the new account has its own" "$(last_ip_for Acc4)" "198.51.100.7"
check "every sighting is tied to the account it came from" \
      "$(awk -F'\t' '{print $1"="$2}' "$IP_MAP" | sort -u | tr '\n' ' ')" \
      "Acc1=203.0.113.9 Acc2=203.0.113.9 Acc3=203.0.113.9 Acc4=198.51.100.7 "
set_forward_ip_in_listeners false X-Real-IP
check "the status says when the logged IP is the proxy's, not the player's" \
      "$(real_client_ip_line | grep -c 'ADDRESS OF THE PROXY')" "1"
set_forward_ip_in_listeners true X-Forwarded-For
check "…and when the players' real addresses are in use" \
      "$(real_client_ip_line | grep -c 'real addresses')" "1"

# --------------------------------------------------------------------------- #
echo "== 20. the address in the log: the player's, or the proxy's =="

# The tool reads the kernel's own tables, so the tests can hand it a fixture.
PEERFX="$WORK/peerfx"; rm -rf "$PEERFX"; mkdir -p "$PEERFX/net"
cat > "$PEERFX/net/tcp" <<'PEER_TCP'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1EB4 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1EB4 0500000A:8AE1 01 00000000:00000000 00:00000000 00000000  1000        0 2 1 0000000000000000 20 4 30 10 -1
   2: 0100007F:1EB4 6300000A:9BC2 06 00000000:00000000 00:00000000 00000000  1000        0 3 1 0000000000000000 20 4 30 10 -1
   3: 0100007F:1F90 0100007F:1EB4 01 00000000:00000000 00:00000000 00000000  1000        0 4 1 0000000000000000 20 4 30 10 -1
PEER_TCP
cat > "$PEERFX/net/tcp6" <<'PEER_TCP6'
  sl  local_address rem_address   st
   0: 00000000000000000000000000000000:1EB4 B80D0120000000000000000001000000:8AE1 01
PEER_TCP6
check "the proxy peers come out of the kernel tables (IPv4 and IPv6)" \
      "$(python3 "$ROOT/tools/proxy_peers.py" --proc-dir "$PEERFX" | tr '\n' ' ')" \
      "10.0.0.5 10.0.0.99 2001:db8::1 "
check "…and a connection that is not to the game port is not a peer" \
      "$(python3 "$ROOT/tools/proxy_peers.py" --proc-dir "$PEERFX" | grep -c '127.0.0.1')" "0"

# a python wrapper so the recorded peers come from the fixture
cat > "$WORK/peers_py.py" <<PYWRAP
import subprocess, sys
sys.exit(subprocess.call([sys.executable, "$ROOT/tools/proxy_peers.py",
                          "--proc-dir", "$PEERFX"] + sys.argv[1:]))
PYWRAP
export PROXY_PEERS_PY="$WORK/peers_py.py"
: > "$PROXY_PEERS_STATE"; : > "$IP_MAP"; : > "$IP_MAP_FILE"
proxy_peers_record > "$WORK/peers-record.log" 2>&1
check "the proxy peers are written into private-logs (so they survive a restart)" \
      "$(grep -c '10.0.0.5' "$PROXY_PEERS_STATE")" "1"
check "the peer is saved in private-logs for report classification" \
      "$(awk -F'\t' '$2=="10.0.0.5"{n++} END{print n+0}' "$PROXY_PEERS_STATE")" "1"
proxy_peers_record > /dev/null 2>&1
check "…and the same peer is never recorded twice" "$(grep -c . "$PROXY_PEERS_STATE")" "3"
check "an address equal to a peer is the proxy's" "$(is_proxy_addr 10.0.0.5 && echo yes || echo no)" "yes"
check "…while a player's address is not" "$(is_proxy_addr 203.0.113.9 && echo yes || echo no)" "no"

# the evidence, and the report that spells it out
printf '%s\t%s\t%s\t%s\n' Alice 10.0.0.5 bungee-handshake "$(date +%s)" >> "$IP_MAP"
printf '%s\t%s\t%s\t%s\n' Bob 203.0.113.9 paper "$(date +%s)" >> "$IP_MAP"
check "the evidence notices that a logged address is the proxy's" \
      "$(logged_ip_is_proxy && echo yes || echo no)" "yes"
check "…and says it in one sentence" "$(ip_evidence_line | grep -c "ARE THE PROXY'S")" "1"
ip_report_body "$IP_MAP" "$WORK/ip-report.txt" no
check "the report classifies the proxy's address" \
      "$(grep -Fxc $'10.0.0.5\tPROXY address (not a player)\t1 account(s)' "$WORK/ip-report.txt")" "1"
check "…and classifies the player's address" \
      "$(grep -Fxc $'203.0.113.9\treal client address\t1 account(s)' "$WORK/ip-report.txt")" "1"
check "…with the mixed forwarding diagnosis" \
      "$(grep -c 'Both proxy and client addresses are present' "$WORK/ip-report.txt")" "1"
: > "$IP_MAP"
printf '%s\t%s\t%s\t%s\n' Alice 10.0.0.5 bungee-handshake "$(date +%s)" >> "$IP_MAP"
ip_report_body "$IP_MAP" "$WORK/ip-report.txt" no
check "a report with only peer addresses says forwarded IPs are unavailable" \
      "$(grep -c 'Every logged address is a proxy peer; forwarded client IPs are unavailable' "$WORK/ip-report.txt")" "1"
check "…and never calls a placeholder a player address" \
      "$(grep -c 'unknown' "$WORK/ip-report.txt")" "0"

# one device using both protocols is not two machines
: > "$IP_MAP"
printf '%s\t%s\t%s\t%s\n' Cara 203.0.113.9 paper "$(date +%s)" >> "$IP_MAP"
printf '%s\t%s\t%s\t%s\n' Cara 2001:db8::5 paper "$(date +%s)" >> "$IP_MAP"
ip_report_body "$IP_MAP" "$WORK/ip-report.txt" no
check "IPv4 + IPv6 for one account is reported as one device" \
      "$(grep -Fxc $'Cara\tone device/account using both protocols' "$WORK/ip-report.txt")" "1"

# when is the header discovery retried? only with nobody online, and only when
# the addresses in the logs really are the proxy's
: > "$IP_MAP"; : > "$ONLINE_STATE"; : > "$FORWARD_IP_STATE"
printf '%s\t%s\t%s\t%s\n' Alice 10.0.0.5 bungee-handshake "$(date +%s)" >> "$IP_MAP"
FORWARD_IP=auto
check "the discovery is retried when the logs hold the proxy's address" \
      "$(forward_ip_retry_needed && echo yes || echo no)" "yes"
printf 'Alice\n' > "$ONLINE_STATE"
check "…but never while somebody is online (it restarts the proxy)" \
      "$(forward_ip_retry_needed && echo yes || echo no)" "no"
: > "$ONLINE_STATE"
printf 'X-Real-IP\n' > "$FORWARD_IP_STATE"
check "…and not once a header already works" \
      "$(forward_ip_retry_needed && echo yes || echo no)" "no"
: > "$FORWARD_IP_STATE"; FORWARD_IP=off
check "…and not when forwarding was switched off on purpose" \
      "$(forward_ip_retry_needed && echo yes || echo no)" "no"
FORWARD_IP=auto; FORWARD_IP_RETRY_INTERVAL=0
check "…and the retries can be turned off entirely" \
      "$(forward_ip_retry_needed && echo yes || echo no)" "no"
FORWARD_IP_RETRY_INTERVAL=600
printf 'off\n' > "$FORWARD_IP_STATE"
check "a header that was ruled out is only re-asked rarely" \
      "$(forward_ip_retry_due 1 && echo yes || echo no)" "no"
check "…but it is asked again eventually (the proxy can change)" \
      "$(forward_ip_retry_due 6 && echo yes || echo no)" "yes"
: > "$FORWARD_IP_STATE"
check "…while a boot that never got an answer is asked again next time" \
      "$(forward_ip_retry_due 1 && echo yes || echo no)" "yes"
: > "$IP_MAP"
printf '%s\t%s\t%s\t%s\n' Bob 203.0.113.9 paper "$(date +%s)" >> "$IP_MAP"
check "…and there is nothing to do when the addresses are the players' own" \
      "$(forward_ip_retry_needed && echo yes || echo no)" "no"

# the choice of header has to survive a restart, or every boot starts from zero
check "the discovered header is remembered where the README says (private-logs)" \
      "$(grep -c '^FORWARD_IP_STATE="\$PRIV_DIR/forward-ip.state"$' "$ROOT/start.sh")" "1"
: > "$IP_MAP"; : > "$IP_MAP_FILE"
write_logger_status
check "status.txt prints the proxy peers" \
      "$(grep -c '^Proxy peers   :' "$SEC_DIR/status.txt")" "1"
check "…and what the addresses in the logs are" \
      "$(grep -c '^IP evidence   :' "$SEC_DIR/status.txt")" "1"

# --------------------------------------------------------------------------- #
echo "== 21. the client is optimised for low-end machines =="

check "the EPK reader/writer round-trips a package byte for byte" \
      "$(python3 "$ROOT/tools/epk.py" selftest 2>&1 | grep -c 'selftest: OK')" "1"
check "the PNG reader/writer survives the assets it has to touch" \
      "$(python3 "$ROOT/tools/pnglite.py" selftest 2>&1 | grep -c 'selftest: OK')" "1"

# the two rules against a fixture pack: an animation with a rotated frame list,
# one with a hand-written list, a big end portal and a texture that must stay
FIX="$WORK/optfix"; rm -rf "$FIX"; mkdir -p "$FIX"
python3 - "$FIX" "$ROOT" <<'PYOPT'
import json, sys
sys.path.insert(0, sys.argv[2] + "/tools")
import epk, optimize_client as O, pnglite
out = sys.argv[1]

def strip(width, frames, rgb=(10, 20, 30)):
    img = pnglite.Image(width, width * frames)
    for f in range(frames):
        for y in range(width):
            for x in range(width):
                o = ((f * width + y) * width + x) * 4
                img.pixels[o:o + 4] = bytes((rgb[0], rgb[1], rgb[2], 255 if (x + y + f) % 3 else 200))
    return pnglite.encode(img)

base = "assets/minecraft/textures/"
files = {
    "assets/minecraft/textures/entity/end_portal.png":
        pnglite.encode(pnglite.Image(256, 256, bytes((30, 30, 90, 255)) * 65536)),
    base + "blocks/water_still.png": strip(16, 32),
    base + "blocks/water_still.png.mcmeta": b'{"animation": {"frametime": 2}}',
    base + "blocks/fire_layer_0.png": strip(16, 32),
    base + "blocks/fire_layer_0.png.mcmeta":
        json.dumps({"animation": {"frametime": 1, "frames": list(range(16, 32)) + list(range(16))}}).encode(),
    base + "blocks/lava_still.png": strip(16, 20),
    base + "blocks/lava_still.png.mcmeta":
        json.dumps({"animation": {"frametime": 2, "frames": list(range(20)) + list(range(18, 0, -1))}}).encode(),
    base + "blocks/stone.png": b"\x89PNG\r\n\x1a\n" + b"not really a png",
    base + "font/unicode_page_00.png": b"1-bit png, not decodable here",
    "assets/minecraft/sounds/random/click.ogg": b"OggS" + bytes(200),
}
new_files, changes, notes = O.optimize_pack(files, 8, 32)
changed = sorted(set([c["file"] for c in changes] +
                     [c["meta"] for c in changes if "meta" in c]))
report = {
    "changed": changed,
    "changes": changes,
    "notes": notes,
    "untouched_same": sorted(n for n in files if n not in changed and new_files[n] == files[n]),
    "same_count": sum(1 for n in files if n not in changed and new_files[n] == files[n]),
    "end_portal": [n for n in changed if "end_portal" in n],
    "water_frames": 0, "water_frametime": 0, "fire_frames": 0, "fire_list_len": 0,
    "lava_touched": "lava_still" in " ".join(changed),
    "stone_untouched": base + "blocks/stone.png" not in changed,
}
wf = new_files[base + "blocks/water_still.png"]
wmeta = json.loads(new_files[base + "blocks/water_still.png.mcmeta"])
report["water_frames"] = pnglite.decode(wf).height // 16
report["water_frametime"] = wmeta["animation"]["frametime"]
ff = new_files[base + "blocks/fire_layer_0.png"]
fmeta = json.loads(new_files[base + "blocks/fire_layer_0.png.mcmeta"])
report["fire_frames"] = pnglite.decode(ff).height // 16
flist = fmeta["animation"]["frames"]
report["fire_list_len"] = len(flist)
report["fire_list_ok"] = (all(0 <= i < report["fire_frames"] for i in flist)
                          and sorted(flist) == list(range(report["fire_frames"])))
report["fire_frametime"] = fmeta["animation"]["frametime"]
# the animation must keep playing at the same speed: frames * frametime must match
report["water_cycle_before"] = 32 * 2
report["water_cycle_after"] = report["water_frames"] * report["water_frametime"]
# and the whole thing has to survive a real EPK round trip
blob = epk.write(files, pack_name="assets.epk", timestamp=1)
back = epk.files(epk.read(blob))
report["pack_roundtrip"] = all(back[n] == files[n] for n in files)
blob2 = epk.write([(m, n, new_files.get(n, p) if m == epk.FILE_MARK else p)
                   for m, n, p in epk.read(blob)["records"]],
                  pack_name="assets.epk", timestamp=1)
report["optimised_roundtrip"] = epk.files(epk.read(blob2))[base + "blocks/water_still.png"] == wf
json.dump(report, open(out + "/report.json", "w"), indent=1)
PYOPT
FIXR="$FIX/report.json"
fix() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d[sys.argv[2]])" "$FIXR" "$1"; }
check "the end portal texture is shrunk to 32x32" "$(fix end_portal | tr -d "[]' ")" "assets/minecraft/textures/entity/end_portal.png"
check "a 32-frame animation is reduced to 8 frames" "$(fix water_frames)" "8"
check "…and its frametime is scaled so the animation keeps its speed" \
      "$(fix water_cycle_after)" "$(fix water_cycle_before)"
check "…the same for the fire texture" "$(fix fire_frames)" "8"
check "…whose rotated frame list is remapped, not truncated" \
      "$(fix fire_list_len)/$(fix fire_list_ok)/$(fix fire_frametime)" "8/True/4"
check "a hand-written frame list (lava) is left alone" "$(fix lava_touched)" "False"
check "a texture that cannot be decoded is left alone" "$(fix stone_untouched)" "True"
check "every other file in the pack stays byte for byte" "$(fix same_count)" "5"
check "the rebuilt package still round-trips" \
      "$(fix pack_roundtrip)/$(fix optimised_roundtrip)" "True/True"
check "the optimiser does not need a PNG library from the internet" \
      "$(grep -c 'import PIL\|from PIL' "$ROOT/tools/pnglite.py" "$ROOT/tools/optimize_client.py" | grep -c ':0')" "2"

# The same two rules have to work on a resource pack, because a pack replaces
# the optimised assets with its own - which is how "some packs give really big
# input delay" happens.  A pack the client imports is a .zip, so the optimiser
# takes one and gives a .zip back, byte for byte apart from what it changed.
python3 - "$FIX" "$ROOT" <<'PYZIP'
import json, subprocess, sys, zipfile
sys.path.insert(0, sys.argv[2] + "/tools")
import pnglite

out, root = sys.argv[1], sys.argv[2]


def strip(width, frames, rgb=(10, 20, 30)):
    img = pnglite.Image(width, width * frames)
    for f in range(frames):
        for y in range(width):
            for x in range(width):
                o = ((f * width + y) * width + x) * 4
                img.pixels[o:o + 4] = bytes((rgb[0], rgb[1], rgb[2], 255 if (x + y + f) % 3 else 200))
    return pnglite.encode(img)


base = "assets/minecraft/textures/"
entries = [
    ("pack.mcmeta", json.dumps({"pack": {"pack_format": 3, "description": "fixture"}}).encode()),
    (base + "entity/end_portal.png", pnglite.encode(pnglite.Image(256, 256, bytes((30, 30, 90, 255)) * 65536))),
    (base + "blocks/water_still.png", strip(16, 32)),
    (base + "blocks/water_still.png.mcmeta", json.dumps({"animation": {"frametime": 2}}).encode()),
    (base + "blocks/lava_flow.png", strip(16, 16, (200, 90, 10))),
    # a hand-written frame list: must be left exactly as it is
    (base + "blocks/lava_flow.png.mcmeta",
     json.dumps({"animation": {"frametime": 3, "frames": [0, 1, 2, 3, 2, 1]}}).encode()),
    ("assets/minecraft/sounds.json", b'{"ping": {"sounds": ["ping"]}}'),
]
src = out + "/pack.zip"
with zipfile.ZipFile(src, "w", zipfile.ZIP_DEFLATED) as zf:
    for name, data in entries:
        zf.writestr(name, data)
    zf.writestr(zipfile.ZipInfo("assets/"), b"")

dst = out + "/pack.opt.zip"
run = subprocess.run([sys.executable, root + "/tools/optimize_client.py", "--pack", src,
                      "--output", dst, "--report", out + "/zip-report.json"],
                     capture_output=True, text=True)
report = {"rc": run.returncode, "log": run.stdout + run.stderr}
if run.returncode == 0:
    with zipfile.ZipFile(src) as a, zipfile.ZipFile(dst) as b:
        report["names_same"] = a.namelist() == b.namelist()
        report["crc_ok"] = b.testzip() is None
        report["dir_kept"] = "assets/" in b.namelist()
        report["untouched"] = a.read("pack.mcmeta") == b.read("pack.mcmeta") and             a.read("assets/minecraft/sounds.json") == b.read("assets/minecraft/sounds.json")
        report["lava_same"] = a.read(base + "blocks/lava_flow.png") == b.read(base + "blocks/lava_flow.png") and             a.read(base + "blocks/lava_flow.png.mcmeta") == b.read(base + "blocks/lava_flow.png.mcmeta")
        portal = pnglite.decode(b.read(base + "entity/end_portal.png"))
        report["portal"] = [portal.width, portal.height]
        img = pnglite.decode(b.read(base + "blocks/water_still.png"))
        report["water_frames"] = img.height // 16
        report["water_frametime"] = json.loads(b.read(base + "blocks/water_still.png.mcmeta"))["animation"]["frametime"]
        report["cycle_same"] = report["water_frames"] * report["water_frametime"] == 32 * 2
        report["changed"] = json.load(open(out + "/zip-report.json"))["packs"][0]["changed"]
json.dump(report, open(out + "/zip-check.json", "w"), indent=1)
PYZIP
FIXZ="$FIX/zip-check.json"
fixz() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d[sys.argv[2]])" "$FIXZ" "$1"; }
check "the optimiser also takes a resource-pack .zip" "$(fixz rc)" "0"
check "…gives back the same entries in the same order" "$(fixz names_same)" "True"
check "…with every CRC intact and the directory entry kept" "$(fixz crc_ok)/$(fixz dir_kept)" "True/True"
check "…shrinks the pack's end portal texture to 32x32" "$(fixz portal | tr -d "[]' ")" "32,32"
check "…reduces its 32-frame animation to 8 with the same speed" \
      "$(fixz water_frames)/$(fixz cycle_same)" "8/True"
check "…leaves a hand-written frame list alone" "$(fixz lava_same)" "True"
check "…and leaves everything it did not touch byte for byte" "$(fixz untouched)" "True"
check "…reporting the 2 files it changed (portal + animation)" "$(fixz changed)" "2"

# the committed client must already be in that shape: optimising it again has
# to change nothing (and reproduce the file byte for byte)
if [ -n "${VER_CLIENT_USER:-}" ] && [ -n "${VER_CLIENT_PASS:-}" ]; then
    OPT="$WORK/client-reopt.html"
    python3 "$ROOT/tools/optimize_client.py" "$ROOT/client/1.12.html" \
        --user "$VER_CLIENT_USER" --pass "$VER_CLIENT_PASS" --output "$OPT" \
        --report "$WORK/reopt.json" > "$WORK/reopt.log" 2>&1
    check "the committed client is already optimised (nothing left to change)" \
          "$(grep -c 'changed 0 file(s)' "$WORK/reopt.log")" "1"
    check "…and re-optimising it reproduces the same file byte for byte" \
          "$(cmp -s "$ROOT/client/1.12.html" "$OPT" && echo same || echo different)" "same"
    REINFO=$(python3 "$ROOT/tools/patch_verified_client.py" --check "$ROOT/client/1.12.html" \
             --gate-user "$VER_CLIENT_USER" --gate-pass "$VER_CLIENT_PASS" 2>&1)
    check "…with the same brand UUID the server checks" \
          "$(sed -n 's/.*brandUUID *: *//p' <<<"$REINFO" | head -1)" "$EXPECTED_UUID"
    check "…and the same gate parameters" \
          "$(python3 -c "import sys;sys.path.insert(0,'$ROOT/tools');import patch_verified_client as P;\
g=P.gate_params(open('$ROOT/client/1.12.html','rb').read());print(g['iterations'], len(g['salt']), len(g['iv']))")" \
          "1200000 16 12"
else
    echo "  skip - set VER_CLIENT_USER / VER_CLIENT_PASS to re-optimise the real client"
fi

# --------------------------------------------------------------------------- #
echo "== 22. the end portal no longer draws 15 layers =="
# The lag near a stronghold/End portal comes from RenderEndPortal drawing the
# same quad once per "pass": the stock client picks up to 15 of them from the
# squared distance.  The pass count is a tiny compiled function in classes.wasm;
# the optimiser finds its comparison chain and lowers the constants.
PFIX="$WORK/portalfix"; rm -rf "$PFIX"; mkdir -p "$PFIX"
python3 - "$PFIX" "$ROOT" <<'PYPORTAL'
import json, struct, subprocess, sys
sys.path.insert(0, sys.argv[2] + "/tools")
import optimize_client as O

out = sys.argv[1]


def uleb(n):
    b = bytearray()
    while True:
        x = n & 0x7F
        n >>= 7
        if n:
            b.append(x | 0x80)
        else:
            b.append(x)
            return bytes(b)


def body(returns, thresholds=O.PORTAL_THRESHOLDS):
    """A module body shaped exactly like the compiled getPasses (f64, f64 -> i32)."""
    b = bytearray(b"\x01\x01\x7f")          # one i32 local (index 2 = the result)
    b += b"\x02\x40"                        # the block every branch jumps out of
    for t, r in zip(thresholds, returns):
        b += b"\x20\x01" + b"\x44" + struct.pack("<d", t)
        b += (b"\x64" if t != O.PORTAL_THRESHOLDS[-1] else b"\x65") + b"\x04\x40"
        b += b"\x41" + uleb(r) + b"\x21\x02\x0c\x01\x0b"
    b += b"\x41" + uleb(returns[-1]) + b"\x21\x02"
    b += b"\x0b\x20\x02\x0b"
    return bytes(b)


def module(buf):
    code = uleb(1) + uleb(len(buf)) + buf
    return (b"\x00asm\x01\x00\x00\x00" + b"\x01\x07\x01\x60\x02\x7c\x7c\x01\x7f"
            + b"\x03\x02\x01\x00" + b"\x07\x05\x01\x01f\x00\x00"
            + b"\x0a" + uleb(len(code)) + code)


report = {}
stock = module(body((1, 3, 5, 7, 9, 11, 13, 15, 14)))
report["stock_len"] = len(stock)
chain = O.find_end_portal_passes(stock)
report["chain"] = [p for _o, p in chain]
report["chain_offsets_sorted"] = [o for o, _p in chain] == sorted(o for o, _p in chain)
patched, changes = O.cap_end_portal_passes(stock, 7)
report["edits"] = len(changes)
report["patched"] = [p for _o, p in O.find_end_portal_passes(patched)]
report["same_len"] = len(patched) == len(stock)
report["bytes_changed"] = sum(1 for a, b in zip(stock, patched) if a != b)
report["only_lowered"] = all((o, p) == (o, min(p, 7)) for (o, p) in
                             zip([o for o, _p in chain], report["patched"]))
again, edits2 = O.cap_end_portal_passes(patched, 7)
report["idempotent"] = again == patched and edits2 == []
report["cap0_unchanged"] = O.cap_end_portal_passes(stock, 0)[0] == stock
try:
    O.cap_end_portal_passes(stock, 20)
    report["bad_cap_refused"] = False
except SystemExit:
    report["bad_cap_refused"] = True
shifted = module(body((1, 3, 5, 7, 9, 11, 13, 15, 14),
                      thresholds=(999999.0,) + O.PORTAL_THRESHOLDS[1:]))
try:
    O.find_end_portal_passes(shifted)
    report["other_module_refused"] = False
except ValueError:
    report["other_module_refused"] = True

# behaviour: run both modules for real distances (needs node)
report["node_stock"] = report["node_patched"] = None
if subprocess.run(["bash", "-c", "command -v node"], capture_output=True).returncode == 0:
    open(out + "/stock.wasm", "wb").write(stock)
    open(out + "/patched.wasm", "wb").write(patched)
    js = ("const fs=require('fs');(async()=>{const o={};"
          "for(const n of ['stock','patched']){const m=await WebAssembly.instantiate("
          "fs.readFileSync(process.argv[1]+'/../portalfix/'+n+'.wasm'));"
          "o[n]=[1000000,30000,20000,10000,5000,2000,700,300,100]"
          ".map(d=>m.instance.exports.f(0,d));}"
          "console.log(JSON.stringify(o));})()")
    r = subprocess.run(["node", "-e", js, out], capture_output=True, text=True, timeout=120)
    if r.returncode == 0 and r.stdout.strip().startswith("{"):
        data = json.loads(r.stdout)
        report["node_stock"], report["node_patched"] = data["stock"], data["patched"]
    else:
        report["node_error"] = (r.stderr or r.stdout).strip()[:200]
json.dump(report, open(out + "/report.json", "w"), indent=1)
PYPORTAL
PR="$PFIX/report.json"
pfix() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d[sys.argv[2]])" "$PR" "$1"; }
check "the passes function is found in a stock-shaped module" \
      "$(pfix chain)" "[1, 3, 5, 7, 9, 11, 13, 15, 14]"
check "…the pass counts are read at the right offsets" "$(pfix chain_offsets_sorted)" "True"
check "capping at 7 lowers every layer above it" "$(pfix edits)/$(pfix patched)" "5/[1, 3, 5, 7, 7, 7, 7, 7, 7]"
check "…touching one byte per pass, never the length" \
      "$(pfix bytes_changed)/$(pfix same_len)" "5/True"
check "…and only ever lowering a count" "$(pfix only_lowered)" "True"
check "capping an already capped client changes nothing" "$(pfix idempotent)" "True"
check "0 leaves the passes alone" "$(pfix cap0_unchanged)" "True"
check "an impossible cap is refused" "$(pfix bad_cap_refused)" "True"
check "a module that does not look like the stock one is refused" "$(pfix other_module_refused)" "True"
if [ "$(pfix node_stock)" != "None" ]; then
    check "the stock module really returns 15 layers at 16-24 blocks" \
          "$(pfix node_stock)" "[1, 3, 5, 7, 9, 11, 13, 14, 15]"
    check "…and the patched module returns at most 7, and still runs" \
          "$(pfix node_patched)" "[1, 3, 5, 7, 7, 7, 7, 7, 7]"
else
    echo "  skip - node is not installed, cannot run the fixture modules"
fi

if [ -n "${VER_CLIENT_USER:-}" ] && [ -n "${VER_CLIENT_PASS:-}" ]; then
    python3 - "$ROOT" "$WORK" "$VER_CLIENT_USER" "$VER_CLIENT_PASS" > "$WORK/portal.log" 2>&1 <<'PYREAL'
import json, sys
sys.path.insert(0, sys.argv[1] + "/tools")
import optimize_client as O, patch_verified_client as P
client, work, user, password = sys.argv[1:5]
epw = P.unseal_client(open(client + "/client/1.12.html", "rb").read(), user, password)
wasm = P.decompress_component(P.parse_header(epw)["slices"]["classesWASMData"])
chain = [p for _o, p in O.find_end_portal_passes(wasm)]
print(json.dumps({
    "chain": chain,
    "max": max(chain),
    "capped": all(p <= O.DEFAULT_PORTAL_PASSES for p in chain),
    "no_stock_15": 15 not in chain and 14 not in chain and 13 not in chain,
    "len": len(wasm),
}))
PYREAL
    REAL=$(tail -1 "$WORK/portal.log")
    real() { python3 -c "import json,sys;print(json.loads(sys.argv[1])[sys.argv[2]])" "$REAL" "$1"; }
    check "the committed client carries the capped passes function" \
          "$(real chain)" "[1, 3, 5, 7, 7, 7, 7, 7, 7]"
    check "…so no portal block draws more than $(python3 -c "import sys;sys.path.insert(0,'$ROOT/tools');import optimize_client as O;print(O.DEFAULT_PORTAL_PASSES)") layers" \
          "$(real capped)" "True"
    check "…and the 13/14/15 layer cases are gone" "$(real no_stock_15)" "True"
else
    echo "  skip - set VER_CLIENT_USER / VER_CLIENT_PASS to check the real client"
fi

echo "== 23. the server does not fight the game for the CPU =="

# -Xms may never exceed -Xmx: the JVM refuses to start with "Initial heap size
# set to a larger value than the maximum heap size".  The sizing block is lifted
# out of start.sh verbatim (only the free(1) call is replaced, so the test can
# ask about a few Space sizes) and the invariant is checked for each of them.
MEM_BLOCK="$WORK/mem-block.sh"
sed -n '/^TOTAL_MEM_MB=\$(free -m/,/^\[ "\$PAPER_MIN_MB" -lt 512 \] && PAPER_MIN_MB=512$/p' \
    "$ROOT/start.sh" > "$MEM_BLOCK"
check_at_least "the JVM memory sizing block is still in start.sh" "$(wc -l < "$MEM_BLOCK")" 8
check "…the old fixed -Xms8192 is gone" "$(grep -c '^PAPER_MIN_MB=8192$' "$ROOT/start.sh")" "0"

sed 's|^TOTAL_MEM_MB=.*|TOTAL_MEM_MB=${TOTAL_MEM_MB:-16000}|' "$MEM_BLOCK" > "$WORK/mem-block-src.sh"
sizing() { TOTAL_MEM_MB="$1" bash -c '. "$0"; printf "%s %s\n" "$PAPER_MIN_MB" "$PAPER_MAX_MB"' "$WORK/mem-block-src.sh"; }

for MB_SIZE in 2048 4096 8192 16384 32768; do
    set -- $(sizing "$MB_SIZE")
    XMS="$1"; XMX="$2"
    check "a ${MB_SIZE}MB Space gets Xms<=Xmx (${XMS} <= ${XMX})" \
          "$([ "$XMS" -le "$XMX" ] && echo ok || echo broken)" "ok"
    check "…and a heap that fits the Space" \
          "$([ "$XMX" -ge 1024 ] && [ "$XMX" -le 8192 ] && [ "$XMS" -ge 512 ] && [ "$XMX" -le "$MB_SIZE" ] && echo ok || echo broken)" "ok"
done

# Bucket sync, world copies and log staging should yield CPU/I/O priority to
# Paper; a full snapshot still walks the whole game-data tree, so avoid running
# it as a foreground, high-priority job against the tick loop.
BG_PRIORITY=()
eval "$(awk '/^BG_PRIORITY=\(\)/,/^fi$/ { print }' "$ROOT/start.sh" 2>/dev/null || true)"
check "the sync runs behind a nice/ionice prefix" \
      "$(grep -c 'BG_PRIORITY=(nice' "$ROOT/start.sh")" "2"      # nice alone + nice with ionice
check "…the ionice class is probed before it is used" \
      "$(grep -c 'ionice -c3 true' "$ROOT/start.sh")" "1"
check "the Python uploader runs at background priority" \
      "$(grep -Fc '"${BG_PRIORITY[@]}" python3 "$BUCKET_SYNC_PY"' "$ROOT/start.sh")" "1"
check "the CLI sync and restore run at background priority" \
      "$(grep -Fc '"${BG_PRIORITY[@]}" hf buckets sync' "$ROOT/start.sh")" "2"
check "all full/log staging copies run at background priority" \
      "$(grep -Fc '"${BG_PRIORITY[@]}" cp -a' "$ROOT/start.sh")" "3"
check "full/log staging cleanup also runs at background priority" \
      "$(grep -Fc '"${BG_PRIORITY[@]}" rm -rf "$STAGING"' "$ROOT/start.sh")" "4"
if command -v nice >/dev/null 2>&1; then
    check_at_least "…and the probe really picks a prefix here" "${#BG_PRIORITY[@]}" "1"
fi
check "…which runs a command" "$("${BG_PRIORITY[@]}" true >/dev/null 2>&1; echo $?)" "0"
check "…and each sync prints how long it took (an OK and a FAIL line per loop)" \
      "$(grep -c '(took \${TOOK}s)' "$ROOT/start.sh")" "4"
check "…with the timing taken from the real work" \
      "$(grep -c 'STARTED=\$(date +%s)$' "$ROOT/start.sh")" "2"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
