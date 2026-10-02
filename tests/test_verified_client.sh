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
export SYNC_CONSOLE_LOGS=false   # turned on in section 6

export VERIFIED_CLIENT_KICK_MESSAGE="This server only allows the verified client."
export ONLINE_STATE="$WORK/online-players.txt"
export PLAYERLIST_POLL=1
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
         last_ip_for mask_cmd is_auth_cmd queue_auth auth_seen_recently record_auth_seen \
         flush_pending_auth ip_field hide_ip_for client_field \
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
echo "== 8. the client really boots: its own EPW loader must accept the file =="
if command -v node >/dev/null 2>&1; then
    LOADER_OUT=$(node "$ROOT/tools/run_epw_loader.mjs" "$ROOT/client/1.12.html" 2>&1); LOADER_RC=$?
    check "the client's own loader.wasm accepts the patched client" "$LOADER_RC" "0"
    check "…and reports success" "$(grep -c 'resultSuccess *: true' <<<"$LOADER_OUT")" "1"
    check "…after decompressing classes.wasm" \
          "$(grep -c 'Decompressing classes.wasm\.\.\.$' <<<"$LOADER_OUT")" "1"
    check "…and both asset EPKs" "$(grep -c 'Decompressing assets EPK' <<<"$LOADER_OUT")" "2"

    # negative control: a corrupted container must be rejected by the same test
    node "$ROOT/tools/run_epw_loader.mjs" "$ROOT/client/1.12.html" --dump-epw "$WORK/epw.bin" >/dev/null 2>&1
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
else
    echo "  skip - node is not installed (cannot run the client's own EPW loader)"
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
      "$(grep -c '^ModernGuy	10\.0\.0\.1$' "$IP_MAP")" "1"
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
      "$(grep '^ProxyGuy	10\.0\.0\.3$' "$IP_MAP" | sort -u | wc -l | tr -d ' ')" "1"

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
mc_command() { printf '%s' "There are 2 of a max 20 players online: RconGuy, A_b-c"; }
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

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
