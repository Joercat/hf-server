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
| `client/1.12.html` | **the verified client** — patched, sealed behind a login (see below) |
| `tools/patch_verified_client.py` | patches / inspects / seals the client brand |
| `tools/verify_gated_client.mjs` | runs the real login gate + loader headless: proves the file only boots after the login |
| `tools/run_epw_loader.mjs` | boots the client's own EPW loader to prove the file loads |
| `tools/forward_ip_probe.py` | asks the proxy whether it sends a forwarded-IP header (embedded in `start.sh`) |
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
stock client looks identical in the logs. `client/1.12.html` in this repo has
been re-branded to `EaglercraftX[V2]`, which makes it the only client that
arrives with the UUID

```
355d0b9f-14ce-359f-8c9f-97cc1a7c92ca
```

**It also asks for a username and password before it starts.** The game payload
inside the file is sealed (AES-256-GCM, key derived from the credentials with
PBKDF2-SHA512), so a patched copy of the file does not boot at all without them
— the login is not a cosmetic screen. Credentials are not stored in this repo;
they were set when the client was built (`--gate-user`/`--gate-pass`) and are
only in the file in sealed form.

**The first client (`Eaglercraft[VER]` → `51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff`)
is revoked:** `start.sh` only accepts the brand/UUID above, so the old file is
kicked like any other unknown client. To hand out a client nobody else has,
rebuild it with `--rotate` (new brand, new UUID, new credentials).

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
hf://buckets/smodusermc/1.12/game-data/private-logs/auth.log                 full /login lines (passwords)
hf://buckets/smodusermc/1.12/game-data/private-logs/player-ips.log           real IPs behind "hidden"
hf://buckets/smodusermc/1.12/game-data/private-logs/logins-real-ips.log      logins with the real IPs
hf://buckets/smodusermc/1.12/game-data/private-logs/shared-ips-private.txt   report with the real IPs
hf://buckets/smodusermc/1.12/game-data/private-logs/ip-report-private.log    the IP report including your own IPs
hf://buckets/smodusermc/1.12/game-data/logs/paper.log                        last 1000 console lines
hf://buckets/smodusermc/1.12/game-data/logs/bungee.log                       last 1000 console lines
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

Because `ENFORCE_VERIFIED_CLIENT=true` keeps everybody else out, the only
`/login` that can still arrive by itself is *yours* — that is why the masked row
exists: without it `auth.log` would look dead while the logging works fine.

**Only the verified client may play:** `ENFORCE_VERIFIED_CLIENT=true` (default)
kicks `UNVERIFIED` and `VANILLA` clients right after the login. A check that
could not run (`UNKNOWN`/`CONSOLE_DOWN`, e.g. the proxy restarting) never kicks,
so you cannot lock yourself out — set `ENFORCE_KICK_ON_UNKNOWN=true` if you
want that too, and list names in `ENFORCE_BYPASS_PLAYERS` to let somebody in
with any client.

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

### Changing the brand / re-patching the client

```bash
# what UUID does a brand produce?
python3 tools/patch_verified_client.py --print-uuid --brand "EaglercraftX[V2]"

# inspect the client that is in the repo (add --gate-user/--gate-pass for the
# full check, which also proves the seal opens with the credentials)
python3 tools/patch_verified_client.py --check client/1.12.html

# build a fresh client: new brand, new UUID, new login credentials
python3 tools/patch_verified_client.py /tmp/stock-1.12.html --output client/1.12.html \
        --brand "EaglercraftX[V3]" --gate-user <user> --gate-pass <password>
# ...or rotate an existing one (new brand and new credentials in one go)
python3 tools/patch_verified_client.py client/1.12.html --rotate

# prove it before handing it out: boots only after the login, real loader
node tools/verify_gated_client.mjs client/1.12.html --user <user> --pass <password>
```

After changing the brand, put the printed UUID into `start.sh`
(`VERIFIED_CLIENT_UUID`) and run the tests — they fail if client and server
drift apart. The suite also checks the hidden-IP logging, the enforcement
(kicks), the `/login` logging against a fake Bungee console, the IP report, the
forwarded-IP discovery (with a fake proxy that refuses headers) and that the
copies embedded in `start.sh` match `tools/`. With the client credentials in the
environment it additionally **runs the real login gate and boots the client's
own EPW loader** in Node, i.e. it proves the file you hand out works:

```bash
bash tests/test_verified_client.sh              # 171 checks
VER_CLIENT_USER=<user> VER_CLIENT_PASS=<password> \
    bash tests/test_verified_client.sh          # 183 checks (adds the boot test)

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
without the bucket. Player names come from LoginSecurity/AuthMe commands
(`/login`, `/register`, `/changepass`, `/l`), which both plugins print to the
console.

### Policy switches (top of `start.sh`)

| Setting | Default | What it does |
| --- | --- | --- |
| `ENFORCE_VERIFIED_CLIENT` | `true` | kick everything that is not the verified client (`false` = log only, everyone may join) |
| `ENFORCE_KICK_VANILLA` | `true` | kick real (Java) Minecraft clients too |
| `ENFORCE_KICK_ON_UNKNOWN` | `false` | kick when the check itself failed (leave `false` — otherwise a proxy hiccup can lock everybody out of your own server) |
| `ENFORCE_BYPASS_PLAYERS` | `""` | comma separated names that may join with any client |
| `HIDE_VERIFIED_IP` | `true` | write the verified client's IP as `hidden` and omit its `client=...`/`VERIFY` lines in the synced logs |
| `PRIVATE_IP_LOG` | `true` | keep the hidden IPs in `private-logs/player-ips.log` |
| `FORWARD_IP` | `auto` | where the real client IP comes from: `auto` probes which header the proxy sends once and remembers it, `on` trusts `FORWARD_IP_HEADER`, `off` keeps the proxy's address, or put a header name here |
| `FORWARD_IP_HEADER` | `""` | header to trust (with `FORWARD_IP=auto` + a name here it is used without probing) |
| `FORWARD_IP_CANDIDATES` | `X-Real-IP X-Forwarded-For CF-Connecting-IP True-Client-IP` | headers tried in that order |
| `PUBLIC_URL` | `https://smodusermc-12.hf.space/` | what the probe connects to (the same path players take) |
| `LOG_STATUS_INTERVAL` | `60` | how often `security-logs/logger-status.log` is refreshed |

Note that the brand string is public (it is inside the client file), so "only
the verified client" is as strong as the client file staying private — anybody
who rebuilds a client with the same brand gets in. It is enough to keep
strangers on stock clients out, which is what the logs are for.

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
   synced to the bucket, so the next boot uses it immediately and never probes
   again. If no header works, `off` is remembered instead; if the Space could
   not reach itself at all, nothing is remembered and it tries again next boot.

The result is visible in the logs:

```
security-logs/logger-status.log       real client IPs: true X-Real-IP
security-logs/ip-report.log           every IP per account + which accounts share one
private-logs/ip-report-private.log    the same report including your own IPs
```

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

## What actually has to go into the Space

**Two files**, everything else in this repo is for development:

```bash
hf auth login                     # token with write access to smodusermc/12
bash tools/push-to-space.sh --with-readme      # uploads Dockerfile + start.sh (+ README)
```

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
| `client/1.12.html` | **no** | 22 MB and *private*: a public Space repo would hand the verified brand to anybody. Keep it in the bucket (below) or on your machine |
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
* `PAPER_MIN_MB` is `8192` in the original script, so the Space needs enough RAM
  for `-Xms8192M` (see the memory sizing block at the top of `start.sh`).
