# The verified client — how it works

This document explains what was changed on both sides so that the server can
tell "my client" apart from any other client/account, and why the changes are
safe.

---

## 1. How Eaglercraft clients identify themselves

During the login handshake an EaglercraftX client sends a 16-byte **client brand
UUID** as protocol profile data (`brand_uuid_v1`). The client computes it from
its own brand name with the same helper the server uses:

```java
// EagUtils / EaglerXBungeeAPIHelper
public static UUID makeClientBrandUUID(String name) {
    return UUID.nameUUIDFromBytes(("EaglercraftXClient:" + name).getBytes(StandardCharsets.UTF_8));
}
```

`UUID.nameUUIDFromBytes` is the classical name-based MD5 UUID (RFC 4122 v3).
The stock Eaglercraft 1.12 client (`EaglercraftVersion.projectForkName`,
publicly visible in the 1.12 sources) uses

```java
public static final String projectForkName = "Eaglercraft 1.12";
```

which produces exactly the UUID that the official EaglerX server registers as
`BRAND_EAGLERCRAFT_1_12`:

```
EaglercraftXClient:Eaglercraft 1.12  ->  522b2ce5-c9b9-36cf-be7c-5d90f55e631a
```

The same check for the other official brands proves the algorithm:

| brand name | computed UUID | known constant |
| --- | --- | --- |
| `EaglercraftX` | `4448369e-4e87-3621-94f5-e28eeb160524` | `BRAND_EAGLERCRAFTX_V4` |
| `EaglercraftX` (legacy prefix) | `71d0c812-01c2-366a-a0d2-3d9aa10846eb` | `BRAND_EAGLERCRAFTX_LEGACY` |
| `Eaglercraft 1.12` | `522b2ce5-c9b9-36cf-be7c-5d90f55e631a` | `BRAND_EAGLERCRAFT_1_12` |

So: **change the brand string → change the UUID the client sends.**

The brand is never written down in readable text anywhere: the client carries
only a **PBKDF2-SHA512 verifier** of it (`window.__verGate.brandKdf`) and
`start.sh` keeps the pair XOR'd + base64 (`VERIFIED_CLIENT_PAIR_B64`, decoded at
boot). Both are committed; neither shows the brand.

| brand | UUID | state |
| --- | --- | --- |
| *(not readable anywhere)* | *(likewise)* | **current** — the client has a verifier, `start.sh` has the obfuscated pair, the git-ignored `.verified-client.env` and the optional Space secrets hold it in clear |
| `Eaglercraft[VER]` | `51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff` | **burned** — committed to the repo, refused by `PUBLISHED_CLIENT_BRANDS` |
| `EaglercraftX[V2]` | `355d0b9f-14ce-359f-8c9f-97cc1a7c92ca` | **burned** — same |
| `Eaglercraft 1.12` (stock) | `522b2ce5-c9b9-36cf-be7c-5d90f55e631a` | never the verified client |

A burned brand is refused even if somebody puts it into the Space secrets: the
boot log prints `PUBLIC BRAND` and nobody gets the verified mark. The patcher
refuses to build with such a name at all (`REVOKED_BRANDS`).

Revoking V1 was a one-line change: `VERIFIED_CLIENT_BRAND`/`VERIFIED_CLIENT_UUID`
in `start.sh` point at the new pair, and the comparison
(`query_client_brand()` → `uuid == $VERIFIED_CLIENT_UUID || brand == $VERIFIED_CLIENT_BRAND`)
simply stops matching. Nothing in the old file can restore it — the server does
not care what the file contains, only what brand UUID arrives during the
handshake.

### The login gate (V2 and later)

V2 does not boot until a username and a password are entered. The part that
makes that real — rather than a screen somebody can skip — is *where the game
payload lives*: the EPW is **sealed with AES-256-GCM** and stored as
`window.__verSealed = "<base64>"` in the page. The key is derived in the browser
from the credentials with PBKDF2-SHA512 (1,200,000 iterations, random salt +
random IV, both stored next to the ciphertext):

```
key        = PBKDF2-SHA512(password = user + "\u0000" + pass, salt, 1200000, 32)
plaintext  = AES-256-GCM-open(key, iv, sealed)      ->  the EPW container
```

The gate runs *before* the client's bootstrap: it replaces `window.main` (the
only thing that starts the game) with itself, so

* `main()` before the login does nothing at all — there is no plaintext EPW in
  the page to boot from, and the file's own `assetsURI` is gone;
* wrong username **and** wrong password are both rejected, and the failure
  counter locks the form for 30 s after five attempts;
* on success the EPW is decrypted, checked for the `EAG$` magic, turned into a
  `data:` URI with `FileReader`, `main()` is called and the gate removes itself
  and the splash screen.

What this does and does not give you:

* somebody who has the file **cannot play without the credentials** — they
  would have to break PBKDF2-SHA512 (1.2 M iterations) or brute-force the
  password; patching the gate script out does not help, because the payload in
  their copy is still sealed;
* the credentials are never written into the file: rebuilding with
  `--gate-user/--gate-pass` derives a fresh salt, and `--check`/the verifier
  assert that neither string appears in the file;
* it is still client-side: a copy of the *decrypted* EPW can be shared, and the
  server cannot see the gate at all (it only sees the brand UUID, which is why
  revocation stays possible). Change the credentials by rebuilding/rotating;
* the gate is also what keeps the brand secret: it only exists inside the sealed
  payload, so the client file can be committed and handed out without revealing
  which brand the server looks for. Reading it back needs the login, or an
  `--expect-brand` check against the verifier the file carries.

---

## 2. Where the brand lives inside the client file

`client/1.12.html` is a WASM-GC build of Eaglercraft 1.12. Its structure:

```
1.12.html
 ├─ <script> window.eaglercraftXOpts = {...}          (launch options)
 ├─ <script> loader bootstrap ("LoaderBootstrap:")     (reads the package below)
 ├─ <script> window.eaglercraftXOpts.assetsURI =
 │            "data:application/octet-stream;base64,<EPW file>"
 └─ <script> small game-loop throttle patches
```

The EPW file (`EAG$WASM`, ~16.8 MB) is a small container format. Its header
(384 bytes, from the public loader source `src/wasm-gc-teavm-loader/c/epw_header.h`)
contains:

```c
uint8_t  magic[8];            // "EAG$WASM"
uint32_t fileLength;          // @8  must equal the size of the file
uint32_t fileCRC32;           // @12 CRC32 over bytes [16, fileLength)
uint16_t versionMajor/minor;  // @16 / @18
...
struct epw_slice  loaderJSData   @164   // raw (uncompressed) loader.js
struct epw_slice  loaderWASMData @180   // raw loader.wasm
struct epw_slice_compressed JSPIUnavailableData @196
struct epw_slice_compressed eagruntimeJSData    @212
struct epw_slice_compressed classesWASMData     @228   <-- the game, XZ compressed
struct epw_slice_compressed classesDeobfTEADBGData @244
struct epw_slice_compressed classesDeobfWASMData   @260
struct epw_assets_epk_file   assetsEPKs[]       @276   // assets.epk + lang
```

Each compressed slice is `{offset, compressedLength, decompressedLength, reserved}`
and the payload is an `.xz` stream. Inside `classes.wasm` (7.7 MB, TeaVM
string pool) the brand is stored as a length-prefixed UTF-8 pool entry:

```
... 0x10 "Eaglercraft 1.12" 0x16 "EaglercraftXClientOld:" ...
      ^^ 16 byte string     ^^ next entry
```

That is exactly the constant the tool rewrites — **16 bytes in, 16 bytes out**,
so nothing inside the wasm moves.

---

## 3. What `tools/patch_verified_client.py` does

1. finds `window.eaglercraftXOpts.assetsURI`, base64-decodes the EPW;
2. parses the EPW header, takes `classesWASMData`, XZ-decompresses it;
3. locates the brand constant (`\x10<brand>\x16EaglercraftXClientOld:`) and
   rewrites the 16 brand bytes (verifies the wasm section walk still holds);
4. XZ-recompresses the wasm and rebuilds the container, because the compressed
   size changed:
   * every slice that points **after** the patched component is shifted,
   * `classesWASMData.compressedLength/decompressedLength` are updated,
   * `fileLength` and `fileCRC32` (CRC32 over `[16, len)`) are recomputed;
5. re-validates the result exactly like the loader would (magic, length, CRC32,
   every slice in bounds, every XZ component decompresses to its declared
   length, every component byte-identical except the 5 changed bytes of the
   brand — the rest of the client, including both `assets.epk` packages, is
   untouched);
6. splices the new base64 back into the HTML.

Everything outside the base64 blob is copied byte-for-byte.

### The loader's rules (learned the hard way)

The EPW is unpacked by a small wasm loader (`loader.wasm`, built from
`wasm-gc-teavm-loader/c/main.c`) that is **much stricter than a normal XZ
decoder**:

| Rule | Consequence if broken |
| --- | --- |
| `fileCRC32` = CRC32 of the bytes from offset 16 to the end | "EPW file has an invalid checksum" |
| `fileLength` = the real file size | "EPW file is incomplete" |
| every slice within `[headerLen, fileLength]` | "EPW file contains an invalid offset" |
| every XZ component decodes with an **LZMA2 dictionary ≤ 32 MiB** (`xz_dec_init(XZ_DYNALLOC, 33554432)`) | `XZ_OPTIONS_ERROR` = "Decompression failed, code 6!" → **"EPW file is invalid"** |
| the XZ stream ends exactly at the end of the slice (no padding/trailing bytes) | "still some input data remaining" → "EPW file is invalid" |
| decompressed size equals the declared size | "Decompression failed" / buffer overflow |

`xz --preset 9` (and Python's `lzma` default) use a **64 MiB** dictionary, so a
naively recompressed component produces a client that shows
*"EPW file is invalid / Try again later"* in the browser even though every
Python-side check passes. `tools/patch_verified_client.py` therefore caps the
dictionary at 32 MiB, keeps the stock stream's integrity check (`none`), and
validates the result with `decompress_component()` — a re-implementation of the
loader's exact decode loop.

**Limitations.** The brand string is inside a public file, so a determined
person can rebuild their own client with the same brand — the seal stops them
from *using this file* without the credentials, not from building their own.
The brand is therefore the secret that matters: keep the client file, the
brand/UUID and this repository private, and put the pair into the Space as
secrets (`VERIFIED_CLIENT_BRAND` / `VERIFIED_CLIENT_UUID`, which `start.sh`
prefers over the literals in the file). "Keeping the brand secret" in
`README.md` has the four steps.
Treat the pair (brand UUID + sealed payload) as an identification aid plus a
speed bump: keep the file itself private, rotate (`--rotate`) when it leaks, and
watch `security-logs/activity.log` for `CHECK` rows that are not you.

---

## 4. What `start.sh` does

1. `start_bungee()` opens a FIFO (`/opt/server/bungee/console.pipe`) read+write
   and gives it to BungeeCord as stdin. That keeps the console alive **and** lets
   the script inject console commands from anywhere.
2. Paper, BungeeCord and an RCON `list` safety poll can report joins. The first
   source writes one `LOGIN` row and marks the name online; duplicate reports
   are ignored. The poll defaults to every 60 seconds.
3. `check_player_client` runs `client-brand name <player>` on the proxy console,
   reads the answer out of `/tmp/bungee.log`, strips legacy/ANSI color codes and
   retries once if the handshake has not completed.
4. The result is compared with the configured brand/UUID. `LOGIN`, `LOGOUT`,
   `CHECK` and `COMMAND` events all go to the same append-only
   `security-logs/activity.log`. Each event has an Eastern 12-hour timestamp;
   the logger inserts a spaced divider when the local date changes. The verdict
   marker `VERIFIED CLIENT` is retained, but the owner's IP is hidden and their
   brand/UUID are redacted from synced output. Other clients receive their
   resolved labels and, when available, their IP.
5. **Enforcement** is off by default: all clients may join. Setting
   `ENFORCE_VERIFIED_CLIENT=true` enables the kick policy. A check that did not
   resolve does not kick unless `ENFORCE_KICK_ON_UNKNOWN=true`; bypass names are
   configured with `ENFORCE_BYPASS_PLAYERS`.
6. **Passwords**: auth command arguments are masked in the activity log and the
   console snapshot. Other players' full auth commands are retained in private
   `private-logs/auth.log`; the verified client's own password is never saved.
   With no verified pair configured, all auth rows are masked as
   `client=UNCONFIGURED`.
7. **Why `/login` needs a jar patch**: LoginSecurity 3.3.1 and AuthMe can filter
   the console line before the parser sees it. `start.sh` neutralises only the
   relevant deny-string constants before Paper starts (`tools/patch_auth_filter.py`),
   verifies with `javap` when available, keeps a backup, and restores/restarts
   if the patched plugin fails to load. `AUTH_FILTER_PATCH=false` disables it.
8. **IPs**: behind the ingress, the game sees a proxy address unless a
   forwarded header works. The script probes candidates after startup and only
   enables one if the upgrade succeeds and the plugin does not refuse it. The
   result is remembered in private `private-logs/forward-ip.state`; see the IP
   section in `README.md`.
9. **Reports/status**: public `security-logs/addresses.txt` omits the verified
   client's address; private `private-logs/addresses.txt` includes it. The
   full dated sightings are in `private-logs/addresses.log`. The compact
   `security-logs/status.txt` reports logger health, the last player-list
   answer, auth capture, and forwarding/proxy evidence.

## 5. Getting the logs out of the Space

The bucket is the only log location reachable from outside the Space. Log sync
and full world sync share a lock, so they do not overlap:

* `log_sync_loop` runs every 60 seconds by default and syncs only the
  `security-logs/`, `private-logs/`, and `logs/` prefixes. Each prefix uses
  `--delete` so obsolete duplicate files are removed.
* `hf_sync_loop` mirrors the full game-data tree every 600 seconds by default.
* Both syncs and their staging copies run at low CPU/I/O priority where the
  container permits (`nice -n 19`, `ionice -c3`). A low priority can make an
  upload take longer; it is intended to let Paper's tick work win CPU/disk
  scheduling. No live CPU/TPS/gameplay measurement is available in this repo.

The curated remote files are:

```
hf://buckets/smodusermc/1.12/game-data/security-logs/activity.log
hf://buckets/smodusermc/1.12/game-data/security-logs/addresses.txt
hf://buckets/smodusermc/1.12/game-data/security-logs/status.txt
hf://buckets/smodusermc/1.12/game-data/private-logs/{auth.log,addresses.log,addresses.txt}
hf://buckets/smodusermc/1.12/game-data/private-logs/{verified-players.txt,proxy-peers.log,forward-ip.state}
hf://buckets/smodusermc/1.12/game-data/logs/console.log
```

`bash tools/fetch-logs.sh [outdir] [bucket/game-data]` downloads the current
folders in one go. Read `activity.log` to filter `LOGIN`, `CHECK`, or `COMMAND`
rows. `activity.log`, `auth.log`, and `addresses.log` are append-only logs using
`America/New_York` (EST/EDT), a 12-hour clock, and daily dividers. Address
reports, status, and the combined console file are snapshots with an Eastern
12-hour update/capture timestamp.

`SYNC_PRIVATE_LOGS=true` is the default because the private files are needed to
read the verified client's real address and other players' full auth commands.
Setting `SYNC_PRIVATE_LOGS=false` syncs an empty private prefix with `--delete`,
removing old private copies from the bucket. `SYNC_CONSOLE_LOGS=false` does the
same for the console snapshot prefix. Keep the bucket private. Reports
regenerate every 300 seconds and the status snapshot every 60 seconds by
default.

On startup `tools/log_migrate.py` converts legacy UTC timestamps to Eastern,
redacts verified-client identity data, masks the verified owner's legacy auth
password when historical evidence identifies them, merges duplicate events/IP
history, and removes the old many-file copies. The migration is marker-based and
idempotent; `tests/test_verified_client.sh` exercises it with a fixture.

The checked-in client includes earlier End Portal pass-count and asset/animation
transformations. They are client-side, not Paper tick optimisations. Automated
fixtures prove that the targeted WASM/package edits remain well-formed; they do
not prove a visible FPS gain. A previous visual check showed no noticeable
improvement, and there is no in-game A/B or low-end-phone benchmark available.

The reported stutter is near an End gateway or the End return-to-overworld
portal, not usually the overworld stronghold portal. Do not assume the cause:
the End Portal pass edit does not diagnose the separate gateway render path,
server chunk/tick load, entities, or network delay. See the controlled
client-FPS versus Paper-timings comparison in `README.md` before making further
gameplay or client-render changes.

## 6. Keeping client and server in sync

`tests/test_verified_client.sh` exercises the client/server identity flow and
related helpers. It checks the built-in pair and history, verified/unverified/
vanilla/unknown detection, default allow-all enforcement, auth command masking,
LoginSecurity/AuthMe patch fixtures, forwarded-IP behavior, proxy-peer/IP reports,
and the low-end client package's structural edits. It also checks:

* Eastern 12-hour timestamps, one divider per date, and consistent spacing;
* consolidated event/report paths, legacy UTC migration, secret redaction,
  legacy verified-auth masking, and migration idempotence;
* per-prefix bucket sync (including disabled-prefix cleanup), combined console
  redaction, private-log staging, sync intervals, and low-priority wrappers;
* embedded helper parity with `tools/`, plus optional JVM/client-loader checks
  when the required runtime and gate credentials are available.

The suite uses local fixtures and fake bucket APIs. It does **not** test a live
HF bucket/Space, build the Docker image, measure server CPU/TPS, or establish
that gameplay has no lag. Those require deployment/player-side measurements.

```bash
bash tests/test_verified_client.sh
PRINT_LOGS=1 bash tests/test_verified_client.sh

# optional: boot the sealed client through its real login gate and loader
VER_CLIENT_USER=<user> VER_CLIENT_PASS=<password> \
    bash tests/test_verified_client.sh
node tools/verify_gated_client.mjs client/1.12.html --user <user> --pass <password>
```

## 7. Changing the marker

```bash
# rotate: new random brand, new UUID and new login credentials in one go
python3 tools/patch_verified_client.py client/1.12.html --rotate

# or pick the brand yourself (must be exactly 16 ASCII characters)
python3 tools/patch_verified_client.py client/1.12.html --brand "Something16Chars"
```

Both print the new brand UUID. Either way, put the pair into `start.sh` —
`--rotate` prints the two lines to paste — and add the *old* brand to the
`REVOKED_BRANDS` list in `tools/patch_verified_client.py`, which is what keeps a
future build from reusing a burned name:

```
VERIFIED_CLIENT_BRAND="Something16Chars"
VERIFIED_CLIENT_UUID="<printed uuid>"
```

Then hand out the new file (or put it in the bucket) and run:

```bash
VER_CLIENT_USER=<user> VER_CLIENT_PASS=<password> bash tests/test_verified_client.sh
```

The old client stops being accepted the moment the Space runs the new value —
it is not "blocked", it simply stops matching, which is the one thing a copy of
the old file cannot undo.

Note that the brand also shows up in the client's main menu and in the F3 debug
screen (`Minecraft 1.12.2 (<brand> u2)`), which is a handy way for players to
see that they are on the right client.
