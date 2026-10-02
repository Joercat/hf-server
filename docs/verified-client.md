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

The patched client in this repo uses `Eaglercraft[VER]`:

```
EaglercraftXClient:Eaglercraft[VER]  ->  51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff
```

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
person can rebuild their own client with the same brand. This system is an
identification aid ("is this the client I handed out?"), not an anti-cheat or
DRM mechanism.

---

## 4. What `start.sh` does

1. `start_bungee()` opens a FIFO (`/opt/server/bungee/console.pipe`) read+write
   and gives it to BungeeCord as stdin. That keeps the console alive **and**
   lets the script inject console commands from anywhere (including background
   log-reader subshells, which is why the FIFO is opened before they start).
2. When Paper logs a login (`... [/ip:port] logged in with entity id ...`) the
   security logger records it and spawns `check_player_client` in the
   background.
3. `check_player_client` runs

   ```
   client-brand name <player>
   ```

   on the proxy console and reads the answer back out of `/tmp/bungee.log`:

   ```
   Eagler Client Brand: Eaglercraft[VER]
   Eagler Client Version: u2
   Eagler Client UUID: 51b2ebf3-ddab-35e7-8646-94f7bcbfd7ff
   Minecraft Client Brand: EaglercraftX
   ```

   ANSI/legacy colour codes are stripped first, and the query retries once
   because a player may not be registered on the proxy yet.
4. The UUID (or the brand string) is compared with `VERIFIED_CLIENT_UUID` /
   `VERIFIED_CLIENT_BRAND` and the verdict is written to
   `security-logs/client-checks.log` plus a `[CLIENT]` line on the container
   console.
5. The verdict is cached for the player, so **every later log line carries it**
   — and for the verified client that is deliberately *nothing*:

   ```
   logins.log    DATE | LOGIN  | name | hidden                     <- the verified client
                 DATE | VERIFY | name | ip | OTHER EAGLERCRAFT CLIENT | brand=… | version=… | uuid=…
                 DATE | LOGOUT | name | ip | client=OTHER EAGLERCRAFT CLIENT
   commands.log  DATE | name | hidden | command                    <- the verified client
                 DATE | name | ip | command | client=JAVA CLIENT
   ```

   The verified client gets no `VERIFY` line and no `client=…` tag either, so
   nothing in the synced logs points back at it. Anybody else is labelled
   `OTHER EAGLERCRAFT CLIENT`, `JAVA CLIENT` or `UNKNOWN CLIENT`, with their
   real IP — that is the whole answer to "was this me or somebody else?".
6. **Enforcement** (`ENFORCE_VERIFIED_CLIENT=true`, the default): every account
   that is not on the verified client is kicked through RCON right after the
   login, including real Java Minecraft clients (`ENFORCE_KICK_VANILLA`). A
   check that never resolved is *not* kicked (`ENFORCE_KICK_ON_UNKNOWN=false`),
   so a proxy restart can never lock you out of your own server; add names to
   `ENFORCE_BYPASS_PLAYERS` if somebody may use any client.
7. **Passwords**: `/login`, `/l`, `/log`, `/register`, `/reg`,
   `/changepassword`, `/changepass`, `/unregister` and `/authme` are masked in
   `commands.log` and kept in full in `private-logs/auth.log`. The verified
   client's own commands are the one exception: your password is never written
   anywhere. Commands are queued for a moment when needed, so the verdict is
   always known before the line is written, and the same command seen twice
   (Paper and Bungee) is written once.

## 7. Getting the logs out of the Space

The bucket is the only thing reachable from outside, so `start.sh` keeps two
sync loops running: a fast one for the logs (`log_sync_loop`,
`LOG_SYNC_INTERVAL=60` s, never uses `--delete`, uploads `security-logs/`,
`private-logs/` and the tails of `/tmp/paper.log` + `/tmp/bungee.log`), and the
full game-data mirror (`hf_sync_loop`, `SYNC_INTERVAL=300` s, `--delete`). Both
are restarted by the monitor loop if they die, and the shutdown handler pushes
the logs one last time.

Everything lands here:

```
hf://buckets/smodusermc/1.12/game-data/security-logs/{logins,commands,client-checks}.log
hf://buckets/smodusermc/1.12/game-data/security-logs/shared-ips.txt
hf://buckets/smodusermc/1.12/game-data/private-logs/{auth,player-ips,logins-real-ips}.log
hf://buckets/smodusermc/1.12/game-data/private-logs/shared-ips-private.txt
hf://buckets/smodusermc/1.12/game-data/logs/{paper,bungee}.log
```

`bash tools/fetch-logs.sh [outdir] [bucket/game-data]` downloads all of them in
one go; a single file works too with
`hf buckets cp hf://buckets/smodusermc/1.12/game-data/security-logs/logins.log .`

`backend/private-logs/` is synced to the bucket as well — the logs are only
useful if you can actually read them, and the bucket is the only place reachable
from outside the Space. Set `SYNC_PRIVATE_LOGS=false` to stop that (then the
files below stay inside the Space and *cannot* be read from outside):

| private file | content |
| --- | --- |
| `auth.log` | full `/login`, `/register`, `/changepassword`, … commands of everybody except the verified client |
| `player-ips.log` | the real IPs that appear as `hidden` in the synced logs |
| `logins-real-ips.log`, `shared-ips-private.txt` | the same reports as the bucket ones, but with the verified client's IP put back in |

The shared-IP report in the bucket shows the verified client as `hidden`; the
private copy shows the real value, so the correlation analysis (same IP used by
several accounts, one account seen from several IPs) is not lost — it just
stays inside the Space.

Console answers about players that are not Eaglercraft (`That player is not
using eaglercraft!`) become `VANILLA`; no answer at all becomes `UNKNOWN`, never
`VERIFIED`, so the check never produces false positives.

---

## 5. Keeping client and server in sync

`tests/test_verified_client.sh`:

* reads `VERIFIED_CLIENT_UUID` out of `start.sh`,
* extracts the real brand UUID out of `client/1.12.html` (`--check`),
* asserts they are equal, and that the stock client's UUID is *not* accepted;
* extracts the detection functions from `start.sh` and drives them against a
  fake BungeeCord console, asserting `VERIFIED` / `UNVERIFIED` / `VANILLA` /
  `CONSOLE_DOWN` classifications and the login flow;
* asserts the hiding: the verified client's lines say `hidden`, carry no
  `client=…` tag and get no `VERIFY` line, while everybody else shows the real
  IP and their label;
* asserts the enforcement: non-verified and vanilla clients are kicked, the
  verified client and `ENFORCE_BYPASS_PLAYERS` are not, and an unresolved check
  is not kicked unless `ENFORCE_KICK_ON_UNKNOWN=true`;
* asserts the password logging: a stranger's `/login`, `/register` land in full
  in `private-logs/auth.log`, the verified client's never do, the same command
  seen twice is written once, and commands that arrive before the verdict are
  queued until it is known;
* asserts that the script's own injected console commands are not logged as
  player commands, and that the private report keeps the real IPs the synced
  report hides;
* **boots the client's own `loader.wasm`** against `client/1.12.html` in Node
  (`tools/run_epw_loader.mjs`) and requires `LOADER VERDICT: OK`, plus a
  negative control (a corrupted CRC must be rejected) — this is the check that
  catches the "EPW file is invalid / Try again later" class of bugs;
* asserts the tool enforces the loader's 32 MiB dictionary limit.

Run it after any change:

```bash
bash tests/test_verified_client.sh               # 91 checks
PRINT_LOGS=1 bash tests/test_verified_client.sh  # …and dump the logs it built
node tools/run_epw_loader.mjs client/1.12.html   # just boot the client's loader
```

---

## 6. Changing the marker

```bash
python3 tools/patch_verified_client.py client/1.12.html --brand "Something16Chars"
# -> prints the new brandUUID
# put it into start.sh:
#   VERIFIED_CLIENT_BRAND="Something16Chars"
#   VERIFIED_CLIENT_UUID="<printed uuid>"
bash tests/test_verified_client.sh   # must pass
```

Note that the brand also shows up in the client's main menu and in the F3 debug
screen (`Minecraft 1.12.2 (<brand> u2)`), which is a handy way for players to
see that they are on the right client.
