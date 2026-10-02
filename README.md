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
* an append-only **security log** of logins, commands and client checks

## Layout

| Path | What it is |
| --- | --- |
| `Dockerfile` | image build (Java 17, BungeeCord, Paper, plugins, verified client) |
| `start.sh` | boots + supervises everything, writes configs and security logs |
| `config/bungee/EaglerXBungee.jar` | proxy plugin that lets EaglercraftX clients join |
| `plugins/` | backend plugins copied into Paper (AuthMe jars live here) |
| `client/1.12.html` | **the verified client** (patched, see below) |
| `tools/patch_verified_client.py` | patches / inspects the client brand |
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

`start.sh` asks the proxy for the brand of every player that joins
(`/client-brand`, over a console pipe) and records the result:

```
security-logs/logins.log          DATE | LOGIN/LOGOUT | name | ip
security-logs/client-checks.log    DATE | VERDICT | name | ip | brand=... | version=... | uuid=...
security-logs/commands.log         DATE | name | ip | command        (passwords masked)
security-logs/shared-ips.txt       report: shared IPs + verification summary
```

`VERDICT` is one of:

| Verdict | Meaning |
| --- | --- |
| `VERIFIED` | this repo's client (brand UUID matches `VERIFIED_CLIENT_UUID`) |
| `UNVERIFIED` | some other Eaglercraft client / fork / edited client |
| `VANILLA` | a real (Java) Minecraft client, not Eaglercraft |
| `UNKNOWN` | could not be checked (proxy busy/down) |

So a quick look at the log tells you whether a login was you (or someone you
gave the client to) or somebody else:

```
$ tail -f /opt/server/backend/security-logs/client-checks.log
2026-10-02 21:14:03 | VERIFIED   | CreppyBitch | 1.2.3.4  | brand=Eaglercraft[VER] | version=u2 | uuid=51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff
2026-10-02 21:15:47 | UNVERIFIED | RandomDude  | 5.6.7.8  | brand=Eaglercraft 1.12 | version=u2 | uuid=522b2ce5-c9b9-36cf-be7c-5d90f55e631a
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
drift apart:

```bash
bash tests/test_verified_client.sh
```

### Enforcing it

Set `ENFORCE_VERIFIED_CLIENT=true` in `start.sh` to kick anyone whose client is
`UNVERIFIED` (stock Eaglercraft clients are kicked too, so hand out the client
from `client/1.12.html`).

## Deploying / running

Push the repo to the Space (or `docker build` it yourself). Required Space
settings: a `HF_TOKEN` secret with write access to the bucket, and
`EXPOSE 7860` is already handled. Players join with the client in
`client/1.12.html` on `wss://smodusermc-12.hf.space/`.

## Notes

* `plugins/` needs the AuthMe jars from the original Space (`AuthMe-6.0.1-Bungee.jar`,
  `AuthMeBungee-2.2.0-beta1.jar`); they are binary files and are not in this
  checkout — see `plugins/README.md`.
* `config/bungee/EaglerXServer.jar` (unused by the Dockerfile) is not committed here.
* The login regex in the original `start.sh` was missing the `]` after the
  port, so Paper logins were never written to `logins.log`; this is fixed here.
* `PAPER_MIN_MB` is `8192` in the original script, so the Space needs enough RAM
  for `-Xms8192M` (see the memory sizing block at the top of `start.sh`).
