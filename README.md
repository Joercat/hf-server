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
  account except the verified client's

## Layout

| Path | What it is |
| --- | --- |
| `Dockerfile` | image build (Java 17, BungeeCord, Paper, plugins, verified client) |
| `start.sh` | boots + supervises everything, writes configs and security logs |
| `config/bungee/EaglerXBungee.jar` | proxy plugin that lets EaglercraftX clients join |
| `plugins/` | backend plugins copied into Paper (AuthMe jars live here) |
| `client/1.12.html` | **the verified client** (patched, see below) |
| `tools/patch_verified_client.py` | patches / inspects the client brand |
| `tools/fetch-logs.sh` | downloads all the server logs from the bucket |
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
been re-branded to `Eaglercraft[VER]`, which makes it the only client that
arrives with the UUID

```
51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff
```

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
hf://buckets/smodusermc/1.12/game-data/private-logs/auth.log                 full /login lines (passwords)
hf://buckets/smodusermc/1.12/game-data/private-logs/player-ips.log           real IPs behind "hidden"
hf://buckets/smodusermc/1.12/game-data/private-logs/logins-real-ips.log      logins with the real IPs
hf://buckets/smodusermc/1.12/game-data/private-logs/shared-ips-private.txt   report with the real IPs
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

private-logs/auth.log             DATE | name | ip | /login hunter2 | client=...   <- full passwords
private-logs/player-ips.log       the real IPs that show as "hidden" above
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
verified client, whose password is never written anywhere. Use it to recover a
password a player set for you.

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
2026-10-02 21:15:52 | RandomDude | 5.6.7.8 | /login hisnewpass | client=OTHER EAGLERCRAFT CLIENT

$ cat /opt/server/backend/private-logs/player-ips.log  # the IPs behind "hidden"
2026-10-02 21:14:01 | CreppyBitch | 203.0.113.7
```

### Changing the brand / re-patching the client

```bash
# what UUID does a brand produce?
python3 tools/patch_verified_client.py --print-uuid --brand "Eaglercraft[VER]"

# inspect the client that is in the repo
python3 tools/patch_verified_client.py --check client/1.12.html

# re-brand a client (brand must be exactly 16 ASCII characters)
python3 tools/patch_verified_client.py client/1.12.html --brand "MyOwnBrand16Chr"
```

After changing the brand, put the printed UUID into `start.sh`
(`VERIFIED_CLIENT_UUID`) and run the tests — they fail if client and server
drift apart. The suite also checks the hidden-IP logging, the enforcement
(kicks) and the `/login` logging against a fake Bungee console:

```bash
bash tests/test_verified_client.sh              # 54 checks

# same, but print the logs it produced, so you can see the formats:
PRINT_LOGS=1 bash tests/test_verified_client.sh
```

### Policy switches (top of `start.sh`)

| Setting | Default | What it does |
| --- | --- | --- |
| `ENFORCE_VERIFIED_CLIENT` | `true` | kick everything that is not the verified client (`false` = log only, everyone may join) |
| `ENFORCE_KICK_VANILLA` | `true` | kick real (Java) Minecraft clients too |
| `ENFORCE_KICK_ON_UNKNOWN` | `false` | kick when the check itself failed (leave `false` — otherwise a proxy hiccup can lock everybody out of your own server) |
| `ENFORCE_BYPASS_PLAYERS` | `""` | comma separated names that may join with any client |
| `HIDE_VERIFIED_IP` | `true` | write the verified client's IP as `hidden` and omit its `client=...`/`VERIFY` lines in the synced logs |
| `PRIVATE_IP_LOG` | `true` | keep the hidden IPs in `private-logs/player-ips.log` |

Note that the brand string is public (it is inside the client file), so "only
the verified client" is as strong as the client file staying private — anybody
who rebuilds a client with the same brand gets in. It is enough to keep
strangers on stock clients out, which is what the logs are for.

## Deploying / running

The current tree has to be copied onto the Space (this checkout does not
contain the binary jars that live there, so do **not** force-push over it):

```bash
hf auth login                                  # token with write access to smodusermc/12
git clone https://huggingface.co/spaces/smodusermc/12 space
cd space
git fetch https://github.com/Joercat/hf-server.git arena/01a0fc66-hf-server
git checkout FETCH_HEAD -- .                   # overwrites/updates files, deletes nothing
git add -A && git commit -m "Verified client + tagged security logs"
git push
```

`git checkout FETCH_HEAD -- .` deliberately leaves the jars that only exist on
the Space (`plugins/AuthMe*.jar`, `config/bungee/EaglerXServer.jar`) in place —
they are LFS-tracked there.

Required Space settings: a `HF_TOKEN` secret with write access to the bucket
(`EXPOSE 7860` is already handled). Players join with the client in
`client/1.12.html` on `wss://smodusermc-12.hf.space/`.

## Notes

* The bucket contains clear-text passwords (`private-logs/auth.log`) and your
  real IP (`private-logs/player-ips.log`) with the default settings — keep the
  bucket private; `SYNC_PRIVATE_LOGS=false` stops uploading them.
* `plugins/` needs the AuthMe jars from the original Space (`AuthMe-6.0.1-Bungee.jar`,
  `AuthMeBungee-2.2.0-beta1.jar`); they are binary files and are not in this
  checkout — see `plugins/README.md`.
* `config/bungee/EaglerXServer.jar` (unused by the Dockerfile) is not committed here.
* The login regex in the original `start.sh` was missing the `]` after the
  port, so Paper logins were never written to `logins.log`; this is fixed here.
* `PAPER_MIN_MB` is `8192` in the original script, so the Space needs enough RAM
  for `-Xms8192M` (see the memory sizing block at the top of `start.sh`).
