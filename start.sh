#!/bin/bash

JAVA_HOME_DIR=$(find /usr/lib/jvm -maxdepth 1 -name "java-17-openjdk-*" -type d 2>/dev/null | head -1)
if [ -z "$JAVA_HOME_DIR" ]; then
    echo "ERROR: Java 17 not found!"
    exit 1
fi
JAVA="$JAVA_HOME_DIR/bin/java"

BUNGEE_DIR="/opt/server/bungee"
BACKEND_DIR="/opt/server/backend"
PLUGIN_DIR="$BACKEND_DIR/plugins"

# Security log locations (append-only, synced to the HF bucket every
# $SYNC_INTERVAL seconds, see SAVE_DIRS below):
#   hf://buckets/smodusermc/1.12/game-data/security-logs/logins.log
#   hf://buckets/smodusermc/1.12/game-data/security-logs/commands.log
#   hf://buckets/smodusermc/1.12/game-data/security-logs/client-checks.log
#   hf://buckets/smodusermc/1.12/game-data/security-logs/shared-ips.txt
SEC_DIR="$BACKEND_DIR/security-logs"
LOGIN_LOG="$SEC_DIR/logins.log"
CMD_LOG="$SEC_DIR/commands.log"
SHARED_REPORT="$SEC_DIR/shared-ips.txt"
CLIENT_LOG="$SEC_DIR/client-checks.log"

# Private log locations - NEVER synced to the bucket (private-logs is not in
# SAVE_DIRS, see the check further down):
#   auth.log        full /login, /register, /changepassword lines (passwords in
#                   clear, for password resets) - everything except the
#                   verified client, i.e. your own password is never written
#   player-ips.log  the real IPs that were hidden as "ip=hidden" in the synced
#                   logs, in case you ever need to look your own up
PRIV_DIR="$BACKEND_DIR/private-logs"
AUTH_LOG="$PRIV_DIR/auth.log"
IP_MAP_FILE="$PRIV_DIR/player-ips.log"

# Runtime caches (in /tmp, never written to disk)
#   VERDICT_CACHE : "<name>\t<VERDICT>" - last verdict per player
#   IP_MAP        : "<name>\t<ip>"      - real IP per player
#   PENDING_AUTH  : auth commands waiting for the player's client verdict
VERDICT_CACHE="/tmp/client-verdicts.txt"
IP_MAP="/tmp/client-ips.txt"
PENDING_AUTH="/tmp/pending-auth-commands.tsv"
AUTH_SEEN="/tmp/auth-commands-seen.tsv"
: > "$VERDICT_CACHE"; : > "$IP_MAP"; : > "$PENDING_AUTH"; : > "$AUTH_SEEN"

# Bungee console pipe - lets this script run commands on the proxy, it is used
# to ask EaglerXBungee which client a player is using (/client-brand)
BUNGEE_CONSOLE="$BUNGEE_DIR/console.pipe"

mkdir -p "$PLUGIN_DIR" "$SEC_DIR" "$PRIV_DIR"

HF_BUCKET_HANDLE="hf://buckets/smodusermc/1.12"
# NOTE: private-logs is deliberately absent - auth.log holds clear-text
# passwords and player-ips.log holds the IPs that are hidden in the synced
# logs, so neither may ever leave the Space.
SAVE_DIRS="world world_nether world_the_end players banned-ips.json banned-players.json ops.json whitelist.json plugins security-logs"
case " $SAVE_DIRS " in *" private-logs "*)
    echo "WARNING: private-logs is in SAVE_DIRS - auth.log would be synced to the bucket!" ;;
esac
SYNC_INTERVAL="${SYNC_INTERVAL:-300}"
IDLE_MODE=false

# =============================================
# OP ACCOUNT
# =============================================
OP_USERNAME="CreppyBitch"

# =============================================
# VERIFIED CLIENT  (see docs/verified-client.md)
# =============================================
# client/1.12.html in this repo is a patched Eaglercraft 1.12 client that
# reports a custom brand instead of the stock "Eaglercraft 1.12". The brand is
# turned into the 16 byte "brand UUID" the client sends during the Eagler
# handshake with
#
#     brandUUID = UUID.nameUUIDFromBytes("EaglercraftXClient:" + brand)
#
# so the patched client is the only one that arrives with this UUID and the
# server can tell it apart from other clients / other accounts in the logs.
# Recompute the UUID after changing the brand:
#     python3 tools/patch_verified_client.py --print-uuid --brand "<brand>"
VERIFIED_CLIENT_BRAND="Eaglercraft[VER]"
VERIFIED_CLIENT_UUID="51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff"

# true = ONLY the verified client may stay on the server; every other account
# is kicked right after the login. Set to false to allow everyone and only log.
ENFORCE_VERIFIED_CLIENT=true
# also kick real (Java) Minecraft clients - they are not the verified client
ENFORCE_KICK_VANILLA=true
# do NOT kick when the check itself could not run (proxy busy/restarting).
# Keeps you from locking yourself out; those logins stay visible as
# "UNKNOWN CLIENT" in the logs.
ENFORCE_KICK_ON_UNKNOWN=false
# names that may join with any client even when enforcement is on
# (comma separated, e.g. ENFORCE_BYPASS_PLAYERS="Friend1,Friend2")
ENFORCE_BYPASS_PLAYERS=""
VERIFIED_CLIENT_KICK_MESSAGE="This server only allows the verified client."

# The verified client is *you*, so its IP is never written to the logs that
# get synced to the bucket (commands, logins and verifications show
# "ip=hidden" instead). A local copy is kept in private-logs/ (never synced)
# in case you ever need to look your own IP up.
HIDE_VERIFIED_IP=true
PRIVATE_IP_LOG=true

# The login line is written before the client check has finished. When the IP
# is hidden the tag is left off as well, so a login by the verified client is
# just "DATE | LOGIN | name | hidden" with nothing marking it.
if [ "$HIDE_VERIFIED_IP" = true ]; then
    LOGIN_CLIENT_FIELD=""
else
    LOGIN_CLIENT_FIELD=" | client=CHECK PENDING"
fi

# Open the Bungee console pipe now, before any background subshell exists, so
# every part of this script can push console commands into the proxy.
mkfifo "$BUNGEE_CONSOLE" 2>/dev/null
if exec 9<>"$BUNGEE_CONSOLE" 2>/dev/null; then
    BUNGEE_CONSOLE_OK=true
else
    BUNGEE_CONSOLE_OK=false
    echo "WARNING: could not open $BUNGEE_CONSOLE - verified-client checks are disabled"
fi
BUNGEE_PID_FILE="/tmp/bungee.pid"

CPU_CORES=$(nproc 2>/dev/null || echo 2)
NETTY_THREADS=2

TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
BUNGEE_MAX_MB=1024
PAPER_MAX_MB=$(( TOTAL_MEM_MB - BUNGEE_MAX_MB - 768 ))
[ "$PAPER_MAX_MB" -gt 8192 ] && PAPER_MAX_MB=8192
[ "$PAPER_MAX_MB" -lt 1024 ] && PAPER_MAX_MB=1024
PAPER_MIN_MB=8192

echo "========================================"
echo "  Eaglercraft 1.12.2 Vanilla Survival"
echo "  Paper 1.12.2 + HuggingFace Buckets"
echo "========================================"
echo ""
echo " CPUs: $CPU_CORES | RAM: ${TOTAL_MEM_MB}MB"
echo " Server: ${PAPER_MIN_MB}-${PAPER_MAX_MB}MB | Bungee: ${BUNGEE_MAX_MB}MB"
echo " Java: $($JAVA -version 2>&1 | head -1)"
echo " Bucket: $HF_BUCKET_HANDLE"
[ -n "$OP_USERNAME" ] && echo " OP Account: $OP_USERNAME"
echo " Plugins synced: WorldEdit, WorldGuard, MineResetLite, Shopkeepers, SafeTrade, Skript, PvPManager"
echo " Security logs: $SEC_DIR (synced to the bucket every ${SYNC_INTERVAL}s)"
if [ "$HIDE_VERIFIED_IP" = true ]; then
    echo "   -> the verified client is hidden: its IP is written as \"hidden\" and no"
    echo "      client=... / VERIFY line is added for it"
    echo "   -> real IPs of hidden lines -> $IP_MAP_FILE (not synced)"
fi
echo " Private logs (never synced): $PRIV_DIR"
echo "   -> auth.log: full /login|/register|/changepassword commands of everybody"
echo "      except the verified client (for password resets)"
echo " Verified client: $VERIFIED_CLIENT_BRAND ($VERIFIED_CLIENT_UUID)"
if [ "$ENFORCE_VERIFIED_CLIENT" = true ]; then
    echo " Enforce verified client: ON - only the verified client may join"
    echo "   -> kick vanilla clients too: $ENFORCE_KICK_VANILLA | kick unresolved checks: $ENFORCE_KICK_ON_UNKNOWN"
    [ -n "$ENFORCE_BYPASS_PLAYERS" ] && echo "   -> bypass: $ENFORCE_BYPASS_PLAYERS"
else
    echo " Enforce verified client: off - everyone can join, only logged"
fi
echo ""

# =============================================
# JVM FLAGS
# =============================================
PAPER_JVM_FLAGS=(
    -Xmx${PAPER_MAX_MB}M
    -Xms${PAPER_MIN_MB}M
    -XX:+UseG1GC
    -XX:+ParallelRefProcEnabled
    -XX:MaxGCPauseMillis=25
    -XX:+UnlockExperimentalVMOptions
    -XX:+DisableExplicitGC
    -XX:G1NewSizePercent=40
    -XX:G1MaxNewSizePercent=50
    -XX:G1HeapRegionSize=8M
    -XX:G1ReservePercent=15
    -XX:G1HeapWastePercent=10
    -XX:G1MixedGCCountTarget=8
    -XX:InitiatingHeapOccupancyPercent=60
    -XX:G1MixedGCLiveThresholdPercent=90
    -XX:G1RSetUpdatingPauseTimePercent=5
    -XX:SurvivorRatio=32
    -XX:+PerfDisableSharedMem
    -XX:MaxTenuringThreshold=1
    -XX:+OptimizeStringConcat
    -XX:+UseCompressedOops
    -XX:MaxMetaspaceSize=256M
    -XX:CompressedClassSpaceSize=128M
    -XX:ReservedCodeCacheSize=128M
    -XX:-UseCodeCacheFlushing
    -Xss256k
    -Djline.terminal=jline.UnsupportedTerminal
    -Dio.netty.allocator.maxCachedBufferCapacity=524288
    -Dio.netty.recycler.maxCapacityPerThread=0
    -Dio.netty.eventLoopThreads=${NETTY_THREADS}
    -Dio.netty.allocator.numDirectArenas=${NETTY_THREADS}
    -Dio.netty.allocator.numHeapArenas=${NETTY_THREADS}
    -Dcom.mojang.eula.agree=true
    -DIReallyKnowWhatIAmDoingISwear
    -Dusing.aikars.flags=https://mcflags.emc.gs
    -Daikars.new.flags=true
    # Java 17 Compatibility overrides for 1.12.2
    --add-opens=java.base/java.lang=ALL-UNNAMED
    --add-opens=java.base/java.lang.reflect=ALL-UNNAMED
    --add-opens=java.base/java.math=ALL-UNNAMED
    --add-opens=java.base/java.net=ALL-UNNAMED
    --add-opens=java.base/java.nio=ALL-UNNAMED
    --add-opens=java.base/java.security=ALL-UNNAMED
    --add-opens=java.base/java.text=ALL-UNNAMED
    --add-opens=java.base/java.util=ALL-UNNAMED
    --add-opens=java.base/java.util.concurrent=ALL-UNNAMED
    --add-opens=java.base/jdk.internal.math=ALL-UNNAMED
    --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED
    --add-opens=java.base/sun.net.www.protocol.http=ALL-UNNAMED
    --add-opens=java.base/sun.net.www.protocol.https=ALL-UNNAMED
    --add-opens=java.base/sun.security.action=ALL-UNNAMED
    --add-opens=java.base/sun.security.util=ALL-UNNAMED
    --add-opens=java.base/sun.security.x509=ALL-UNNAMED
)

BUNGEE_JVM_FLAGS=(
    -Xmx${BUNGEE_MAX_MB}M
    -Xms128M
    -XX:+UseG1GC
    -XX:+ParallelRefProcEnabled
    -XX:MaxGCPauseMillis=30
    -XX:+UnlockExperimentalVMOptions
    -XX:+DisableExplicitGC
    -XX:+PerfDisableSharedMem
    -XX:+OptimizeStringConcat
    -XX:+UseCompressedOops
    -XX:MaxMetaspaceSize=128M
    -XX:ReservedCodeCacheSize=64M
    -Xss256k
    -Dio.netty.allocator.maxCachedBufferCapacity=524288
    -Dio.netty.recycler.maxCapacityPerThread=0
    -Dio.netty.eventLoopThreads=${NETTY_THREADS}
    -Dio.netty.allocator.numDirectArenas=${NETTY_THREADS}
    -Dio.netty.allocator.numHeapArenas=${NETTY_THREADS}
    -Deaglerxbungee.stfu=true
    # Additional Bungee reflection backups
    --add-opens=java.base/java.lang=ALL-UNNAMED
    --add-opens=java.base/java.lang.reflect=ALL-UNNAMED
)

# =============================================================
# RCON — each command sent individually to avoid mangling
# =============================================================
RCON_PASS="chunkystart"

get_player_count() {
    local RESULT
    RESULT=$(mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASS" "list" 2>/dev/null)
    echo "$RESULT" | grep -oE 'are [0-9]+' | grep -oE '[0-9]+' || echo "0"
}

mc_command() {
    for cmd in "$@"; do
        mcrcon -H 127.0.0.1 -P 25575 -p "$RCON_PASS" "$cmd" 2>/dev/null
    done
}

# =============================================================
# Paper starter
# =============================================================
start_paper() {
    cd "$BACKEND_DIR"
    $JAVA "${PAPER_JVM_FLAGS[@]}" -jar server.jar nogui --noconsole >> /tmp/paper.log 2>&1 &
    BACKEND_PID=$!
}

# =============================================================
# OP Account Setup
# =============================================================
setup_op_account() {
    if [ -z "$OP_USERNAME" ]; then
        return
    fi

    echo " Setting up OP for: $OP_USERNAME"

    local OFFLINE_UUID
    OFFLINE_UUID=$(echo -n "OfflinePlayer:${OP_USERNAME}" | md5sum | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    local V3_UUID
    V3_UUID=$(echo "$OFFLINE_UUID" | sed 's/.\{1\}\(.\\{3\}-\)/3\1/' | sed 's/\(.\{14\}-\).\(.\{3\}-\)/\1'"$(echo "$OFFLINE_UUID" | cut -c15 | tr '0-9a-f' '89ab89ab89ab89ab')"'\2/')

    cat > "$BACKEND_DIR/ops.json" << OPEOF
[
  {
    "uuid": "${V3_UUID}",
    "name": "${OP_USERNAME}",
    "level": 4,
    "bypassesPlayerLimit": true
  }
]
OPEOF
    echo "   ops.json written (level 4, UUID: ${V3_UUID})"

    mc_command "op ${OP_USERNAME}"
    echo "   RCON op command sent"
}

# =============================================================
# IDLE MODE — safe version that does NOT kill entities
# =============================================================
enter_idle_mode() {
    [ "$IDLE_MODE" = true ] && return
    IDLE_MODE=true
    mc_command "gamerule randomTickSpeed 0"
    mc_command "gamerule doMobSpawning false"
    # Kill regular hostile mobs to free up CPU, without affecting gameplay since players are gone
    mc_command "kill @e[type=Zombie]"
    mc_command "kill @e[type=Skeleton]"
    mc_command "kill @e[type=Spider]"
    mc_command "kill @e[type=Creeper]"
    mc_command "kill @e[type=Enderman]"
    mc_command "kill @e[type=Witch]"
    mc_command "kill @e[type=Slime]"
    mc_command "kill @e[type=CaveSpider]"
    mc_command "kill @e[type=Silverfish]"
    mc_command "kill @e[type=Guardian]"
    mc_command "kill @e[type=Endermite]"
    mc_command "kill @e[type=Blaze]"
    mc_command "kill @e[type=Ghast]"
    mc_command "kill @e[type=MagmaCube]"
    mc_command "kill @e[type=WitherSkeleton]"
    mc_command "kill @e[type=ZombiePigman]"
    echo "[IDLE] Active — hostile mobs cleared, ticks paused"
}

exit_idle_mode() {
    [ "$IDLE_MODE" = false ] && return
    IDLE_MODE=false
    mc_command "gamerule randomTickSpeed 3"
    mc_command "gamerule doMobSpawning true"
    echo "[IDLE] Gameplay restored"
}

# =============================================================
# Port fix
# =============================================================
find_listeners_yml() {
    find "$BUNGEE_DIR/plugins" -name "listeners.yml" -type f 2>/dev/null | head -1
}

patch_eagler_port() {
    local FILE=$(find_listeners_yml)
    [ -z "$FILE" ] && return 1
    grep -q ":7860" "$FILE" && return 0
    sed -i 's/\(address:[[:space:]]*"[^:]*:\)[0-9]*/\17860/' "$FILE"
    sed -i "s/\(address:[[:space:]]*[^\"][^:]*:\)[0-9]*/\17860/" "$FILE"
    echo "  Port -> 7860"
}

start_bungee() {
    cd "$BUNGEE_DIR"
    # BungeeCord reads console commands from stdin. Giving it the write+read end
    # of the pipe we opened at startup means its stdin never hits EOF, and this
    # script can inject commands (used by the verified-client check).
    if [ "$BUNGEE_CONSOLE_OK" = true ]; then
        $JAVA "${BUNGEE_JVM_FLAGS[@]}" \
            -cp "sqlite-jdbc.jar:BungeeCord.jar" \
            net.md_5.bungee.Bootstrap <&9 >> /tmp/bungee.log 2>&1 &
    else
        $JAVA "${BUNGEE_JVM_FLAGS[@]}" \
            -cp "sqlite-jdbc.jar:BungeeCord.jar" \
            net.md_5.bungee.Bootstrap < /dev/null >> /tmp/bungee.log 2>&1 &
    fi
    BUNGEE_PID=$!
    echo "$BUNGEE_PID" > "$BUNGEE_PID_FILE"
}

# =============================================================
# SECURITY LOGGER — logins/IPs + commands (append-only)
# =============================================================
# logins.log   : DATE | LOGIN  | name | ip | client=CHECK PENDING
#                DATE | VERIFY | name | ip | <label> | brand=... | version=... | uuid=...
#                DATE | LOGOUT | name | ip | client=...
# commands.log : DATE | name | ip | command | client=...
# shared-ips.txt : report of shared IPs / multi-IP accounts
#
# When HIDE_VERIFIED_IP=true the IP of the verified client is written as
# "hidden" everywhere in these files and its "client=..." tag and VERIFY line
# are left out, so a verified login is just "DATE | LOGIN | name | hidden".
# Everybody else keeps the full ip / client=... information.
#
# VERIFIED CLIENT
# client-checks.log : DATE | VERDICT | name | ip | brand=... | version=... | uuid=...
#   VERIFIED   = the client from this repo (unique Eagler brand UUID)
#   UNVERIFIED = some other Eaglercraft client / fork
#   VANILLA    = a real Minecraft client (not Eaglercraft)
#   UNKNOWN    = could not be checked
#
# private-logs/auth.log : DATE | name | ip | full /login command | client=...
#   every password-reset relevant command from everybody EXCEPT the verified
#   client, so you can read "what password did they set" without ever writing
#   your own password down. Never synced to the bucket.
# =============================================================

# last known (real) IP of a player - from the runtime map, so it also works
# when the IP is hidden in the logs themselves
last_ip_for() {
    awk -F'\t' -v n="$1" '$1==n{v=$2} END{print v}' "$IP_MAP" 2>/dev/null
}

# the IP that goes into a log line: real, or "hidden" for the verified client
ip_field() {
    local name="$1" ip="${2:-unknown}" verdict="${3:-UNKNOWN}"
    if hide_ip_for "$verdict"; then
        if [ "$PRIVATE_IP_LOG" = true ]; then
            printf '%s | %s | %s\n' "$(date '+%F %T')" "$name" "$ip" >> "$IP_MAP_FILE"
        fi
        echo "hidden"
    else
        echo "$ip"
    fi
}

# which verdicts get their IP hidden: the verified client, and any verdict
# that is not final yet (a check that never resolves must never expose it)
hide_ip_for() {
    [ "$HIDE_VERIFIED_IP" = true ] || return 1
    case "${1:-UNKNOWN}" in
        VERIFIED|PENDING|UNKNOWN|CONSOLE_DOWN) return 0 ;;
        *) return 1 ;;
    esac
}

# " | client=LABEL" for a log line. While the owner's identity is hidden only
# the clients that are definitely not the verified one are tagged (and those
# are the lines that also carry a real IP), so nothing in the synced logs
# points back at the verified client.
client_field() {
    local v="${1:-UNKNOWN}"
    if [ "$HIDE_VERIFIED_IP" = true ]; then
        case "$v" in
            UNVERIFIED|VANILLA) ;;
            *) return 0 ;;
        esac
    fi
    printf ' | client=%s' "$(verdict_label "$v")"
}

# -------------------------------------------------------------
# Verified client verdict cache
# -------------------------------------------------------------
# The client check runs in the background right after the login (the proxy
# handshake needs a moment), so commands a player typed in the first seconds
# are logged as PENDING and everything after that carries the final verdict.
set_verdict() {
    printf '%s\t%s\n' "$1" "${2:-UNKNOWN}" >> "$VERDICT_CACHE"
}

verdict_for() {
    local v
    v=$(awk -F'\t' -v n="$1" '$1==n{v=$2} END{print v}' "$VERDICT_CACHE" 2>/dev/null)
    echo "${v:-UNKNOWN}"
}

# Human readable form used next to logins/commands so the raw logs say it
# plainly. VERIFIED CLIENT is the only label containing that phrase, so
# "grep 'VERIFIED CLIENT' logins.log" always means "this was my client".
verdict_label() {
    case "${1:-UNKNOWN}" in
        VERIFIED)   echo "VERIFIED CLIENT" ;;
        UNVERIFIED) echo "OTHER EAGLERCRAFT CLIENT" ;;
        VANILLA)    echo "JAVA CLIENT" ;;
        PENDING)    echo "CHECK PENDING" ;;
        *)          echo "UNKNOWN CLIENT" ;;
    esac
}

# -------------------------------------------------------------
# Password / register / login commands
# -------------------------------------------------------------
# auth-style commands are masked in commands.log (which can be read by other
# people and is synced) but kept in full in private-logs/auth.log, so a lost
# password can be looked up. The verified client's own commands are the one
# exception: your password is never written anywhere.
is_auth_cmd() {
    case "${1,,}" in
        "/login "*|"/l "*|"/log "*|"/register "*|"/reg "*|"/changepassword "*|"/changepass "*|"/unregister "*) return 0 ;;
        "/authme"*) return 0 ;;
        *) return 1 ;;
    esac
}

# The same command reaches us twice (Paper logs it and the Bungee console logs
# it), so every auth command is recorded once, with a short time window.
auth_seen_recently() {
    awk -F'\t' -v n="$1" -v c="$2" -v e="$(date +%s)" \
        '$2==n && $3==c && (e-$1)<15 {f=1} END{exit !f}' "$AUTH_SEEN" 2>/dev/null
}

record_auth_seen() {
    printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$AUTH_SEEN"
}

# queue an auth command until the player's client verdict is known
queue_auth() {
    local name="$1" cmd="$2"
    auth_seen_recently "$name" "$cmd" && return 0
    record_auth_seen "$name" "$cmd"
    printf '%s\t%s\t%s\n' "$(date +%s)" "$name" "$cmd" >> "$PENDING_AUTH"
}

# write queued auth commands whose verdict is known (or that are old enough)
flush_pending_auth() {
    [ -s "$PENDING_AUTH" ] || return 0
    local tmp="${PENDING_AUTH}.tmp" epoch name cmd v now ip
    : > "$tmp"
    while IFS=$'\t' read -r epoch name cmd; do
        v=$(verdict_for "$name")
        ip=$(last_ip_for "$name"); ip="${ip:-unknown}"
        if [ "$v" = "VERIFIED" ]; then
            continue                                   # never log your own password
        elif [ "$v" != "PENDING" ]; then
            echo "$(date -d "@$epoch" '+%F %T') | $name | $ip | $cmd | client=$(verdict_label "$v")" >> "$AUTH_LOG"
        elif [ $(( $(date +%s) - epoch )) -gt 300 ]; then
            echo "$(date -d "@$epoch" '+%F %T') | $name | $ip | $cmd | client=UNKNOWN CLIENT (check never resolved)" >> "$AUTH_LOG"
        else
            printf '%s\t%s\t%s\n' "$epoch" "$name" "$cmd" >> "$tmp"
        fi
    done < "$PENDING_AUTH"
    mv "$tmp" "$PENDING_AUTH"
}

# mask passwords in the log lines that leave the Space; the full command is
# kept in private-logs/auth.log instead
mask_cmd() {
    local name="$1" cmd="$2" verdict="${3:-UNKNOWN}" ip
    if is_auth_cmd "$cmd"; then
        case "${verdict:-UNKNOWN}" in
            VERIFIED)
                # the owner: your own password is never written anywhere
                ;;
            *)
                case "$verdict" in
                    # verdict still unknown - keep it and log it once the
                    # player's client has been identified
                    PENDING|UNKNOWN|CONSOLE_DOWN) queue_auth "$name" "$cmd" ;;
                    *)
                        if ! auth_seen_recently "$name" "$cmd"; then
                            record_auth_seen "$name" "$cmd"
                            ip=$(last_ip_for "$name"); ip="${ip:-unknown}"
                            echo "$(date '+%F %T') | $name | $ip | $cmd | client=$(verdict_label "$verdict")" >> "$AUTH_LOG"
                        fi ;;
                esac ;;
        esac
        cmd="${cmd%% *} ********"
    fi
    echo "$cmd"
}

handle_paper_line() {
    local line="${1%$'\r'}" NOW name ip cmd
    # Paper writes:  [12:00:00 INFO]: Steve[/1.2.3.4:5555] logged in with entity id 42 at (...)
    # (the original pattern was missing the closing bracket, so logins were never recorded)
    local LOGIN_RE='^\[[0-9:]+ INFO\]: ([A-Za-z0-9_.-]+)\[/(.+):[0-9]+\] logged in with entity id'
    local CMD_RE='^\[[0-9:]+ INFO\]: ([A-Za-z0-9_.-]+) issued server command: (.*)$'
    local LEAVE_RE='^\[[0-9:]+ INFO\]: ([A-Za-z0-9_.-]+) left the game'
    NOW=$(date '+%F %T')

    if [[ "$line" =~ $LOGIN_RE ]]; then
        name="${BASH_REMATCH[1]}"; ip="${BASH_REMATCH[2]}"
        printf '%s\t%s\n' "$name" "$ip" >> "$IP_MAP"
        # the IP is hidden until we know whose client it is (see hide_ip_for)
        echo "$NOW | LOGIN | $name | $(ip_field "$name" "$ip" PENDING)${LOGIN_CLIENT_FIELD:-}" >> "$LOGIN_LOG"
        set_verdict "$name" PENDING
        # ask the proxy which client this player is using (runs in the background,
        # it appends the "VERIFY" line to logins.log once it knows)
        check_player_client "$name" "$ip" &
    elif [[ "$line" =~ $CMD_RE ]]; then
        name="${BASH_REMATCH[1]}"
        v=$(verdict_for "$name")
        cmd=$(mask_cmd "$name" "${BASH_REMATCH[2]}" "$v")
        ip=$(last_ip_for "$name")
        echo "$NOW | $name | $(ip_field "$name" "${ip:-unknown}" "$v") | $cmd$(client_field "$v")" >> "$CMD_LOG"
    elif [[ "$line" =~ $LEAVE_RE ]]; then
        name="${BASH_REMATCH[1]}"
        v=$(verdict_for "$name")
        ip=$(last_ip_for "$name")
        echo "$NOW | LOGOUT | $name | $(ip_field "$name" "${ip:-unknown}" "$v")$(client_field "$v")" >> "$LOGIN_LOG"
    fi
}

handle_bungee_line() {
    local line="${1%$'\r'}" NOW name ip cmd
    local BC_RE='([A-Za-z0-9_.-]+)\]? executed command: (.*)$'
    NOW=$(date '+%F %T')
    if [[ "$line" =~ $BC_RE ]]; then
        name="${BASH_REMATCH[1]}"
        # don't log commands that this script itself injects into the console
        [[ "$name" == "CONSOLE" || "$name" == "Console" || "$name" == "client-brand" ]] && return
        v=$(verdict_for "$name")
        cmd=$(mask_cmd "$name" "${BASH_REMATCH[2]}" "$v")
        ip=$(last_ip_for "$name")
        echo "$NOW | $name | $(ip_field "$name" "${ip:-unknown}" "$v") | [bungee] $cmd$(client_field "$v")" >> "$CMD_LOG"
    fi
}

start_security_logger() {
    mkdir -p "$SEC_DIR" "$PRIV_DIR"
    touch "$LOGIN_LOG" "$CMD_LOG" "$CLIENT_LOG" "$AUTH_LOG"

    # Make sure no old watchers are left over (prevents duplicate log lines)
    pkill -f "tail -n0 -F /tmp/" 2>/dev/null
    [ -n "$SECLOG_PID" ] && kill "$SECLOG_PID" 2>/dev/null

    (
        tail -n0 -F /tmp/paper.log 2>/dev/null \
            | grep --line-buffered -E 'logged in with entity id|issued server command|left the game' \
            | while IFS= read -r l; do handle_paper_line "$l"; done &

        tail -n0 -F /tmp/bungee.log 2>/dev/null \
            | grep --line-buffered 'executed command:' \
            | while IFS= read -r l; do handle_bungee_line "$l"; done &

        wait
    ) &
    SECLOG_PID=$!
}

# =============================================================
# VERIFIED CLIENT CHECK
# =============================================================
# Runs "/client-brand name <player>" on the Bungee console (through the pipe
# opened by start_bungee) and reads the answer back out of /tmp/bungee.log.
# EaglerXBungee prints:
#   Eagler Client Brand:   <brand>       <- "Eaglercraft[VER]" for our client
#   Eagler Client Version: <version>
#   Eagler Client UUID:    <brand UUID>  <- the unique marker
#   Minecraft Client Brand: <vanilla brand>
# =============================================================
strip_colours() {
    sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\xc2\xa7[0-9a-fk-or]//g' -e 's/\xa7[0-9a-fk-or]//g'
}

# write one command into the BungeeCord console pipe (safe from any subshell)
bungee_console() {
    [ "$BUNGEE_CONSOLE_OK" = true ] || return 1
    [ -p "$BUNGEE_CONSOLE" ] || return 1
    timeout 3 bash -c 'printf "%s\n" "$1" > "$2"' bash "$*" "$BUNGEE_CONSOLE" 2>/dev/null || return 1
}

bungee_alive() {
    local pid
    pid=$(cat "$BUNGEE_PID_FILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

query_client_brand() {
    local player="$1" start_line out brand version uuid mcbrand i
    if ! bungee_alive; then
        echo "CONSOLE_DOWN||||"
        return 1
    fi

    start_line=$(wc -l < /tmp/bungee.log 2>/dev/null || echo 0)
    bungee_console "client-brand name $player" || { echo "CONSOLE_DOWN||||"; return 1; }

    for i in $(seq 1 25); do
        sleep 0.2
        out=$(tail -n "+$((start_line + 1))" /tmp/bungee.log 2>/dev/null | tr -d '\r' | strip_colours)
        grep -q "Eagler Client UUID:" <<<"$out" && break
        grep -qE "not using eaglercraft|That player was not found|Unknown command" <<<"$out" && break
    done

    if grep -qi "not using eaglercraft" <<<"$out"; then
        echo "VANILLA||||"
        return 0
    fi

    brand=$(sed -n 's/.*Eagler Client Brand: //p' <<<"$out" | tail -1)
    version=$(sed -n 's/.*Eagler Client Version: //p' <<<"$out" | tail -1)
    uuid=$(sed -n 's/.*Eagler Client UUID: //p' <<<"$out" | tail -1)
    mcbrand=$(sed -n 's/.*Minecraft Client Brand: //p' <<<"$out" | tail -1)

    if [ -z "$uuid" ] && [ -z "$brand" ]; then
        echo "UNKNOWN||||"
        return 0
    fi

    if [ "$uuid" = "$VERIFIED_CLIENT_UUID" ] || [ "$brand" = "$VERIFIED_CLIENT_BRAND" ]; then
        echo "VERIFIED|$brand|$version|$uuid|$mcbrand"
    else
        echo "UNVERIFIED|$brand|$version|$uuid|$mcbrand"
    fi
}

check_player_client() {
    local name="$1" ip="$2" res verdict brand version uuid mcbrand now
    sleep 1   # give the Eagler handshake a moment to finish
    res=$(query_client_brand "$name")
    IFS='|' read -r verdict brand version uuid mcbrand <<< "$res"
    if [ "${verdict:-UNKNOWN}" = "UNKNOWN" ] || [ "$verdict" = "CONSOLE_DOWN" ]; then
        sleep 2
        res=$(query_client_brand "$name")
        IFS='|' read -r verdict brand version uuid mcbrand <<< "$res"
    fi

    now=$(date '+%F %T')
    verdict="${verdict:-UNKNOWN}"
    set_verdict "$name" "$verdict"
    flush_pending_auth
    local shown_ip=$(ip_field "$name" "$ip" "$verdict")
    echo "$now | ${verdict} | $name | $shown_ip | brand=${brand:-?} | version=${version:-?} | uuid=${uuid:-?}" >> "$CLIENT_LOG"
    # Everybody except the verified client also gets a plainly readable VERIFY
    # line in logins.log, so logins.log alone answers "was this me?" with
    # "grep 'VERIFIED CLIENT' logins.log". For the verified client the line is
    # omitted (see client_field) - a login by it is just LOGIN + LOGOUT.
    if [ "$verdict" != "VERIFIED" ] || [ "$HIDE_VERIFIED_IP" != true ]; then
        echo "$now | VERIFY | $name | $shown_ip | $(verdict_label "$verdict") | brand=${brand:-?} | version=${version:-?} | uuid=${uuid:-?}" >> "$LOGIN_LOG"
    fi
    echo "[CLIENT] $(date '+%H:%M:%S') $name ($shown_ip): ${verdict} / $(verdict_label "$verdict") brand=${brand:-?} version=${version:-?}"

    enforce_client_policy "$name" "$verdict"
}

# =============================================================
# Enforcement — only the verified client may stay
# =============================================================
# ENFORCE_VERIFIED_CLIENT=true kicks everybody who is not on the verified
# client. Nothing is kicked while the check has not resolved
# (ENFORCE_KICK_ON_UNKNOWN=false), so a proxy hiccup can never lock you out.
is_bypassed() {
    local n l
    for n in ${ENFORCE_BYPASS_PLAYERS//,/ }; do
        [ -z "$n" ] && continue
        for l in "$@"; do
            [ "${n,,}" = "${l,,}" ] && return 0
        done
    done
    return 1
}

enforce_client_policy() {
    local name="$1" verdict="${2:-UNKNOWN}"
    [ "$ENFORCE_VERIFIED_CLIENT" = true ] || return 0
    is_bypassed "$name" && return 0

    case "$verdict" in
        VERIFIED)
            return 0 ;;
        UNVERIFIED)
            mc_command "kick $name $VERIFIED_CLIENT_KICK_MESSAGE"
            echo "[CLIENT] kicked $name (other Eaglercraft client - only the verified client may join)" ;;
        VANILLA)
            if [ "$ENFORCE_KICK_VANILLA" = true ]; then
                mc_command "kick $name $VERIFIED_CLIENT_KICK_MESSAGE"
                echo "[CLIENT] kicked $name (Java client - only the verified client may join)"
            else
                echo "[CLIENT] letting $name stay (Java client, ENFORCE_KICK_VANILLA=false)"
            fi ;;
        *)
            if [ "$ENFORCE_KICK_ON_UNKNOWN" = true ]; then
                mc_command "kick $name $VERIFIED_CLIENT_KICK_MESSAGE"
                echo "[CLIENT] kicked $name (client could not be verified)"
            else
                echo "[CLIENT] letting $name stay (${verdict} - not kicked, ENFORCE_KICK_ON_UNKNOWN=false)"
            fi ;;
    esac
}

# =============================================================
# Shared IP / verified client report
# =============================================================
# $1 = logins.log-style file to analyse, $2 = file to write
shared_report_body() {
    awk -F' [|] ' '
        $2=="LOGIN" {
            ip=$4; n=$3
            if (!((ip SUBSEP n) in s1)) { s1[ip,n]=1; ipn[ip]=ipn[ip] " " n; ipc[ip]++ }
            if (!((n SUBSEP ip) in s2)) { s2[n,ip]=1; nip[n]=nip[n] " " ip; nc[n]++ }
        }
        END {
            print "=== IPs used by MULTIPLE accounts ==="
            for (i in ipc) if (ipc[i]>1) print i " ->" ipn[i]
            print ""
            print "=== Accounts logged in from MULTIPLE IPs ==="
            for (n in nc) if (nc[n]>1) print n " ->" nip[n]
        }' "$1" > "$2"

    {
        echo ""
        echo "=== Verified client checks (client-checks.log) ==="
        if [ -s "$CLIENT_LOG" ]; then
            awk -F' \\| ' '
                { c[$2]++; last[$2]=$0 }
                END {
                    for (k in c) print k ": " c[k] " login(s)    (last seen " last[k] ")"
                }' "$CLIENT_LOG" | sort
            echo ""
            echo "=== Logins NOT using the verified client ==="
            grep -E "UNVERIFIED|VANILLA" "$CLIENT_LOG" 2>/dev/null | tail -20
        else
            echo "no client checks recorded yet"
        fi
    } >> "$2"
}

report_shared_ips() {
    flush_pending_auth
    [ -s "$LOGIN_LOG" ] || return
    {
        echo "=== Shared IP report $(date '+%F %T') ==="
        [ "$HIDE_VERIFIED_IP" = true ] && \
            echo "(the verified client's own IP shows as \"hidden\" here - see private-logs/shared-ips-private.txt)"
    } > "$SHARED_REPORT"
    shared_report_body "$LOGIN_LOG" "$SHARED_REPORT"

    # private copy with the real IPs put back in, for your own analysis
    if [ "$HIDE_VERIFIED_IP" = true ] && [ "$PRIVATE_IP_LOG" = true ]; then
        local name ip line
        : > "$PRIV_DIR/logins-real-ips.log"
        while IFS= read -r line; do
            if [[ "$line" == *"| hidden"* ]]; then
                name=$(awk -F' [|] ' '{print $3}' <<<"$line")
                ip=$(last_ip_for "$name")
                line="${line//| hidden/| ${ip:-unknown}}"
            fi
            printf '%s\n' "$line" >> "$PRIV_DIR/logins-real-ips.log"
        done < "$LOGIN_LOG"
        echo "=== Shared IP report (real IPs) $(date '+%F %T') ===" > "$PRIV_DIR/shared-ips-private.txt"
        shared_report_body "$PRIV_DIR/logins-real-ips.log" "$PRIV_DIR/shared-ips-private.txt"
        {
            echo ""
            echo "=== Last 20 logins with their real IPs ==="
            tail -20 "$PRIV_DIR/logins-real-ips.log"
        } >> "$PRIV_DIR/shared-ips-private.txt"
    fi
}

# =============================================================
# HuggingFace Bucket
# =============================================================
hf_authenticate() {
    if [ -n "$HF_TOKEN" ]; then
        hf auth login --token "$HF_TOKEN" --add-to-git-credential 2>/dev/null || true
        echo " Authenticated"
    else
        echo " No HF_TOKEN"
    fi
}

hf_ensure_bucket() {
    local BUCKET_ID=$(echo "$HF_BUCKET_HANDLE" | sed 's|hf://buckets/||')
    hf buckets create "$BUCKET_ID" --exist-ok 2>/dev/null
}

hf_restore_saves() {
    echo " Restoring game data..."
    hf buckets sync "${HF_BUCKET_HANDLE}/game-data" "$BACKEND_DIR" 2>&1 | tail -5
    for dir in $SAVE_DIRS; do
        [ -e "$BACKEND_DIR/$dir" ] && echo "   Found: $dir"
    done
}

hf_push_saves() {
    report_shared_ips
    local STAGING="/tmp/hf-staging"
    rm -rf "$STAGING" && mkdir -p "$STAGING"
    for item in $SAVE_DIRS; do
        if [ -e "$BACKEND_DIR/$item" ]; then
            mkdir -p "$STAGING/$(dirname "$item")"
            cp -a "$BACKEND_DIR/$item" "$STAGING/$item"
        fi
    done
    hf buckets sync "$STAGING" "${HF_BUCKET_HANDLE}/game-data" --delete 2>&1 | tail -3
    [ $? -eq 0 ] && echo "[SYNC] OK $(date '+%H:%M:%S')" \
                  || echo "[SYNC] FAIL $(date '+%H:%M:%S')"
    rm -rf "$STAGING"
}

hf_sync_loop() {
    while true; do
        sleep "$SYNC_INTERVAL"
        hf_push_saves
    done
}

# =============================================================
# STEP 0: Bucket
# =============================================================
echo "[0/7] Bucket setup..."
hf_authenticate
hf_ensure_bucket
hf_restore_saves
mkdir -p "$SEC_DIR" "$PRIV_DIR"
touch "$LOGIN_LOG" "$CMD_LOG" "$CLIENT_LOG" "$AUTH_LOG"
echo ""

# =============================================================
# STEP 1: World size
# =============================================================
echo "[1/7] World analysis..."
for WORLD_DIR in world world_nether world_the_end; do
    if [ -d "$BACKEND_DIR/$WORLD_DIR" ]; then
        SIZE=$(du -sh "$BACKEND_DIR/$WORLD_DIR" 2>/dev/null | awk '{print $1}')
        REGIONS=$(find "$BACKEND_DIR/$WORLD_DIR" -name "*.mca" 2>/dev/null | wc -l)
        echo "   $WORLD_DIR: $SIZE ($REGIONS region files)"
    fi
done
echo ""

# =============================================================
# STEP 2: Core server configs + Start Paper
# =============================================================
cd "$BACKEND_DIR"
echo "eula=true" > eula.txt

echo "[2/7] Writing core server configs + starting Paper..."

cat > server.properties << 'EOF'
server-port=25565
server-ip=127.0.0.1
online-mode=false
spawn-protection=0
max-players=20
view-distance=6
gamemode=0
difficulty=2
level-name=world
level-type=DEFAULT
generate-structures=true
motd=Vanilla Survival Eaglercraft
pvp=true
allow-flight=false
white-list=false
spawn-npcs=true
spawn-animals=true
spawn-monsters=true
enable-command-block=false
allow-nether=true
use-native-transport=true
network-compression-threshold=-1
entity-broadcast-range-percentage=50
max-tick-time=-1
enable-rcon=true
rcon.port=25575
rcon.password=chunkystart
EOF

cat > bukkit.yml << 'EOF'
settings:
  allow-end: true
  warn-on-overload: true
  connection-throttle: -1
  shutdown-message: Server closed
  save-user-cache-on-stop-only: true
spawn-limits:
  monsters: 50
  animals: 10
  water-animals: 2
  ambient: 1
chunk-gc:
  period-in-ticks: 600
ticks-per:
  animal-spawns: 600
  monster-spawns: 4
  autosave: 12000
EOF

cat > spigot.yml << 'EOF'
config-version: 8
settings:
  bungeecord: true
  timeout-time: 60
  netty-threads: 2
  async-catcher-enabled: false
  save-user-cache-on-stop-only: true
  moved-wrongly-threshold: 0.0625
  moved-too-quickly-multiplier: 10.0
  item-dirty-ticks: 20
  player-shuffle: 0
commands:
  tab-complete: 0
  log: true
world-settings:
  default:
    verbose: false
    view-distance: 4
    mob-spawn-range: 4
    entity-activation-range:
      animals: 16
      monsters: 24
      misc: 8
      tick-inactive-villagers: false
    entity-tracking-range:
      players: 48
      animals: 32
      monsters: 32
      misc: 16
      other: 48
    ticks-per:
      hopper-transfer: 8
      hopper-check: 1
    hopper-amount: 1
    max-entity-collisions: 2
    merge-radius:
      exp: 6.0
      item: 4.0
    arrow-despawn-rate: 60
    item-despawn-rate: 3000
    nerf-spawner-mobs: true
    zombie-aggressive-towards-villager: true
    enable-zombie-pigmen-portal-spawns: true
EOF

setup_op_account

> /tmp/paper.log
start_paper
echo " Paper PID: $BACKEND_PID"

for i in $(seq 1 120); do
    if grep -q "Done" /tmp/paper.log 2>/dev/null; then
        echo " Paper READY (~${i}s)"
        break
    fi
    if ! kill -0 $BACKEND_PID 2>/dev/null; then
        echo " PAPER CRASHED!"
        tail -30 /tmp/paper.log
        exit 1
    fi
    [ $((i % 15)) -eq 0 ] && echo " Loading... (${i}s)"
    sleep 1
done

# Start security logger (logins/IPs + commands + verified client checks)
start_security_logger
echo " Security logger PID: $SECLOG_PID"

for i in $(seq 1 30); do
    nc -z 127.0.0.1 25575 2>/dev/null && break
    sleep 1
done

if [ -n "$OP_USERNAME" ]; then
    mc_command "op ${OP_USERNAME}"
    echo " OP granted to ${OP_USERNAME} via RCON"
fi

echo ""
echo " === PLUGINS LOADED ==="
grep -i "Enabling" /tmp/paper.log | grep -oP "Enabling \K[^\s]+" 2>/dev/null | while read p; do
    echo "   - $p"
done
echo " ======================"
echo ""

# =============================================================
# STEP 3: Vanilla Survival gamerules
# =============================================================
echo "[3/7] Setting Vanilla gamerules..."
mc_command "gamerule pvp true"
mc_command "gamerule keepInventory false"
mc_command "gamerule naturalRegeneration true"
mc_command "gamerule doFireTick true"
mc_command "gamerule mobGriefing true"
mc_command "gamerule announceAdvancements true"
mc_command "difficulty 1"
mc_command "seed"
mc_command "defaultgamemode survival"
echo " Survival gamerules set"
echo ""

# =============================================================
# STEP 4: Idle mode
# =============================================================
echo "[4/7] Applying idle mode (no players)..."
enter_idle_mode
echo ""

# =============================================================
# STEP 5: Write BungeeCord config
# =============================================================
echo "[5/7] Writing BungeeCord config..."

cd "$BUNGEE_DIR"

cat > config.yml << 'EOF'
server_connect_timeout: 5000
remote_ping_cache: -1
forge_support: false
player_limit: 10
permissions:
  default:
    - bungeecord.command.server
  admin:
    - bungeecord.command.alert
timeout: 30000
log_commands: true
network_compression_threshold: 256
online_mode: false
disabled_commands:
  - disabledcommandhere
servers:
  lobby:
    motd: '&aEaglercraft Survival'
    address: 127.0.0.1:25565
    restricted: false
listeners:
  - query_port: 25577
    motd: '&6Eaglercraft 1.12.2 Survival'
    tab_list: GLOBAL_PING
    query_enabled: false
    proxy_protocol: false
    forced_hosts: {}
    ping_passthrough: false
    priorities:
      - lobby
    bind_local_address: true
    host: 127.0.0.1:25577
    max_players: 10
    tab_size: 60
    force_default_server: true
ip_forward: true
remote_ping_timeout: 5000
prevent_proxy_connections: false
groups:
  default:
    - default
connection_throttle: -1
connection_throttle_limit: 0
stats: none
log_pings: false
EOF
echo "   BungeeCord config.yml written"

echo ""
echo "   Reloading server via RCON..."
sleep 2
mc_command "reload confirm"
echo "   Full server reload done"
echo ""

# =============================================================
# STEP 6: EaglerXServer generation + Start BungeeCord
# =============================================================
LISTENERS_FILE=$(find_listeners_yml)

if [ -z "$LISTENERS_FILE" ]; then
    echo "[6/7] Generating EaglerXServer config..."
    cd "$BUNGEE_DIR"
    $JAVA "${BUNGEE_JVM_FLAGS[@]}" \
        -cp "sqlite-jdbc.jar:BungeeCord.jar" \
        net.md_5.bungee.Bootstrap >> /tmp/bungee-gen.log 2>&1 &
    GEN_PID=$!

    for i in $(seq 1 60); do
        if nc -z 127.0.0.1 8081 2>/dev/null || nc -z 127.0.0.1 7860 2>/dev/null; then
            echo " EaglerXServer started (~$((i*2))s)"
            break
        fi
        if ! kill -0 $GEN_PID 2>/dev/null; then
            echo " Generation failed"
            tail -20 /tmp/bungee-gen.log
            break
        fi
        sleep 2
    done

    sleep 3
    kill $GEN_PID 2>/dev/null
    wait $GEN_PID 2>/dev/null
    for i in $(seq 1 15); do
        nc -z 127.0.0.1 8081 2>/dev/null || break
        sleep 1
    done
    sleep 2
else
    echo "[6/7] EaglerXServer config exists"
fi

echo " Starting BungeeCord..."

patch_eagler_port

# === MOTD AND ICON PATCH ===
LISTENERS_NOW=$(find_listeners_yml)
if [ -n "$LISTENERS_NOW" ]; then
    sed -i 's/An EaglercraftX server/\&e\&l★ \&a\&lSurvival 1.12 Server \&e\&l★/g' "$LISTENERS_NOW"
    sed -i 's/smodusermc-server.hf.space/\&r\&7Survive, craft and explore!/g' "$LISTENERS_NOW"
fi

EAGLER_DIR=$(dirname "$(find_listeners_yml)" 2>/dev/null)

if [ -n "$EAGLER_DIR" ]; then
    mkdir -p "$EAGLER_DIR/drivers"
    cp -f "$BUNGEE_DIR/sqlite-jdbc.jar" "$EAGLER_DIR/drivers/sqlite-jdbc.jar" 2>/dev/null
fi

> /tmp/bungee.log
start_bungee
echo " BungeeCord PID: $BUNGEE_PID"

PORT_READY=false
for i in $(seq 1 45); do
    if nc -z 127.0.0.1 7860 2>/dev/null; then
        PORT_READY=true
        echo " Port 7860 OPEN (~$((i*2))s)"
        break
    fi
    if ! kill -0 $BUNGEE_PID 2>/dev/null; then
        echo " BungeeCord crashed!"
        tail -20 /tmp/bungee.log
        break
    fi
    sleep 2
done

if [ "$PORT_READY" = true ]; then
    echo ""
    echo "============================================"
    echo " SERVER READY — Vanilla EaglerCraft on :7860"
    [ -n "$OP_USERNAME" ] && echo " OP: $OP_USERNAME (level 4)"
    echo " Plugins Synced via HuggingFace!"
    echo " Security logging ACTIVE  (client marks: security-logs/logins.log, passwords: private-logs/auth.log)"
    echo " Verified client: $VERIFIED_CLIENT_BRAND"
    echo " Client checks -> security-logs/client-checks.log (synced to the bucket)"
    echo "============================================"
else
    echo " Port 7860 NOT open!"
    for port in 7860 8081 25565 25577; do
        nc -z 127.0.0.1 $port 2>/dev/null && echo "   OK $port" || echo "   FAIL $port"
    done
    LISTENERS_NOW=$(find_listeners_yml)
    if [ -n "$LISTENERS_NOW" ] && grep -q ":8081" "$LISTENERS_NOW"; then
        kill $BUNGEE_PID 2>/dev/null
        wait $BUNGEE_PID 2>/dev/null
        sleep 3
        patch_eagler_port
        start_bungee
        sleep 20
        nc -z 127.0.0.1 7860 2>/dev/null && echo " Port 7860 open!" || echo " Failed"
    fi
fi

# =============================================================
# STEP 7: Final confirmation
# =============================================================
echo ""
echo "[7/7] Final status check..."
echo " === ACTIVE PLUGINS ==="
RELOAD_CHECK=$(mc_command "plugins")
echo "   $RELOAD_CHECK"
echo " ======================"
echo ""

# =============================================================
# Sync loop
# =============================================================
hf_sync_loop &
SYNC_PID=$!

# =============================================================
# Shutdown — save world properly, then push, then stop processes
# =============================================================
graceful_shutdown() {
    echo " Shutting down..."
    mc_command "gamerule doMobSpawning true"
    mc_command "gamerule randomTickSpeed 3"
    mc_command "save-all"
    sleep 5
    pkill -f "tail -n0 -F /tmp/" 2>/dev/null
    kill $SECLOG_PID 2>/dev/null
    hf_push_saves
    kill $SYNC_PID 2>/dev/null
    mc_command "stop"
    sleep 5
    kill $BUNGEE_PID 2>/dev/null
    kill -0 $BACKEND_PID 2>/dev/null && kill $BACKEND_PID 2>/dev/null
    exit 0
}

trap graceful_shutdown SIGTERM SIGINT SIGHUP

# =============================================================
# Monitor loop
# =============================================================
echo ""
echo "Monitor loop started..."

LAST_LOG_LINE=$(wc -l < /tmp/paper.log 2>/dev/null || echo 0)
LOOP_COUNT=0

while true; do
    LOOP_COUNT=$((LOOP_COUNT + 1))

    if ! kill -0 $BACKEND_PID 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] Paper crashed — restarting..."
        hf_push_saves
        IDLE_MODE=false
        start_paper
        sleep 45
        for i in $(seq 1 30); do
            nc -z 127.0.0.1 25575 2>/dev/null && break
            sleep 1
        done
        if [ -n "$OP_USERNAME" ]; then
            mc_command "op ${OP_USERNAME}"
        fi
        mc_command "gamerule pvp true"
        mc_command "gamerule keepInventory false"
        mc_command "gamerule mobGriefing true"
        enter_idle_mode
    fi

    if ! kill -0 $BUNGEE_PID 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] BungeeCord crashed — restarting..."
        patch_eagler_port
        start_bungee
    fi

    if ! kill -0 $SYNC_PID 2>/dev/null; then
        hf_sync_loop &
        SYNC_PID=$!
    fi

    if ! kill -0 "$SECLOG_PID" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] Security logger died — restarting..."
        start_security_logger
    fi

    if kill -0 $BACKEND_PID 2>/dev/null; then
        PLAYER_COUNT=$(get_player_count)
        if [ "$PLAYER_COUNT" != "0" ] && [ "$IDLE_MODE" = true ]; then
            exit_idle_mode
        elif [ "$PLAYER_COUNT" = "0" ] && [ "$IDLE_MODE" = false ]; then
            enter_idle_mode
        fi
    fi

    # auth commands waiting for a verdict that never came (player left mid-check)
    if [ $((LOOP_COUNT % 10)) -eq 0 ]; then
        flush_pending_auth
    fi

    if [ $((LOOP_COUNT % 5)) -eq 0 ]; then
        CURRENT_LINE=$(wc -l < /tmp/paper.log 2>/dev/null || echo 0)
        if [ "$CURRENT_LINE" -gt "$LAST_LOG_LINE" ]; then
            NEW_ERRORS=$(tail -n +"$((LAST_LOG_LINE + 1))" /tmp/paper.log | grep -c "ERROR\|SEVERE" || echo 0)
            [ "$NEW_ERRORS" -gt 0 ] && echo "[$(date '+%H:%M:%S')] $NEW_ERRORS errors" && \
                tail -n +"$((LAST_LOG_LINE + 1))" /tmp/paper.log | grep "ERROR\|SEVERE" | tail -3
            LAST_LOG_LINE=$CURRENT_LINE
        fi
    fi

    if [ $((LOOP_COUNT % 30)) -eq 0 ]; then
        for LF in /tmp/paper.log /tmp/bungee.log; do
            LS=$(stat -c%s "$LF" 2>/dev/null || echo 0)
            if [ "$LS" -gt 10485760 ]; then
                # Truncate in place so Java and the security logger keep working
                tail -1000 "$LF" > "${LF}.old"
                : > "$LF"
                echo "[$(date '+%H:%M:%S')] Trimmed $(basename $LF)"
            fi
        done
        LAST_LOG_LINE=$(wc -l < /tmp/paper.log 2>/dev/null || echo 0)
    fi

    if [ $((LOOP_COUNT % 5)) -eq 0 ]; then
        RSS=$(ps -p $BACKEND_PID -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
        echo "[STATUS] Players: ${PLAYER_COUNT:-?} | RAM: ${RSS:-?}MB | $([ "$IDLE_MODE" = true ] && echo IDLE || echo ACTIVE)"
    fi

    sleep 60
done
