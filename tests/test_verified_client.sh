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
# The brand/UUID are a secret: they come from the environment (the Space passes
# them as secrets) or from the git-ignored .verified-client.env, never from a
# literal in the repository.
[ -z "${VERIFIED_CLIENT_BRAND:-}" ] && [ -s "$ROOT/.verified-client.env" ] && \
    . "$ROOT/.verified-client.env"
EXPECTED_BRAND="${VERIFIED_CLIENT_BRAND:-}"
EXPECTED_UUID="${VERIFIED_CLIENT_UUID:-}"

if [ -z "$EXPECTED_BRAND" ] || [ -z "$EXPECTED_UUID" ]; then
    echo "  skip - no brand configured (that is a valid, safe state: start.sh"
    echo "         then marks nobody as the verified client)."
    echo "         To test the full system: bash tools/setup-verified-client.sh \\"
    echo "             --brand \"<16 chars>\" --gate-user <user> --gate-pass <pass>"
    echo "         or set VERIFIED_CLIENT_BRAND / VERIFIED_CLIENT_UUID."
else
echo "  brand        : $EXPECTED_BRAND"
echo "  uuid         : $EXPECTED_UUID"

# ... and that pair must never have been public
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    HITS=""
    [ -n "$EXPECTED_BRAND" ] && HITS=$(git -C "$ROOT" log --all --format=%h -S"$EXPECTED_BRAND" 2>/dev/null | head -3)
    [ -n "$EXPECTED_UUID" ] && HITS="$HITS $(git -C "$ROOT" log --all --format=%h -S"$EXPECTED_UUID" 2>/dev/null | head -3)"
    check "the configured brand/UUID never appear in git history" "$(echo $HITS | tr -d ' ')" ""
else
    echo "  skip - not a git checkout, cannot check the history"
fi

# the client itself must not be committed either (it carries the brand)
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    check "client/1.12.html is not tracked by git" \
          "$(git -C "$ROOT" ls-files --error-unmatch client/1.12.html >/dev/null 2>&1 && echo tracked || echo untracked)" \
          "untracked"
    check "…and is ignored" \
          "$(git -C "$ROOT" check-ignore -q client/1.12.html && echo ignored || echo not-ignored)" "ignored"
fi

fi   # end: brand configured

if [ ! -s "$ROOT/client/1.12.html" ]; then
    echo "  skip - client/1.12.html is not built here (tools/setup-verified-client.sh)"
else
    CLIENT_INFO=$(python3 "$ROOT/tools/patch_verified_client.py" --check "$ROOT/client/1.12.html" 2>&1)
    CLIENT_UUID=$(sed -n 's/.*brandUUID *: *//p' <<<"$CLIENT_INFO" | head -1)
    CLIENT_BRAND=$(sed -n "s/.*brand *: *'\(.*\)'.*/\1/p" <<<"$CLIENT_INFO" | head -1)
    echo "  client brand : $CLIENT_BRAND"
    echo "  client uuid  : $CLIENT_UUID"
    check "the client reports the configured brand" "$CLIENT_BRAND" "$EXPECTED_BRAND"
    check "…and the configured UUID" "$CLIENT_UUID" "$EXPECTED_UUID"
    check "the client carries the login gate" \
          "$(grep -c 'verified-client gate' "$ROOT/client/1.12.html")" "1"

    for BURNED in "Eaglercraft 1.12" "Eaglercraft[VER]" "EaglercraftX[V2]"; do
        if [ "$BURNED" = "$EXPECTED_BRAND" ]; then
            bad "the client must not use the revoked brand '$BURNED'"
        else
            ok "revoked brand '$BURNED' is not the verified client"
        fi
    done
    if [ "$CLIENT_BRAND" = "EaglercraftX[V2]" ] || [ "$CLIENT_BRAND" = "Eaglercraft[VER]" ]; then
        bad "the released client uses a brand that is public in this repo"
    else
        ok "the released client uses a brand that is not in this repo"
    fi
fi

# a brand that is already public must be refused by the builder
REFUSED=$(python3 "$ROOT/tools/patch_verified_client.py" --brand "Eaglercraft[VER]" \
          /dev/null --output /tmp/should-not-exist.html 2>&1)
check "the builder refuses a public (revoked) brand" \
      "$(grep -c 'refusing brand' <<<"$REFUSED")" "1"

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
export LOGIN_CLIENT_FIELD=""   # set by start.sh from HIDE_VERIFIED_IP
: > "$VERDICT_CACHE"; : > "$IP_MAP"; : > "$PENDING_AUTH"; : > "$AUTH_SEEN"
touch "$BLOG" "$CLIENT_LOG" "$LOGIN_LOG" "$CMD_LOG" "$AUTH_LOG" "$IP_MAP_FILE"
: > "$WORK/kicks"

extract() { awk "/^$1\(\) \{/,/^\}/" "$ROOT/start.sh"; }
FUNCS="$WORK/funcs.sh"
for f in strip_colours bungee_console bungee_alive query_client_brand check_player_client \
         is_real_ip record_ip last_ip_for ips_for ip_report_body write_logger_status \
         mask_cmd write_auth_masked is_auth_cmd queue_auth auth_seen_recently record_auth_seen \
         flush_pending_auth ip_field hide_ip_for client_field forward_ip_setting \
         set_forward_ip_in_listeners read_forward_ip_state write_forward_ip_state \
         verified_client_problem warn_verified_client_problem \
         forward_ip_start_line forward_ip_was_refused apply_forward_ip_choice \
         bungee_restart discover_forward_ip_header forward_ip_probe_once \
         write_forward_ip_probe_py ensure_forward_ip_probe_py \
         set_verdict verdict_for verdict_label is_bypassed enforce_client_policy \
         shared_report_body report_shared_ips hf_push_logs hf_push_saves \
         is_online mark_online mark_offline record_login record_logout \
         playerlist_names playerlist_check playerlist_loop \
         bucket_id_of bucket_prefix_of bucket_sync_dir bucket_write_probe bucket_py \
         write_bucket_sync_py ensure_bucket_sync_py \
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

# the clients handed out before (and public in the git history) are just "some
# other Eaglercraft client" now - they cannot make anybody look like the owner
brand_answer "Eaglercraft[VER]" "51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"
login OldV1 8.8.8.1
sleep 4.5
check "the revoked V1 client is not verified" \
      "$(grep -c '| VERIFY | OldV1 | 8.8.8.1 | OTHER EAGLERCRAFT CLIENT | brand=Eaglercraft\[VER\] |' "$LOGIN_LOG")" "1"
brand_answer "EaglercraftX[V2]" "355d0b9f-14ce-359f-8c9f-97cc1a7c92ca"
login OldV2 8.8.8.2
sleep 4.5
check "the revoked V2 client is not verified either" \
      "$(grep -c '| VERIFY | OldV2 | 8.8.8.2 | OTHER EAGLERCRAFT CLIENT | brand=EaglercraftX\[V2\] |' "$LOGIN_LOG")" "1"
check "…and nothing in the logs calls either of them the verified client" \
      "$(grep -c 'VERIFIED CLIENT' "$LOGIN_LOG")" "0"

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
check "…but the command is still recorded (masked)" "$(grep -c '| /login \*\*\*\*\*\*\*\* |' "$AUTH_LOG")" "1"
check "…and marked as unconfigured" "$(grep -c 'client=UNCONFIGURED' "$AUTH_LOG")" "1"
printf '%s\t%s\t%s\n' "$(date +%s)" QueuedGuy "/login queuedpw" >> "$PENDING_AUTH"
set_verdict QueuedGuy UNVERIFIED
flush_pending_auth
check "…and a command queued earlier is masked too" \
      "$(grep -c '| QueuedGuy | .* | /login \*\*\*\*\*\*\*\* | client=UNCONFIGURED' "$AUTH_LOG")" "1"
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

# --------------------------------------------------------------------------- #
echo "== 6. every log reaches the bucket =="
export BACKEND_DIR="$WORK/backend"
export SEC_DIR="$BACKEND_DIR/security-logs"
export PRIV_DIR="$BACKEND_DIR/private-logs"
export HF_BUCKET_HANDLE="hf://buckets/test/1.12"
export FULL_STAGING="$WORK/stage-full"
export LOG_STAGING="$WORK/stage-logs"
export SAVE_DIRS="security-logs private-logs"
mkdir -p "$SEC_DIR" "$PRIV_DIR"
touch "$SEC_DIR/logins.log" "$SEC_DIR/commands.log" "$SEC_DIR/client-checks.log" \
      "$SEC_DIR/shared-ips.txt" "$PRIV_DIR/auth.log" "$PRIV_DIR/player-ips.log"
HF_CALLS="$WORK/hf-calls.txt"; HF_STAGED="$WORK/hf-staged.txt"
: > "$HF_CALLS"; : > "$HF_STAGED"
hf() {   # fake the HF CLI: record the call and the staged files
    printf 'hf %s\n' "$*" >> "$HF_CALLS"
    [ -d "${3:-}" ] && find "$3" -type f -printf '%P\n' | sort >> "$HF_STAGED"
    return 0
}

log_sync_cmd() { grep -m1 'buckets sync' "$HF_CALLS"; }

: > "$HF_CALLS"; : > "$HF_STAGED"
SYNC_PRIVATE_LOGS=true hf_push_logs
check "the log sync pushes to the bucket" \
      "$(grep -c "hf buckets sync $LOG_STAGING $HF_BUCKET_HANDLE/game-data" "$HF_CALLS")" "1"
check "the log sync never uses --delete" "$(grep -c -- '--delete' "$HF_CALLS")" "0"
check "security-logs are staged" "$(grep -c '^security-logs/logins.log$' "$HF_STAGED")" "1"
check "commands.log is staged" "$(grep -c '^security-logs/commands.log$' "$HF_STAGED")" "1"
check "client-checks.log is staged" "$(grep -c '^security-logs/client-checks.log$' "$HF_STAGED")" "1"
check "shared-ips.txt is staged" "$(grep -c '^security-logs/shared-ips.txt$' "$HF_STAGED")" "1"
check "auth.log (full /login) is staged" "$(grep -c '^private-logs/auth.log$' "$HF_STAGED")" "1"
check "player-ips.log (the hidden IPs) is staged" "$(grep -c '^private-logs/player-ips.log$' "$HF_STAGED")" "1"
check "the log staging dir is cleaned up" "$([ -d "$LOG_STAGING" ] && echo yes || echo no)" "no"

: > "$HF_CALLS"; : > "$HF_STAGED"
SYNC_PRIVATE_LOGS=false hf_push_logs
check "SYNC_PRIVATE_LOGS=false keeps auth.log out of the bucket" \
      "$(grep -c '^private-logs/' "$HF_STAGED")" "0"
check "…and still uploads the sanitised logs" "$(grep -c '^security-logs/logins.log$' "$HF_STAGED")" "1"

# raw console tails, so a boot failure is readable without Space access
export CONSOLE_LOG_LINES=1000
printf 'line1\n%s\n' "$(seq 1 5 | tr '\n' ' ')" > /tmp/paper.log
printf 'bungee line\n' > /tmp/bungee.log
: > "$HF_STAGED"
SYNC_CONSOLE_LOGS=true SYNC_PRIVATE_LOGS=true hf_push_logs
check "paper.log tail is uploaded" "$(grep -c '^logs/paper.log$' "$HF_STAGED")" "1"
check "bungee.log tail is uploaded" "$(grep -c '^logs/bungee.log$' "$HF_STAGED")" "1"
: > "$HF_STAGED"
SYNC_CONSOLE_LOGS=false SYNC_PRIVATE_LOGS=true hf_push_logs
check "SYNC_CONSOLE_LOGS=false skips the console tails" "$(grep -c '^logs/' "$HF_STAGED")" "0"

: > "$HF_CALLS"; : > "$HF_STAGED"
hf_push_saves
check "the full game-data sync still mirrors with --delete" "$(grep -c -- '--delete' "$HF_CALLS")" "1"
check "the full sync includes security-logs" "$(grep -c '^security-logs/logins.log$' "$HF_STAGED")" "1"
check "the full sync includes private-logs" "$(grep -c '^private-logs/auth.log$' "$HF_STAGED")" "1"
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
check "the shutdown pushes the last log lines" \
      "$(grep -c 'hf_push_logs     # make sure the last log lines reached the bucket' "$ROOT/start.sh")" "1"

# --------------------------------------------------------------------------- #
echo "== 7. the Space only needs a couple of files =="
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
echo "a login"    > "$STAGING/security-logs/logins.log"
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
check "…the security log lands in the bucket" \
      "$(grep -c '^add tester/1.12 game-data/security-logs/logins.log ' "$FAKE_HF_LOG")" "1"
check "…the private log (passwords) lands in the bucket too" \
      "$(grep -c '^add tester/1.12 game-data/private-logs/auth.log ' "$FAKE_HF_LOG")" "1"
check "…and the sync line says which path was used" \
      "$(grep -c 'bucket-sync:' "$WORK/sync.out")" "1"
check "BUCKET_VIA reports python for the caller" "$BUCKET_VIA" "python"

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
    return 0
}

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

ip_report_body "$IP_MAP" "$SEC_DIR/ip-report.log" no
check "the report names both Alice IPs, with where each came from" \
      "$(grep -c '^  Alice -> 1.2.3.4 (paper) x1$' "$SEC_DIR/ip-report.log")$(grep -c '^  Alice -> 9.9.9.9 (bungee-handshake) x1$' "$SEC_DIR/ip-report.log")" "11"
check "…and flags the account pair behind one IP" \
      "$(grep -c '^  1.2.3.4 -> Alice Bob$' "$SEC_DIR/ip-report.log")" "1"
check "…but never 'unknown' as an address" "$(grep -c 'unknown' "$SEC_DIR/ip-report.log")" "0"

# the synced copy must not carry the owner's addresses
: > "$IP_MAP"
record_ip CreppyBitch 7.7.7.7 paper
record_ip Alice 1.2.3.4 paper
: > "$VERDICT_CACHE"; set_verdict CreppyBitch VERIFIED
ip_report_body "$IP_MAP" "$SEC_DIR/ip-report.log" yes
check "the synced IP report has the other players" "$(grep -c 'Alice' "$SEC_DIR/ip-report.log")" "1"
check "…and not the owner" "$(grep -c 'CreppyBitch\|7\.7\.7\.7' "$SEC_DIR/ip-report.log")" "0"
ip_report_body "$IP_MAP" "$PRIV_DIR/ip-report-private.log" no
check "the private IP report still has the owner (that is how you check it)" \
      "$(grep -c '^  CreppyBitch -> 7.7.7.7 (paper) x1$' "$PRIV_DIR/ip-report-private.log")" "1"
check "an empty map still produces a report" \
      "$( : > "$WORK/empty-map.tsv"; ip_report_body "$WORK/empty-map.tsv" "$WORK/empty-report.txt" no; grep -c 'no IPs recorded yet' "$WORK/empty-report.txt" )" \
      "1"

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
                     ("forward_ip_probe.py", "FORWARD_IP_PROBE_EOF")]:
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
                      ("forward_ip_probe.py", "FORWARD_IP_PROBE_EOF")]
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
printf '%s | LOGIN | Alice | 1.2.3.4\n' "$(date '+%F %T')" > "$LOGIN_LOG"
printf 'x | Alice | 1.2.3.4 | /login pw | client=OTHER EAGLERCRAFT CLIENT\n' >> "$CMD_LOG"
PLAYERLIST_LAST="18:00:00 got: There are 1 of a max 20 players online: Alice"
FORWARD_IP="auto"; FORWARD_IP_HEADER=""; SEC_DIR="$WORK/security"; PRIVATE_IP_LOG=true
write_logger_status
STATUS="$SEC_DIR/logger-status.log"
check "the status file is written" "$([ -s "$STATUS" ] && echo yes)" "yes"
check "…with the paper line count" "$(grep -c '^paper.log      : 1 lines' "$STATUS")" "1"
check "…the login count" "$(grep -c '^logins.log     : 1 logins, 0 logouts' "$STATUS")" "1"
check "…the last player-list answer" "$(grep -c '^playerlist     : 18:00:00 got: There are 1' "$STATUS")" "1"
check "…the forward_ip setting" "$(grep -c '^real client IPs: ' "$STATUS")" "1"
check_at_least "…and the raw lines the parser sees" "$(grep -c 'Alice\[\|logged in with entity id' "$STATUS")" "1"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
