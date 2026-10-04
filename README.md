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
* an append-only **security log** of logins, commands and client checks, with
  the verified client's own IP hidden and everybody else fully logged
* a **private log** (`private-logs/`) of full `/login`-style commands of every
  account except the verified client's (whose own `/login` is recorded with the
  password masked, so the file still shows that it happened)
* **truthful client IPs**: the game reads the real address out of the forwarded
  header the proxy sends (it finds out which one by itself), so accounts are not
  lumped together under one proxy address

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
| `tools/optimize_client.py` | cuts what costs frames on weak machines (end portal render passes, end portal texture, animation frames) and re-seals the client |
| `tools/epk.py` / `tools/pnglite.py` | the EPK package and PNG readers/writers that optimiser needs (no external libraries) |
| `tools/run_epw_loader.mjs` | boots the client's own EPW loader to prove the file loads |
| `tools/forward_ip_probe.py` | asks the proxy whether it sends a forwarded-IP header (embedded in `start.sh`) |
| `tools/proxy_peers.py` | the addresses of the proxy that sits in front of the game port, from the kernel's own tables (embedded in `start.sh`) |
| `tools/patch_auth_filter.py` | stops LoginSecurity/AuthMe from hiding `/login` from the console (embedded in `start.sh`) |
| `tools/bucket_sync.py` | uploads a folder to the bucket (the fallback used when `hf` fails; embedded in `start.sh`) |
| `tools/embed_tools.py` | keeps those embedded copies in sync (the tests fail when they differ) |
| `tools/fetch-logs.sh` | downloads all the server logs from the bucket |
| `tools/push-to-space.sh` | uploads only the files the Space needs |
| `tests/test_verified_client.sh` | test suite (client ⇄ server consistency + detection) |
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

That means the client can be committed and handed out freely: reading the brand
out of it needs the login. `--check` therefore reports
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

The bucket is the only place the logs can be read from outside the Space, so
both log folders **and** the raw console tails are pushed to it — the small
ones every `LOG_SYNC_INTERVAL` seconds (60), the full game data every
`SYNC_INTERVAL` seconds (300):

```
hf://buckets/smodusermc/1.12/game-data/security-logs/logins.log              logins (IPs/verdicts)
hf://buckets/smodusermc/1.12/game-data/security-logs/commands.log            every command
hf://buckets/smodusermc/1.12/game-data/security-logs/client-checks.log       verified / other / vanilla per login
hf://buckets/smodusermc/1.12/game-data/security-logs/shared-ips.txt          shared-IP + verdict report
hf://buckets/smodusermc/1.12/game-data/security-logs/ip-report.log           every IP per account + shared-IP pairs
hf://buckets/smodusermc/1.12/game-data/security-logs/logger-status.log       is the logger seeing joins? raw lines
hf://buckets/smodusermc/1.12/game-data/security-logs/proxy-peers.txt         the proxy's own addresses (so an address can be classified)
hf://buckets/smodusermc/1.12/game-data/private-logs/auth.log                 full /login lines (passwords)
hf://buckets/smodusermc/1.12/game-data/private-logs/player-ips.log           real IPs behind "hidden"
hf://buckets/smodusermc/1.12/game-data/private-logs/logins-real-ips.log      logins with the real IPs
hf://buckets/smodusermc/1.12/game-data/private-logs/shared-ips-private.txt   report with the real IPs
hf://buckets/smodusermc/1.12/game-data/private-logs/ip-report-private.log    the IP report including your own IPs
hf://buckets/smodusermc/1.12/game-data/logs/paper.log                        last 1000 console lines (passwords masked)
hf://buckets/smodusermc/1.12/game-data/logs/bungee.log                       last 1000 console lines (passwords masked)
```

Get them locally in one go:

```bash
bash tools/fetch-logs.sh            # -> ./server-logs/{security-logs,private-logs,logs}
```

Switches: `SYNC_PRIVATE_LOGS=false` stops uploading `private-logs/` (then
`auth.log` and the real IPs only exist inside the Space — and you cannot read
them from outside), `SYNC_CONSOLE_LOGS=false` stops the console tails,
`SYNC_INTERVAL` / `LOG_SYNC_INTERVAL` change the sync periods.

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

⚠️ With the defaults the bucket contains **clear-text passwords** (`auth.log`)
and **your real IP** (`player-ips.log`), so keep the bucket private.

`start.sh` asks the proxy for the brand of every player that joins
(`/client-brand`, over a console pipe), **kicks everybody who is not the
verified client** and records the result:

```
security-logs/logins.log          DATE | LOGIN  | name | hidden            <- verified client: nothing else
                                  DATE | VERIFY | name | ip | OTHER EAGLERCRAFT CLIENT | brand=... | uuid=...
                                  DATE | LOGOUT | name | ip | client=...   <- non-verified clients only
security-logs/commands.log        DATE | name | ip | command | client=...  (passwords masked)
security-logs/client-checks.log   DATE | VERDICT | name | ip | brand=... | version=... | uuid=...
security-logs/shared-ips.txt      report: shared IPs + verification summary
security-logs/ip-report.log       every IP an account was seen from (sources shown)
security-logs/logger-status.log   whether the logger sees joins, with the raw lines

private-logs/auth.log             DATE | name | ip | /login hunter2 | client=...   <- full passwords
private-logs/player-ips.log       the real IPs that show as "hidden" above
private-logs/ip-report-private.log  the IP report including your own IPs
private-logs/shared-ips-private.txt, private-logs/logins-real-ips.log
logs/paper.log, logs/bungee.log   last 1000 lines of the raw servers
```

Nothing that identifies the verified client is in the synced logs: its IP is
written as `hidden`, it gets no `client=...` tag and no `VERIFY` line, so a
login by you is just `DATE | LOGIN | <name> | hidden` followed by the logout.
Everyone else keeps full IPs, verdicts and labels.

**Passwords:** `/login`, `/l`, `/log`, `/register`, `/reg`, `/changepassword`,
`/changepass`, `/unregister` and `/authme` are masked (`/login ********`) in
`commands.log`, and kept in full in `private-logs/auth.log` — **except** for the
verified client, whose password is never written anywhere (its row there is
`/login ********` with `ip=hidden`, so the file still shows the login happened).
Use it to recover a password a player set for you.

**Anybody can join with any client** — `ENFORCE_VERIFIED_CLIENT=false` is the
default. The verified client is only *marked* in the logs (your IP is hidden,
your lines carry no `client=...` tag); everybody else is logged with their real
IP, their commands and their labels. If you ever want the server to be
exclusive, set `ENFORCE_VERIFIED_CLIENT=true` and `UNVERIFIED`/`VANILLA`
clients are kicked right after the login; a check that could not run
(`UNKNOWN`/`CONSOLE_DOWN`, e.g. the proxy restarting) never kicks, so you cannot
lock yourself out, and `ENFORCE_BYPASS_PLAYERS` lists names that may always in.

While the brand is **not configured** (fresh Space, secrets forgotten) the
server cannot tell your own `/login` from anybody else's, so it writes *no*
password in clear — every row in `private-logs/auth.log` is masked
(`client=UNCONFIGURED`) until the pair is set. Set it and the full passwords of
other players start being recorded again.

`VERDICT` is one of:

| Verdict | Meaning |
| --- | --- |
| `VERIFIED` | this repo's client (brand UUID matches `VERIFIED_CLIENT_UUID`) |
| `UNVERIFIED` | some other Eaglercraft client / fork / edited client |
| `VANILLA` | a real (Java) Minecraft client, not Eaglercraft |
| `UNKNOWN` | could not be checked (proxy busy/down) |

| Label in `logins.log` / `commands.log` | Meaning |
| --- | --- |
| `OTHER EAGLERCRAFT CLIENT` | some other Eaglercraft client / fork / edited client |
| `JAVA CLIENT` | a real (Java) Minecraft client, not Eaglercraft |
| `UNKNOWN CLIENT` | could not be checked (proxy busy/down) |
| *(no label at all)* | this was the verified client — hidden on purpose |

So a quick look at the log tells you whether a login was you (or someone you
gave the client to) or somebody else:

```
$ tail -f /opt/server/backend/security-logs/logins.log
2026-10-02 21:14:01 | LOGIN  | CreppyBitch | hidden
2026-10-02 21:14:40 | LOGOUT | CreppyBitch | hidden

2026-10-02 21:15:46 | LOGIN  | RandomDude  | hidden
2026-10-02 21:15:48 | VERIFY | RandomDude  | 5.6.7.8 | OTHER EAGLERCRAFT CLIENT | brand=Eaglercraft 1.12 | version=u2 | uuid=522b2ce5-c9b9-36cf-be7c-5d90f55e631a
2026-10-02 21:15:49 | LOGOUT | RandomDude  | 5.6.7.8 | client=OTHER EAGLERCRAFT CLIENT

$ tail -f /opt/server/backend/security-logs/commands.log
2026-10-02 21:14:40 | CreppyBitch | hidden | /gamemode 1
2026-10-02 21:15:52 | RandomDude  | 5.6.7.8 | /gamemode 1 | client=OTHER EAGLERCRAFT CLIENT

$ cat /opt/server/backend/private-logs/auth.log        # passwords in clear
2026-10-02 21:14:12 | CreppyBitch | hidden | /login ******** | client=VERIFIED CLIENT (password not recorded)
2026-10-02 21:15:52 | RandomDude  | 5.6.7.8 | /login hisnewpass | client=OTHER EAGLERCRAFT CLIENT

$ cat /opt/server/backend/private-logs/player-ips.log  # the IPs behind "hidden"
2026-10-02 21:14:01 | CreppyBitch | 203.0.113.7
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
also checks the hidden-IP logging, the enforcement (kicks), the `/login` logging
against a fake Bungee console, the IP report, the forwarded-IP discovery (with a
fake proxy that refuses headers), the proxy-peer
evidence (against a fixture of the kernel's own tables), the low-end-device rules
(end portal passes + texture + animation frames, with the untouched files
compared byte for byte), the auth-filter patch (its rule table, a fixture jar it
patches and a real JVM loads, the `javap` rollback and the switch), the masking
of the bucket's console copies, the per-account addresses, that the JVM heap
sizing can never hand the JVM an `-Xms` above its `-Xmx` (checked against five
Space sizes by running the real block from `start.sh`), that the bucket sync and
the world copy run at the lowest CPU/disk priority and report how long they took,
and that the copies embedded in `start.sh` match `tools/`. With the client credentials in the
environment it additionally **runs the real login gate and boots the client's
own EPW loader** in Node, i.e. it proves the file you hand out works:

```bash
bash tests/test_verified_client.sh              # 320 checks
VER_CLIENT_USER=<user> VER_CLIENT_PASS=<password> \
    bash tests/test_verified_client.sh          # 342 checks (adds the real client)

# same, but print the logs it produced, so you can see the formats:
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
| the server itself | RCON `list`, polled every `PLAYERLIST_POLL` (20) s | catches anything the log files never showed, whatever the console format is |

The first of them that arrives writes the single `LOGIN` row (the name is
marked online, so the other two stay quiet) and every login/logout is echoed to
the console as `[LOG] LOGIN <name>` — visible in the Space's *Logs* tab, i.e.
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

The result is written to `security-logs/logger-status.log` as a
`login capture :` line, and to the console as `[AUTHPATCH] …` lines (visible in
the Space's *Logs* tab). Set `AUTH_FILTER_PATCH=false` to switch it off (then
`/login` is hidden again and `auth.log` stays empty).

The passwords themselves stay where they were: `private-logs/auth.log` in full
for everybody except the verified client, masked in `commands.log`, and the
copies of the raw console logs that go to the bucket have every auth argument
masked as well, so the bucket never carries your own password twice.

### Policy switches (top of `start.sh`)

| Setting | Default | What it does |
| --- | --- | --- |
| `ENFORCE_VERIFIED_CLIENT` | `false` | `false` (default) = **everybody may join**, the verified client is only marked in the logs; `true` = kick everything that is not the verified client |
| `ENFORCE_KICK_VANILLA` | `true` | kick real (Java) Minecraft clients too |
| `ENFORCE_KICK_ON_UNKNOWN` | `false` | kick when the check itself failed (leave `false` — otherwise a proxy hiccup can lock everybody out of your own server); only matters while `ENFORCE_VERIFIED_CLIENT=true` |
| `ENFORCE_BYPASS_PLAYERS` | `""` | comma separated names that may join with any client |
| `HIDE_VERIFIED_IP` | `true` | write the verified client's IP as `hidden` and omit its `client=...`/`VERIFY` lines in the synced logs |
| `PRIVATE_IP_LOG` | `true` | keep the hidden IPs in `private-logs/player-ips.log` |
| `FORWARD_IP` | `auto` | where the real client IP comes from: `auto` probes which header the proxy sends once and remembers it, `on` trusts `FORWARD_IP_HEADER`, `off` keeps the proxy's address, or put a header name here |
| `FORWARD_IP_HEADER` | `""` | header to trust (with `FORWARD_IP=auto` + a name here it is used without probing) |
| `FORWARD_IP_CANDIDATES` | `X-Real-IP X-Forwarded-For CF-Connecting-IP True-Client-IP X-Envoy-External-Address X-Client-IP` | headers tried in that order |
| `FORWARD_IP_RETRY_INTERVAL` | `600` | seconds between background retries of the header discovery while the logged addresses are still the proxy's (only ever with nobody online; `0` disables) |
| `AUTH_FILTER_PATCH` | `true` | neutralise the LoginSecurity/AuthMe password filter before Paper starts, so `/login` reaches the console and `auth.log` fills; `false` leaves the plugin jars untouched (and the logins stay invisible) |
| `PUBLIC_URL` | `https://smodusermc-12.hf.space/` | what the probe connects to (the same path players take) |
| `LOG_STATUS_INTERVAL` | `60` | how often `security-logs/logger-status.log` is refreshed |

Note that the brand is inside the client file, so it is only as private as the
file and the secrets that hold it: whoever learns the brand can rebuild a client
that reports it. That is why rotating (`--rotate`) is the way to revoke a client
and why the pair is not written down in this repository.

## IPs: why they were wrong and how they are right now

Players reach the server through the Hugging Face ingress, so every connection
arrives from the proxy's address unless the proxy is told to pass the client's
address in a header. EaglerXBungee can read that header
(`forward_ip` + `forward_ip_header` in `listeners.yml`), **but it disconnects
anybody whose connection lacks it** — so guessing the header can lock every
player out for good.

`start.sh` therefore treats it as something to prove, not to guess:

1. with `FORWARD_IP=auto` (default) it starts with `forward_ip: false`;
2. after the server is up it tries the candidate headers one at a time, as a
   real WebSocket upgrade through the public URL (the same path a player takes);
3. a header is only kept when the probe really got through **and** the plugin's
   log does not say it refused that header;
4. the winning header is written to `private-logs/forward-ip.state`, which is
   synced to the bucket **and restored into the container at boot**, so the next
   boot uses it immediately and never probes again. If no header works, `off` is
   remembered instead; if the Space could not reach itself at all it tries again
   every `FORWARD_IP_RETRY_INTERVAL` seconds (600) — but only while nobody is
   online, because applying a header restarts the proxy, and an `off` that a
   probe really decided is only re-asked every sixth interval (about an hour),
   since the answer rarely changes. This matters because
   the boot probe can only succeed once the Space really answers on its public
   URL, which is usually *not* the case while it is still starting up: without
   the retry a failed boot probe was final until the next restart.

The result is visible in the logs:

```
security-logs/logger-status.log       real client IPs: on (X-Real-IP) - the logged IPs are the players' real addresses
                                      proxy peers    : 1.2.3.4 1.2.3.5
                                      ip evidence    : the addresses in the logs are not proxy peers - they are the players' own
security-logs/ip-report.log           every IP per account + which accounts share one + which address is a player's
private-logs/ip-report-private.log    the same report including your own IPs
security-logs/proxy-peers.txt         the proxy's own addresses, so a log address can be classified
private-logs/proxy-peers.log          the same list with the time each one was first seen
```

Those two "proxy peers" lines are not a guess: everything from outside reaches
the game port through the ingress, so the **peers of that port are the proxy's
addresses** (read from the kernel's own tables — `tools/proxy_peers.py`, no `ss`
needed). An address in the logs that equals a peer is the proxy's, and one that
does not is a player's own. `ip-report.log` ends with that classification:

```
=== Which address is a real client address ===
  1.2.3.4 -> the PROXY address (not a player), 3 account(s)
  5.6.7.8 -> a real client address (not a proxy peer), 2 account(s)
  verdict: both kinds are present - a row with the PROXY address had no forwarded header

=== One device, two protocols (IPv4 + IPv6) ===
  1 account(s) -> seen over IPv4 and IPv6 - that is one device, not two
```

The last section answers the other way an "IP" can look wrong: one machine that
reaches the Space over IPv4 one time and IPv6 the next shows two addresses that
are both correct, and it is still one device.

If no header works, the status line says so in plain words
(`… OFF - the logged IPs are the ADDRESS OF THE PROXY, not the player's …`) —
because then *every* address the server can possibly log is the proxy's one, and
an account that connects twice through two different proxy nodes really does
show two different addresses. That is what "the IPs are wrong" turns out to be
when forwarding is off; with a working header every account gets its own real
address and it stays the same across logins.

Two more things worth knowing when reading the IPs:

* the `LOGIN` row is written the moment the join line arrives, which is *before*
  the client check has resolved — while `HIDE_VERIFIED_IP=true` an unresolved
  address is written as `hidden` (that also protects your own). The address of a
  normal player appears on its `VERIFY` line and in `ip-report.log`; yours stays
  in `private-logs/player-ips.log` and `ip-report-private.log`;
* addresses are recorded per account, never by position in the log, so two
  accounts that are online at the same time cannot swap addresses.

`ip-report.log` is the file to read when an IP looks wrong: a proxy address
would appear for *every* account, while real client addresses appear per
account. It lists one line per account/address/source:

```
=== Accounts and the IPs they were seen from ===
  Alice -> 1.2.3.4 (paper) x2
  Alice -> 9.9.9.9 (bungee-handshake) x1
=== One IP, several accounts ===
  1.2.3.4 -> Alice Bob
```

Placeholders (`unknown`, `hidden`) are never treated as an address, which is
what used to make unrelated accounts look like they shared one.

### Where the brand is (and is not) written down

| place | what is there |
| --- | --- |
| `client/1.12.html` (committed) | a PBKDF2-SHA512 verifier of the brand; the brand itself only inside the sealed payload |
| `start.sh` (committed) | the pair XOR'd + base64, decoded at boot |
| `.verified-client.env` (git-ignored) | the pair in clear text, for local tools/tests |
| the Space | optional `VERIFIED_CLIENT_BRAND` / `VERIFIED_CLIENT_UUID` secrets, which win over the baked pair |
| `security-logs/logger-status.log` | which pair is in use and where it came from |

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
`security-logs/logger-status.log` say `NOT CONFIGURED`, nobody is marked as you,
and `auth.log` masks every password until it is set again.

### Low-end machines (4 GB Chromebooks and friends)

Three things in the shipped client cost real frames on weak hardware, and all
three are fixed *inside the client file* — no setting to change, nothing to
remember, the same login and the same brand:

**1. The end portal's render passes — the stronghold/End lag.** This is the big
one, and it is not the texture: `RenderEndPortal` draws the portal quad **once per
pass, up to 15 times**, each pass with its own texture-matrix change and a blended
draw, and the count comes straight from the squared distance to the block
(`getPasses`). In a browser every one of those GL calls crosses the wasm → JS
boundary, so a 3x3 portal is a few thousand calls and a few hundred draw calls
*per frame* — that is the reported "if you go to the stronghold/end and the portal
is in render distance, it lags really bad". The pass count is compiled into
`classes.wasm` as single-byte constants, so the optimiser finds that chain and
**caps it at 7 passes** (one byte per count, the module still compiles, and the
edit can only ever make the client lighter). The portal keeps its layered
starfield, with half the layers; `--portal-passes` tunes it (`3` = fastest,
`0` = leave the stock numbers, `PORTAL_PASSES` for the rebuild script).

**2. The end portal / End sky texture** (`entity/end_portal.png`) shipped as
256x256 (256 KiB) and is sampled by every one of those passes (the End's sky
wallpaper uses the same file), so the passes were both call-heavy *and* cache
unfriendly. It is a soft noise field, so it is now **32x32**: 1/64th of the
memory, and the passes sample from L1 instead of thrashing. The look in motion is
unchanged.

**3. Animated texture strips.** Water, lava, fire, the nether portal, sea lantern
and command blocks shipped as 32/20/16-frame strips (16x16 each). Every frame is
uploaded to the GPU as its own layer and re-uploaded on a timer, which is what
produces the periodic hitch when water or lava fills the screen. Animation is
*time based*, so `tools/optimize_client.py` keeps every n-th frame and multiplies
that texture's `frametime` by n: water and lava now animate at 15 fps instead of
60 — on a 4 GB machine that is already below 60 — with a quarter of the memory
and a quarter of the upload work. Lists that are hand-written (lava's ping-pong,
the prismarine flicker) are **left alone**, and everything else in the package is
copied byte for byte.

```bash
# what it would change (nothing is written)
python3 tools/optimize_client.py client/1.12.html --dry-run

# re-optimise the committed client in place (credentials from .verified-client.env)
python3 tools/optimize_client.py client/1.12.html --output /tmp/c.html && mv /tmp/c.html client/1.12.html

# keep 8 frames per animation (default), or 4 for an even weaker machine
python3 tools/optimize_client.py client/1.12.html --frames 4
# fewer end portal layers (3 = fastest) / leave the stock renderer alone
python3 tools/optimize_client.py client/1.12.html --portal-passes 3
python3 tools/optimize_client.py client/1.12.html --portal-passes 0
# leave the end portal texture alone
python3 tools/optimize_client.py client/1.12.html --end-portal 0

# a resource pack instead: same two rules, pack stays a pack
python3 tools/optimize_client.py --pack mypack.epk -o mypack.optimized.epk
```

The tool re-seals the payload with the **same salt, IV and iterations**, so the
same username/password keeps working and the brand (and therefore the server's
verification) is untouched. The optimisation steps are independent: `--frames`,
`--end-portal` and `--portal-passes` can each be switched off, and re-running the
tool on an already optimised client changes nothing (the suite asserts the
committed client reproduces byte for byte). `tools/setup-verified-client.sh` runs it
automatically after a rebuild (`--no-optimize` skips it), and the test suite
asserts that the committed client is already in that shape: optimising it again
has to reproduce the same file byte for byte.

What is deliberately **not** touched, and why: every texture that is mapped by
UV coordinates (blocks, items, entities, GUI, the font) has to keep its exact
pixel grid, so re-scaling it would corrupt the game; the sounds are already
compressed; and the gameplay settings (`render distance`, `fancy/fast graphics`,
`smooth lighting`, `particles`, `clouds`, `max framerate`, `music`) belong to you
and are one click away in the client's own *Options* screen — those still matter
more than anything in the file. Two things worth knowing on a 4 GB machine:

* a **custom texture pack** is the biggest remaining lever after that, because
  the client decodes, decompresses and re-uploads every texture of a pack when it
  loads it — including its own animated strips, which replace the optimised ones.
  Run the tool on the pack itself (`--pack`) before handing it out, and prefer
  packs whose `entity/end_portal.png` is not huge;
* if the game still hitches with a pack loaded, it is the pack load, not the
  server: the pack is decoded on the machine, once per load.

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
| `config/bungee/EaglerXBungee.jar` | only if needed | keep the Space's copy — it is LFS-tracked there. Upload this one (585 KB, v1.3.6) **only** if `client-checks.log` shows `UNKNOWN` / `Unknown command` for everybody, meaning the Space's plugin does not know `client-brand name <player>` |
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
tab, and the running server's own console is mirrored to
`game-data/logs/paper.log` + `logs/bungee.log` in the bucket.

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

* The bucket contains clear-text passwords (`private-logs/auth.log`) and your
  real IP (`private-logs/player-ips.log`) with the default settings — keep the
  bucket private; `SYNC_PRIVATE_LOGS=false` stops uploading them.
* `plugins/` also needs **LoginSecurity** (the plugin whose `/login` lines are
  logged) if the Space image does not already ship it.
* `plugins/` needs the AuthMe jars from the original Space (`AuthMe-6.0.1-Bungee.jar`,
  `AuthMeBungee-2.2.0-beta1.jar`); they are binary files and are not in this
  checkout — see `plugins/README.md`.
* `config/bungee/EaglerXServer.jar` (unused by the Dockerfile) is not committed here.
* The login regex in the original `start.sh` was missing the `]` after the
  port, so Paper logins were never written to `logins.log`; this is fixed here.
* the memory sizing block at the top of `start.sh` used to hard-code
  `PAPER_MIN_MB=8192`, i.e. `-Xms8192M` against an `-Xmx` that shrinks with the
  Space's RAM — on anything smaller than a 16 GB Space `Xms > Xmx` and the JVM
  refuses to start at all ("Initial heap size set to a larger value than the
  maximum heap size"). The initial heap is now half of the maximum, capped at
  4096 MB, so `Xms <= Xmx` always holds.
* the bucket sync, the world copy and the log parsers run at the lowest CPU and
  disk priority (`nice -n 19`, plus `ionice -c3` where the container allows it).
  They share two cores with Paper: without this, a full world copy + upload every
  `SYNC_INTERVAL` seconds (300 by default) competes with the tick loop, which is
  felt in game as a periodic hitch. The sync and log-loop lines print how long
  each run took, so a slow Space is visible in the logs instead of guessed at.
