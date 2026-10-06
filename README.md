---
title: Server
emoji: 👁
colorFrom: purple
colorTo: gray
sdk: docker
pinned: false
---

Check out the configuration reference at https://huggingface.co/docs/hub/spaces-config-reference

# Eaglercraft 1.12.2 Survival server (Paper + EaglerXBungee)

A Hugging Face Space that runs:

* **BungeeCord** with the **EaglerXBungee** plugin listening for EaglercraftX
  clients on port `7860`
* **Paper 1.12.2** as the backend survival server (RCON on `25575`)
* **Hugging Face buckets** (`hf://buckets/smodusermc/1.12`) for world/bucket
  persistence and periodic syncs
* one date-divided **activity log** for logins, commands and client checks, with
  New York/Eastern timestamps in a 12-hour clock and the verified client's IP
  hidden but its `VERIFIED CLIENT` marker retained
* private auth and address logs in `private-logs/`; other players' full auth
  commands are retained there, while the verified client's own password is
  always masked
* **forwarded client-IP detection**: the server tests whether a forwarded header
  works and reports the result; when it does not, the logs identify proxy
  addresses instead of claiming they are player addresses

## Layout

| Path | What it is |
| --- | --- |
| `Dockerfile` | image build (Java 17, BungeeCord, Paper, plugins, verified client) |
| `start.sh` | boots + supervises everything, writes configs and security logs |
| `config/bungee/EaglerXBungee.jar` | proxy plugin that lets EaglercraftX clients join |
| `plugins/` | backend plugins copied into Paper (AuthMe jars live here) |
| `client/1.12.html` | **the verified client** — sealed behind a login; the brand inside it cannot be read without that login, so the file is safe to commit |
| `tools/setup-verified-client.sh` | one command to build/rotate it, re-bake the pair into `start.sh` and print the secrets |
| `tools/patch_verified_client.py` | patches / inspects / seals the client brand |
| `tools/verify_gated_client.mjs` | runs the real login gate + loader headless: proves the file only boots after the login |
| `tools/optimize_client.py` | reproduces the existing client-package transformations and supports resource-pack fixtures; its tests do not benchmark real gameplay |
| `tools/epk.py` / `tools/pnglite.py` | the EPK package and PNG readers/writers that optimiser needs (no external libraries) |
| `tools/run_epw_loader.mjs` | boots the client's own EPW loader to prove the file loads |
| `tools/forward_ip_probe.py` | asks the proxy whether it sends a forwarded-IP header (embedded in `start.sh`) |
| `tools/proxy_peers.py` | the addresses of the proxy that sits in front of the game port, from the kernel's own tables (embedded in `start.sh`) |
| `tools/patch_auth_filter.py` | stops LoginSecurity/AuthMe from hiding `/login` from the console (embedded in `start.sh`) |
| `tools/log_migrate.py` | one-time, idempotent migration from legacy log files to the consolidated Eastern-time layout (embedded in `start.sh`) |
| `tools/bucket_sync.py` | uploads a folder to the bucket (the fallback used when `hf` fails; embedded in `start.sh`) |
| `tools/embed_tools.py` | keeps those embedded copies in sync (the tests fail when they differ) |
| `tools/fetch-logs.sh` | downloads the curated public/private logs and combined console snapshot |
| `tools/push-to-space.sh` | uploads only the files the Space needs |
| `tests/test_verified_client.sh` | test suite for verification, migration, log privacy, bucket sync paths, and client packaging |
| `docs/verified-client.md` | how the verified client works, in detail |

## The verified client

Every Eaglercraft client reports a 16-byte **brand UUID** during the login
handshake. That UUID is derived from the client's brand name:

```
brandUUID = UUID.nameUUIDFromBytes("EaglercraftXClient:" + brand)
```

The stock Eaglercraft 1.12 client uses the brand `Eaglercraft 1.12`, which
always produces `522b2ce5-c9b9-36cf-be7c-5d90f55e631a` — so *everyone* using a
stock client looks identical in the logs. The client built here carries a brand
of your own, so its logins are recognisable.

**The brand is never written down in readable text.** Two places hold it and
neither shows it:

| where | how it is stored |
| --- | --- |
| `client/1.12.html` | not at all — the file carries a **PBKDF2-SHA512 verifier** of the brand (`window.__verGate.brandKdf`); the brand itself only exists inside the sealed payload, behind the login |
| `start.sh` | XOR'd + base64 (`VERIFIED_CLIENT_PAIR_B64` / `_KEY`), decoded at boot |

That means the client file can be committed and handed out without exposing the
brand inside its sealed payload; reading that payload needs the login. `--check` therefore reports
`brand : hidden - PBKDF2-SHA512 verifier` and can still answer *"is this the
client I think it is?"*:

```bash
python3 tools/patch_verified_client.py --check client/1.12.html --expect-brand "<brand>"
#   matches   : YES ('<brand>' is the brand in this file)
#   brandUUID : <the UUID the server will see>
```

**Optional: the Space secrets override the baked-in pair.** Set
`VERIFIED_CLIENT_BRAND` / `VERIFIED_CLIENT_UUID` (Settings → Variables and
secrets) if you want to change the pair without pushing `start.sh`; the boot log
prints which source won (`pair from: built-in | environment | .verified-client.env`)
and warns when the environment holds a pair the build was not made for (a stale
secret after a rotation).

Be clear about what the obfuscation is worth: `start.sh` carries the key right
next to the blob, so **anybody who can read this repository can decode the pair
in one command** and build a client that reports it. The obfuscation keeps it
out of plain sight and out of `git grep`, not out of reach. If the "verified"
mark has to stay unforgeable, either make this repository private or keep the
pair only in the Space secrets (and remove the baked blob). Everything else
about the system — joining, logging, IPs — does not depend on that choice.

Build or rotate it with one command (it rebuilds the client, re-bakes the pair
into `start.sh`, writes the git-ignored `.verified-client.env` and prints what
to put into the Space):

```bash
bash tools/setup-verified-client.sh --brand "AnotherName16Cha" --gate-user sllab --gate-pass '<password>'
bash tools/setup-verified-client.sh --rotate --gate-user sllab --upload
```

**The clients handed out before are revoked** — `Eaglercraft[VER]` and then
`EaglercraftX[V2]`, because both their brands were committed to this public
repository. They are just "some other Eaglercraft client" now: allowed on the
server (see below) but never marked as you. Rotating is what invalidates a
client; the old file cannot undo it.

### Everything ends up in the bucket

The bucket is the only place the logs can be read from outside the Space. The
curated logs use **America/New_York time (EST/EDT), a 12-hour clock**, and
spaced date dividers in append-only logs. The layout is intentionally small and
nonredundant:

```
hf://buckets/smodusermc/1.12/game-data/security-logs/activity.log       LOGIN / LOGOUT / CHECK / COMMAND
hf://buckets/smodusermc/1.12/game-data/security-logs/addresses.txt      public address report (verified IP omitted)
hf://buckets/smodusermc/1.12/game-data/security-logs/status.txt         replace-in-place health snapshot
hf://buckets/smodusermc/1.12/game-data/private-logs/auth.log            full auth commands for other players
hf://buckets/smodusermc/1.12/game-data/private-logs/addresses.log       full, dated IP history
hf://buckets/smodusermc/1.12/game-data/private-logs/addresses.txt       private address report, including your IP
hf://buckets/smodusermc/1.12/game-data/private-logs/verified-players.txt verified player names used for redaction
hf://buckets/smodusermc/1.12/game-data/private-logs/proxy-peers.log     proxy peer state used to classify addresses
hf://buckets/smodusermc/1.12/game-data/private-logs/forward-ip.state   remembered forwarding-header choice
hf://buckets/smodusermc/1.12/game-data/logs/console.log                 one masked Paper + Bungee snapshot
```

The console file is a snapshot of the last `CONSOLE_LOG_LINES` lines from each
process (1000 by default), with source labels. It is not a second unfiltered
copy of the raw console logs. Password arguments, verified-client addresses,
and client brand/UUID fields are redacted before it is staged.

Background work is separated so log freshness does not require a world scan:

* the small security/private/log prefixes sync every **60 seconds**
  (`LOG_SYNC_INTERVAL`);
* the full game-data/world snapshot syncs every **600 seconds** by default
  (`SYNC_INTERVAL`); the normal server autosave is also ten minutes;
* address reports regenerate every **300 seconds** (`REPORT_INTERVAL`), and
  status snapshots refresh every **60 seconds** (`LOG_STATUS_INTERVAL`);
* the RCON player-list safety poll defaults to **60 seconds**
  (`PLAYERLIST_POLL`).

Only one bucket sync may run at a time. The log loop syncs only its three small
prefixes; it does not walk or upload the worlds. Both the full snapshot and log
staging copy run at low CPU/I/O priority (`nice -n 19` and `ionice -c3` when the
container permits it), so a sync may take longer rather than compete at equal
priority with Paper. These changes have been tested with fixtures and a fake
bucket API; **live bucket, Docker build, server TPS, and gameplay impact have not
been measured here**.

At startup `tools/log_migrate.py` converts legacy UTC log timestamps to Eastern,
redacts verified-client identity data, merges duplicate historical event/IP
files, and removes the old copies. The migration is marker-based and repeat-run
idempotent. Log-prefix sync uses `--delete` to remove stale duplicate filenames
from the bucket as well as upload the curated layout.

Get the current copies locally in one go:

```bash
bash tools/fetch-logs.sh            # -> ./server-logs/{security-logs,private-logs,logs}
```

`SYNC_PRIVATE_LOGS` and `SYNC_CONSOLE_LOGS` default to `true`. Setting either to
`false` syncs an empty corresponding bucket prefix with `--delete`, removing any
older copies there; private data then will no longer be available from the
bucket. Keep the bucket private because the default private folder contains
other players' clear-text auth commands and real IPs. `SYNC_INTERVAL`,
`LOG_SYNC_INTERVAL`, `REPORT_INTERVAL`, `PLAYERLIST_POLL`, and
`CONSOLE_LOG_LINES` can be overridden in the Space environment.

#### If the bucket stays empty ("I don't see private-logs")

The Space uploads with the `hf` CLI first and falls back to the Python API
(`tools/bucket_sync.py`, embedded in `start.sh`), so a broken CLI alone no
longer loses anything. What it *cannot* work around is a token without write
access. At boot the Space therefore tests it and prints the answer next to the
other startup output (Space → **Logs** tab):

```
[BUCKET] write test: hf://buckets/smodusermc/1.12/game-data
   [BUCKET] token role: read
   [BUCKET] hf CLI cannot write: ...
   [BUCKET] !! NOTHING will reach the bucket until this works.
   [BUCKET] !! 1. open huggingface.co/settings/tokens -> New token -> Write
   [BUCKET] !! 2. copy it, then Space Settings -> Variables and secrets
   [BUCKET] !! 3. new secret: name HF_TOKEN, value the token, then Restart
```

Fix = create a **Write** token and save it as the Space secret `HF_TOKEN`, then
restart the Space. Every sync then prints `[LOGSYNC] OK … via cli` or
`… via python`; a failure prints the reason instead of dying quietly.
`BUCKET_METHOD=cli` or `BUCKET_METHOD=python` forces one upload path.

⚠️ With the defaults the **private** bucket prefix contains other players'
clear-text auth commands (`private-logs/auth.log`) and real IPs
(`private-logs/addresses.log` and `private-logs/addresses.txt`). Keep the bucket
private. The verified client's own password is masked, including during legacy
migration.

`start.sh` asks the proxy for the brand of each player that joins
(`/client-brand`, over a console pipe). Enforcement is **off by default**, so all
clients may join. Each event type is written to one dated activity stream:

```
security-logs/activity.log
==================== Monday, October 5, 2026 | 2026-10-05 ====================

2026-10-05 09:14:01 PM EDT | LOGIN | Owner | hidden | client=CHECK PENDING
2026-10-05 09:14:03 PM EDT | CHECK | Owner | hidden | client=VERIFIED CLIENT | brand=redacted | version=u2 | uuid=redacted
2026-10-05 09:14:10 PM EDT | COMMAND | Owner | hidden | /login ******** | client=VERIFIED CLIENT
2026-10-05 09:15:46 PM EDT | LOGIN | Guest | hidden | client=CHECK PENDING
2026-10-05 09:15:48 PM EDT | CHECK | Guest | 5.6.7.8 | client=OTHER EAGLERCRAFT CLIENT | brand=Eaglercraft 1.12 | version=u2 | uuid=...
2026-10-05 09:15:52 PM EDT | COMMAND | Guest | 5.6.7.8 | /gamemode 1 | client=OTHER EAGLERCRAFT CLIENT
```

A single row is written for each join/logout, client check, or command; the
Paper/Bungee/RCON sources are de-duplicated. The login row is immediately
written with the IP hidden while the check is pending. Once a non-verified
client is resolved, the `CHECK` row supplies its address and verdict. The
verified client's IP stays hidden, while the explicit `VERIFIED CLIENT` marker
is retained; its actual brand and UUID are redacted from synced logs.

The private logs are deliberately separate:

```
private-logs/auth.log
==================== Monday, October 5, 2026 | 2026-10-05 ====================

2026-10-05 09:16:00 PM EDT | Owner | hidden | /login ******** | client=VERIFIED CLIENT (password not recorded)
2026-10-05 09:17:00 PM EDT | Guest | 5.6.7.8 | /login guest-password | client=OTHER EAGLERCRAFT CLIENT

private-logs/addresses.log
==================== Monday, October 5, 2026 | 2026-10-05 ====================

2026-10-05 09:15:46 PM EDT | IP | Guest | 5.6.7.8 | source=paper
```

Auth commands (`/login`, `/l`, `/log`, `/register`, `/reg`, `/unregister`, `/changepassword`, `/changepass`, `/cp`, and `/authme`) are
masked in `activity.log` and the console snapshot. Other players' full auth
commands are kept in the private `auth.log` so you can help with account
recovery; the verified client's own password is never saved. The old log
migration also masks a verified player's historical auth rows when its saved
verification evidence identifies that account.

The address summaries are human-readable, timestamped snapshots rather than
several competing reports. `security-logs/addresses.txt` omits the verified
client's address; `private-logs/addresses.txt` includes it. Full sightings are
kept in `private-logs/addresses.log`, with the source of each sighting.
`security-logs/status.txt` is a small replace-in-place health snapshot. No
second `logins.log`, `commands.log`, `client-checks.log`, shared-IP report, or
raw Paper/Bungee tail is uploaded.

The verdict labels are `VERIFIED CLIENT`, `OTHER EAGLERCRAFT CLIENT`,
`JAVA CLIENT`, `CHECK PENDING`, `CONSOLE DOWN`, and `UNKNOWN CLIENT`. They appear
on activity rows where relevant; unknown/pending results are explicit rather
than silently omitted. With `ENFORCE_VERIFIED_CLIENT=false` anybody may join.
Set it to `true` only if you want the later kick policy; `UNKNOWN` and
`CONSOLE_DOWN` still do not kick unless `ENFORCE_KICK_ON_UNKNOWN=true`.

While the verified-client pair is **not configured**, the server cannot safely
tell your own `/login` from another player's, so all auth rows are masked with
`client=UNCONFIGURED` until the pair is set. Set `VERIFIED_CLIENT_BRAND` and
`VERIFIED_CLIENT_UUID` in the Space secrets or use the baked-in pair; the boot
status tells you if the pair is missing.

For a quick filter:

```bash
grep '| LOGIN |'   server-logs/security-logs/activity.log
grep '| CHECK |'   server-logs/security-logs/activity.log
grep '| COMMAND |' server-logs/security-logs/activity.log
cat server-logs/security-logs/addresses.txt
cat server-logs/security-logs/status.txt
cat server-logs/private-logs/auth.log          # keep private: other players' passwords
cat server-logs/private-logs/addresses.log     # keep private: all real IP sightings
```

### Changing the brand / rebuilding the client

```bash
# the one command that does everything: new brand, new credentials, the client
# rebuilt, the pair re-baked into start.sh (obfuscated), the git-ignored
# .verified-client.env rewritten, and optionally the client uploaded
bash tools/setup-verified-client.sh --rotate --gate-user sllab --upload

# or with a brand you pick (exactly 16 ASCII characters, never used here)
bash tools/setup-verified-client.sh --brand "AnotherName16Cha" --gate-user sllab

# what UUID does a brand produce?
python3 tools/patch_verified_client.py --print-uuid --brand "AnotherName16Cha"

# inspect a built client (add --gate-user/--gate-pass to open the seal too)
python3 tools/patch_verified_client.py --check client/1.12.html

# prove it before handing it out: boots only after the login, real loader
node tools/verify_gated_client.mjs client/1.12.html --user <user> --pass <password>
```

After a rotation, push `start.sh` (the pair inside it changed) and hand out the
new client. The old pair stops matching immediately. A brand that was public at
some point is refused by the patcher (`REVOKED_BRANDS`) and by the server
(`PUBLISHED_CLIENT_BRANDS`), and the test suite checks that the pair never
appears in the git history: `git log --all -S"<brand>"` must be empty. The suite
covers verified-client detection, log privacy and date formatting, legacy-log
migration/idempotence, scoped bucket sync using a fake CLI/API, proxy-peer/IP
classification, auth-filter patch fixtures, client packaging and the low-end
WASM patch structure. It does **not** connect to a live bucket or Space, build
the Docker image, simulate real players, measure server CPU/TPS, or prove a
no-lag gameplay outcome. Optional JVM and real-client loader checks run only
when the required local runtime and gate credentials are available.

```bash
bash tests/test_verified_client.sh

# print fixture logs too (never use real production passwords in fixtures)
PRINT_LOGS=1 bash tests/test_verified_client.sh

# the released client is sealed, so unseal it with the credentials first and
# then boot the client's own loader against exactly what a browser gets:
node tools/verify_gated_client.mjs client/1.12.html --user <user> --pass <password> \
        --dump-epw /tmp/unsealed.epw
node tools/run_epw_loader.mjs /tmp/unsealed.epw

# an *ungated* file (client straight out of the patcher) can be tested directly:
node tools/run_epw_loader.mjs client/1.12.html          # only if it is not sealed
```

The loader is strict, and the tool now mirrors it:

* every component must decode with an **LZMA2 dictionary of at most 32 MiB** —
  the loader calls `xz_dec_init(XZ_DYNALLOC, 33554432)`, and a bigger
  dictionary fails with `XZ_OPTIONS_ERROR` ("Decompression failed, code 6!"),
  which the client shows as *"EPW file is invalid / Try again later"*. Plain
  `xz --preset 9` uses 64 MiB, so the tool caps the dictionary at 32 MiB and
  refuses to write a file that the loader would reject.
* the XZ stream must end **exactly** at the declared slice length (no trailing
  bytes) and decompress to exactly the declared size, `fileLength`/`fileCRC32`
  must match, and every slice must stay in bounds. `--check` verifies all of
  this on an existing file, and `tools/run_epw_loader.mjs` then runs the real
  loader as the final proof.

### Why a login is never missed

A join is reported three times and any one of them is enough:

| source | line | why it matters |
| --- | --- | --- |
| Paper | `<name>[/<ip>:<port>] logged in with entity id …` | has the IP, current and older console formats |
| BungeeCord | `<name>[/<ip>:<port>] <-> ServerConnector [lobby] has connected` | sees the player even if Paper's line never appears |
| the server itself | RCON `list`, polled every `PLAYERLIST_POLL` (60) s | catches anything the log files never showed, whatever the console format is |

The first of them that arrives writes the single `LOGIN` row in
`security-logs/activity.log` (the name is marked online, so the other two stay
quiet) and every login/logout is echoed to the console as `[LOG] LOGIN <name>` — visible in the Space's *Logs* tab, i.e.
without the bucket.

#### Why `/login` needs a jar patch (LoginSecurity 3.3.1)

Passwords are read from Paper's console line `<name> issued server command:
/login <password>` — there is no other place the server can see them. That line
never appeared, because **LoginSecurity 3.3.1 itself deletes it**:

* `LoginSecurity.enable()` adds `LoggingFilter` to the log4j **root** logger
  (`LoggingFilter.java`, same version), and
* that filter returns `DENY` for any message that starts with, or contains,
  `issued server command: ` followed by `/login`, `/register`, `/changepassword`
  or `/changepass`.

So the line was dropped *before* Paper, the log file and the parser ever saw it —
no regex could have found it. BungeeCord cannot help either: its
`log_commands: true` only logs commands the *proxy* handles (it prints
`<name> executed command: …` after the command is found in the proxy's own
command map), and `/login` belongs to the backend plugin, so it is forwarded and
never logged there. AuthMe hides the same lines through
`fr.xephi.authme.output.LogFilterHelper`.

`start.sh` therefore neutralises that filter *before Paper starts*, with
`tools/patch_auth_filter.py`:

1. it finds `com/lenis0012/bukkit/loginsecurity/util/LoggingFilter.class` (and
   `fr/xephi/authme/output/LogFilterHelper.class`) inside the plugin jar and
   rewrites **only the string constants** the filter compares against, so
   `"/login"` becomes `"[authlog-patched] /login"` and can never match a real
   console line again;
2. the plugin itself is untouched otherwise — the class keeps its bytecode,
   structure and constant indices, and its own command class (which uses the
   same words for its real job) is not modified at all;
3. the JVM's own parser (`javap`) compares the class before and after: the
   instruction lines must be identical and *every* difference must be one of
   those strings. If that check fails, the original jar is put straight back;
4. a backup is kept in `/tmp/authlog-jar-backups`, and if the patched plugin
   does not show up in Paper's `Enabling …` lines, `start.sh` restores the
   original and restarts Paper once — the server is never left without its auth
   plugin.

The result is written to `security-logs/status.txt` as a `Login capture` line,
and to the console as `[AUTHPATCH] …` lines (visible in the Space's *Logs* tab). Set `AUTH_FILTER_PATCH=false` to switch it off (then
`/login` is hidden again and `auth.log` stays empty).

Other players' passwords stay in `private-logs/auth.log`; all auth arguments are
masked in `security-logs/activity.log` and in the single combined console
snapshot. The verified client's own auth row is masked in the private file too.

### Policy switches (top of `start.sh`)

| Setting | Default | What it does |
| --- | --- | --- |
| `ENFORCE_VERIFIED_CLIENT` | `false` | `false` (default) = **everybody may join**, the verified client is only marked in the logs; `true` = kick everything that is not the verified client |
| `ENFORCE_KICK_VANILLA` | `true` | kick real (Java) Minecraft clients too |
| `ENFORCE_KICK_ON_UNKNOWN` | `false` | kick when the check itself failed (leave `false` — otherwise a proxy hiccup can lock everybody out of your own server); only matters while `ENFORCE_VERIFIED_CLIENT=true` |
| `ENFORCE_BYPASS_PLAYERS` | `""` | comma separated names that may join with any client |
| `HIDE_VERIFIED_IP` | `true` | keep the verified client's IP hidden in activity/console logs while retaining the `VERIFIED CLIENT` marker and redacting its brand/UUID |
| `PRIVATE_IP_LOG` | `true` | keep real IP sightings in `private-logs/addresses.log` |
| `FORWARD_IP` | `auto` | where the real client IP comes from: `auto` probes which header the proxy sends once and remembers it, `on` trusts `FORWARD_IP_HEADER`, `off` keeps the proxy's address, or put a header name here |
| `FORWARD_IP_HEADER` | `""` | header to trust (with `FORWARD_IP=auto` + a name here it is used without probing) |
| `FORWARD_IP_CANDIDATES` | `X-Real-IP X-Forwarded-For CF-Connecting-IP True-Client-IP X-Envoy-External-Address X-Client-IP` | headers tried in that order |
| `FORWARD_IP_RETRY_INTERVAL` | `600` | seconds between background retries of the header discovery while the logged addresses are still the proxy's (only ever with nobody online; `0` disables) |
| `AUTH_FILTER_PATCH` | `true` | neutralise the LoginSecurity/AuthMe password filter before Paper starts, so `/login` reaches the console and `auth.log` fills; `false` leaves the plugin jars untouched (and the logins stay invisible) |
| `PUBLIC_URL` | `https://smodusermc-12.hf.space/` | what the probe connects to (the same path players take) |
| `LOG_STATUS_INTERVAL` | `60` | how often `security-logs/status.txt` is refreshed |
| `LOG_SYNC_INTERVAL` | `60` | interval for the small, scoped log-prefix sync |
| `SYNC_INTERVAL` | `600` | interval for the full world/game-data snapshot |
| `REPORT_INTERVAL` | `300` | minimum time between address-report regenerations |
| `PLAYERLIST_POLL` | `60` | RCON player-list safety poll interval |

Note that the brand is inside the client file, so it is only as private as the
file and the secrets that hold it: whoever learns the brand can rebuild a client
that reports it. That is why rotating (`--rotate`) is the way to revoke a client
and why the pair is not written down in this repository.

## IPs: forwarded address or proxy address?

Players reach the server through the Hugging Face ingress. Without a forwarded
header the game can only log the ingress/proxy address; it cannot infer the
player's real address from a socket. EaglerXBungee can read a forwarded header
(`forward_ip` + `forward_ip_header` in `listeners.yml`), **but it disconnects
connections that lack the configured header**. Guessing can therefore block
players, so `start.sh` treats a header as something to prove, not assume:

1. with `FORWARD_IP=auto` (default) it starts with `forward_ip: false`;
2. after the server is up it tests candidate headers via the public URL, using a
   real WebSocket upgrade;
3. it accepts a header only when the probe reaches the backend and the plugin
   does not report a refusal;
4. the selected header (or an `off` result) is persisted in
   `private-logs/forward-ip.state` and restored on a later boot. A failed
   self-probe can be retried every `FORWARD_IP_RETRY_INTERVAL` seconds, but only
   while nobody is online because changing the proxy setting restarts it.

`security-logs/status.txt` reports the current client-IP setting, known proxy
peers and whether logged addresses match a proxy peer. Proxy peers are retained
in `private-logs/proxy-peers.log`; they are read from the kernel's connection
tables by `tools/proxy_peers.py`. The address report then classifies the IPs
rather than assuming every address is a player:

```
security-logs/addresses.txt
IP ADDRESS REPORT
Updated: 2026-10-05 09:20:00 PM EDT
Verified-client addresses are omitted from this public report.

ACCOUNTS AND ADDRESSES
Alice   1.2.3.4   paper (seen 2 time(s))
Bob     1.2.3.4   paper (seen 1 time(s))

ADDRESSES SHARED BY ACCOUNTS
1.2.3.4   Alice, Bob

PROXY VS PLAYER ADDRESSES
1.2.3.4   PROXY address (not a player)   2 account(s)
5.6.7.8   real client address            1 account(s)
Both proxy and client addresses are present; some connections lack a forwarded IP.
```

The private `private-logs/addresses.txt` includes the verified client's real
address. The append-only `private-logs/addresses.log` keeps each dated sighting
and its source. The activity log hides a pending address until the check resolves;
a verified client's address stays hidden there. Public reports omit the
verified account/address, while the private report is the bucket view to use
when you need to inspect it.

An address equal to a connection peer of the game port is evidence that the
server logged a proxy address, not the player's. A non-peer address is treated
as a client address, but that classification is not a substitute for a working
forwarded header. If no header works, `status.txt` says plainly that the logs
contain proxy addresses. One device can also appear over IPv4 and IPv6; the
report notes dual-stack accounts rather than calling them two devices.

The login row is written as soon as a join arrives, before the client check
resolves. It stays IP-hidden while pending; the resolved `CHECK` row carries a
non-verified player's address. Addresses are stored per account, never by
position in a shared log, so simultaneous joins cannot swap them.

### Where the brand is (and is not) written down

| place | what is there |
| --- | --- |
| `client/1.12.html` (committed) | a PBKDF2-SHA512 verifier of the brand; the brand itself only inside the sealed payload |
| `start.sh` (committed) | the pair XOR'd + base64, decoded at boot |
| `.verified-client.env` (git-ignored) | the pair in clear text, for local tools/tests |
| the Space | optional `VERIFIED_CLIENT_BRAND` / `VERIFIED_CLIENT_UUID` secrets, which win over the baked pair |
| `security-logs/status.txt` | which pair is configured, logger health, and client-IP forwarding status |

Burned (refused by `start.sh` even if configured, and by the builder) are the
brands that were public at some point: the stock one, `Eaglercraft[VER]`,
`EaglercraftX[V2]` and `EaglercraftX[SV]`.

**The honest limit:** the obfuscation in `start.sh` is not encryption — the key
is in the same file, so anyone who can read this repository can decode the pair
and build a client that reports it. What the seal *does* protect is the client
file: without the login, nobody can read the brand out of `client/1.12.html`.
If the mark must stay unforgeable, make the repository private or keep the pair
only in the Space secrets and delete the baked blob.

If the Space ever loses the pair, the boot log and
`security-logs/status.txt` says `NOT CONFIGURED`, nobody is marked as you,
and `auth.log` masks every password until it is set again.

### End-area lag: diagnose before changing gameplay

The reported stutter is near an **End gateway or the End's return-to-overworld
portal**, and is not usually near the overworld stronghold portal. That alone
does not identify the cause. It could be client rendering, a server tick/chunk
load, entities, network delay, or more than one of those. A client-only FPS drop
and a server-wide TPS drop need different fixes.

There is an existing client-side edit that caps a compiled End Portal render-pass
count, plus packaged asset/animation changes. Those changes are separate from
Paper's server tick loop. The automated checks verify the WASM edit's structure
and that the package round-trips; they do **not** benchmark actual gameplay. A
previous visual check showed no noticeable improvement, and no current live
End-area A/B, 2019-phone measurement, server CPU trace, or TPS profile is
available. So these edits are not evidence that the lag is fixed.

The inspected render-pass edit targets the End Portal render path. It does not
establish a cause in the separate End Gateway path, server chunk loading, or
entity ticking. In particular, do not infer that an End gateway hitch is caused
by the portal shader, or change the server's view distance/mob/gameplay settings
without a controlled reproduction.

A useful comparison is:

1. keep the same client/device, world, render settings and approximate player
   count; note client FPS (if available) and whether other players stutter too;
2. test the End gateway, the End exit/return portal, and the overworld stronghold
   portal as separate locations; record a short baseline away from each;
3. for the server-side sample, use Paper timings from an admin console: run
   `/timings reset`, `/timings on`, reproduce one location for a fixed interval,
   then `/timings off` and `/timings paste`. Review the report before sharing it;
   it can contain operational details;
4. compare the timings/CPU change with the client FPS. A TPS/timing spike seen
   by everyone points toward server-side work; one device's FPS drop with stable
   server timings points toward client-side work. Treat this as evidence, not a
   diagnosis, and repeat each location under similar load.

Until that comparison exists, the server-side changes in this branch are
restricted to background bucket/log work. They do not change the configured
gameplay view distance, entity rules, tick rate, or player settings. No
server-TPS or no-lag claim is being made.

The repository still contains `tools/optimize_client.py` for reproducing the
existing client-package transformations and their fixtures. Do not apply further
texture/animation/render-pass reductions as a guessed fix for gateway or
server-side lag; first identify which side is actually stalling.

## What actually has to go into the Space

**Two files**, everything else in this repo is for development — and one thing
you set once in the Space's UI (the brand/UUID):

```bash
hf auth login                     # token with write access to smodusermc/12
bash tools/setup-verified-client.sh --rotate --gate-user sllab --upload
                                  # builds the client, prints the secrets, uploads it
bash tools/push-to-space.sh --with-readme      # uploads Dockerfile + start.sh (+ README)
```

The pair is **already baked into `start.sh`** (obfuscated), so nothing else is
required: the Space marks your client out of the box. The secrets are optional —
add `VERIFIED_CLIENT_BRAND` / `VERIFIED_CLIENT_UUID` (Settings → Variables and
secrets) only if you want to override the baked pair without pushing files; the
environment always wins, and a stale secret after a rotation is reported at boot.

After the client is rebuilt, refresh it in the bucket (no Space rebuild needed):

```bash
bash tools/push-to-space.sh --client-only
```

or by hand (one folder = one commit = one Space rebuild):

```bash
mkdir -p /tmp/space-files && cp Dockerfile start.sh README.md /tmp/space-files/
hf upload smodusermc/12 /tmp/space-files . --repo-type space
```

| File | Upload? | Why |
| --- | --- | --- |
| `Dockerfile` | **yes** | build recipe; the old one must be replaced (it no longer needs `client/`) |
| `start.sh` | **yes** | all the server logic, logging, enforcement, bucket syncs |
| `README.md` | optional | Space card + documentation (same front-matter as before) |
| `config/bungee/EaglerXBungee.jar` | only if needed | keep the Space's copy — it is LFS-tracked there. Upload this one (585 KB, v1.3.6) **only** if `activity.log` has `client=UNKNOWN CLIENT` / `Unknown command` for everybody, meaning the Space's plugin does not know `client-brand name <player>` |
| `client/1.12.html` | **no** (to the Space) | 22 MB, and the Space does not need it — it is committed in this repo and published in the bucket (below). Note this is about the *Space*: the Space repo is public, and the client does not reveal the brand, so committing it in your own repo is fine |
| `plugins/`, `config/bungee/EaglerXServer.jar` | **no** | the Space already has them (AuthMe jars are LFS-tracked there) |
| `.gitattributes`, `.gitignore` | **no** | leave the Space's own LFS rules alone |
| `tools/`, `tests/`, `docs/` | **no** | dev-only; nothing in the image uses them |

Uploading a single file works too:

```bash
hf upload smodusermc/12 start.sh  start.sh  --repo-type space
hf upload smodusermc/12 Dockerfile Dockerfile --repo-type space
```

The Space rebuilds itself after every upload; watch it in the Space's *Logs*
tab. A single masked, labeled snapshot is mirrored to
`game-data/logs/console.log` in the bucket.

### Where the client goes instead

The client is committed in this repo **and** belongs in the bucket: the bucket
is private and reachable from anywhere, which is what you hand out.

The client must **not** sit in the Space repo (public) — keep it in the bucket,
which is private and reachable from anywhere:

```bash
# upload (once)
hf buckets cp client/1.12.html hf://buckets/smodusermc/1.12/client/1.12.html

# download on your machine whenever you need it
hf buckets cp hf://buckets/smodusermc/1.12/client/1.12.html ./1.12.html
```

Put it at the bucket root like that, **not** under `game-data/` — the full
game-data sync runs with `--delete` and would remove anything there that the
server did not stage itself.

Required Space settings: a `HF_TOKEN` secret with write access to the bucket
(`EXPOSE 7860` is already handled). Players join on
`wss://smodusermc-12.hf.space/` with the client you hand them.

## Notes

* The default private bucket prefix includes other players' full auth commands
  (`private-logs/auth.log`) and real IPs (`private-logs/addresses.log` and
  `private-logs/addresses.txt`). Keep the bucket private. Setting
  `SYNC_PRIVATE_LOGS=false` also deletes that old bucket prefix; it is not a
  redaction mode.
* `plugins/` also needs **LoginSecurity** (the plugin whose `/login` lines are
  logged) if the Space image does not already ship it.
* `plugins/` needs the AuthMe jars from the original Space (`AuthMe-6.0.1-Bungee.jar`,
  `AuthMeBungee-2.2.0-beta1.jar`); they are binary files and are not in this
  checkout — see `plugins/README.md`.
* `config/bungee/EaglerXServer.jar` (unused by the Dockerfile) is not committed here.
* The old Paper login parser bug (a missing `]` after the port) is fixed. New
  rows go to `security-logs/activity.log`; `tools/log_migrate.py` converts and
  consolidates legacy records on startup.
* The JVM memory-sizing block keeps `PAPER_MIN_MB <= PAPER_MAX_MB` on small
  Spaces; tests exercise the real block for five memory sizes.
* Bucket/log work is serialized and run behind `nice -n 19` plus `ionice -c3`
  when available. World snapshots default to 600 seconds, scoped logs to 60
  seconds, reports to 300 seconds, and the RCON safety poll to 60 seconds. This
  reduces how often the background jobs scan/copy data, but these changes have
  not been measured against a live Space, TPS, or player session. The repository
  makes no claim of a proven CPU reduction or zero gameplay impact until those
  tests are run.
