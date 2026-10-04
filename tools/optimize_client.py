#!/usr/bin/env python3
"""optimize_client.py - make the verified client cheaper to run on weak machines.

The client is a sealed EPW file; inside it sit the game's compiled code
(`classes.wasm`) and two EPK asset packages (`assets.epk` and the `lang` one).
This tool rewrites the three things that actually cost frames on a low-end
machine, and re-seals the client:

1. **The end portal's render passes (the stronghold/End lag).**  Near an active
   portal the stock client draws the portal quad over and over - up to **15
   passes** - each pass with its own texture matrix change and a blended draw,
   and the count comes straight from the squared distance to the block
   (`RenderEndPortal.getPasses`).  In a browser every one of those GL calls
   crosses the wasm -> JS boundary, so a 3x3 portal is a few thousand calls and
   a few hundred draw calls *per frame*: that is the "it lags really bad when
   the portal is in render distance" report, and it has nothing to do with the
   texture file.  The count is compiled into a tiny function in `classes.wasm`
   as single-byte constants, so this tool finds the chain and lowers it (default:
   **at most 7 passes**).  The edit is one byte per pass count, the module still
   compiles, and it can only ever make the client *lighter* - but the portal does
   show fewer layers of its starfield, so `--portal-passes` (0 = stock) is there
   to tune it.

2. **The end portal texture.**  `entity/end_portal.png` ships as a 256x256 RGBA
   texture (256 KiB) that every pass samples; it is a soft noise field, so 32x32
   looks the same in motion, costs 1/64th of the memory and keeps the sampler in
   L1 instead of thrashing caches.  (The End's sky wallpaper uses the same
   texture, so the whole dimension gets the same win.)

3. **Animated texture memory.**  The pack ships BTA-like animation strips: water
   32 frames of 16x16, lava 20, fire 32, the nether portal 32, sea lantern 5,
   prismarine 4, command blocks 4.  Every frame is its own layer of an array
   texture and is re-uploaded on a timer, so 32-frame strips are part of the
   periodic stutter while water/lava fills the screen.  Animation is *time
   based*, so keeping every n-th frame and multiplying the entry's `frametime`
   by n plays at the same speed - water and lava simply stop running at 120 fps
   and animate at 15, which a human eye cannot tell apart from 60 on a 4 GB
   machine that never runs 60 anyway.  Default: at most 8 frames per texture.

Everything else in the package is copied byte for byte, and the tool prints (and
optionally writes to JSON) exactly what it changed.  The client's brand, the
login gate and every credential stay untouched: the payload is re-sealed with
the same salt/IV/iterations, so the file keeps working with the same username and
password.

usage:
  # what would change, without writing anything
  python3 tools/optimize_client.py client/1.12.html --dry-run

  # write client/1.12.html.optimized
  python3 tools/optimize_client.py client/1.12.html --output client/1.12.html.optimized

  # a resource pack (EPK file) instead of a client
  python3 tools/optimize_client.py --pack mypack.epk --output mypack.optimized.epk

  # the credentials and the brand come from .verified-client.env when present
  python3 tools/optimize_client.py client/1.12.html --user U --pass P

  # fewer end portal passes (3 = fastest), 0 = leave the stock ones alone
  python3 tools/optimize_client.py client/1.12.html --portal-passes 3 --user U --pass P
"""

import argparse
import base64
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import epk                                     # noqa: E402
import patch_verified_client as P               # noqa: E402
import pnglite                                  # noqa: E402

END_PORTAL = "assets/minecraft/textures/entity/end_portal.png"
DEFAULT_FRAMES = 8
DEFAULT_END_PORTAL = 32
DEFAULT_PORTAL_PASSES = 7

# RenderEndPortal.getPasses(double) in the stock 1.12.2 client: the squared
# distance to the portal block picks how many times the portal quad is drawn
# (each pass = a texture matrix change + a blended draw of the same quad).
# The list below is the compiled comparison chain, in the order it appears in
# classes.wasm; the compiled pass counts are 1, 3, 5, 7, 9, 11, 13, 15, 14.
PORTAL_THRESHOLDS = (36864.0, 25600.0, 16384.0, 9216.0, 4096.0, 1024.0, 576.0, 256.0)
PORTAL_MAX_STOCK_PASSES = 15


# --------------------------------------------------------------------------- #
# the two asset rules
# --------------------------------------------------------------------------- #
def frame_factor(count, target):
    """The largest power-of-two reduction that still leaves >= target frames."""
    if target < 2 or count < 2 * target:
        return 1
    best = 1
    factor = 2
    while factor <= count:
        if -(-count // factor) >= target:        # ceil(count / factor)
            best = factor
        factor *= 2
    return best


def rotation_of_range(frames, count):
    """Is this frame list just the whole strip played in a rotated order?

    Only such a list can be thinned safely: every kept strip frame keeps the
    same neighbours, so the animation still plays the same sequence, just with
    a longer step between the frames.  A hand-written list (lava's ping-pong,
    the prismarine flicker) is left alone instead of being silently changed.
    """
    if len(frames) != count or count == 0:
        return False
    if sorted(frames) != list(range(count)):
        return False
    return frames == list(range(frames[0], count)) + list(range(frames[0]))


def _anim_frames(anim, count):
    """The effective frame list of an mcmeta animation (indices into the strip)."""
    frames = anim.get("frames")
    if not frames:
        return list(range(count)), False
    out = []
    for entry in frames:
        if isinstance(entry, dict):
            if "index" in entry:
                out.append(int(entry["index"]))
            else:
                return None, False
        elif isinstance(entry, int):
            out.append(entry)
        else:
            return None, False
    return out, True


def _rewrite_anim_meta(anim, factor):
    """The new animation block for a strip reduced by `factor`."""
    meta = dict(anim)
    frametime = anim.get("frametime", 1)
    if not isinstance(frametime, int):
        return None
    meta["frametime"] = frametime * factor
    frames = anim.get("frames")
    if frames:
        new_frames = []
        for entry in frames:
            if isinstance(entry, dict):
                index = int(entry.get("index", 0))
                if index % factor:
                    continue
                item = dict(entry)
                item["index"] = index // factor
                if isinstance(item.get("time"), int):
                    item["time"] = item["time"] * factor
                new_frames.append(item)
            else:
                if int(entry) % factor:
                    continue
                new_frames.append(int(entry) // factor)
        if len(new_frames) < 2:
            return None
        meta["frames"] = new_frames
    return meta


def optimize_pack(pack_files, frames_target=DEFAULT_FRAMES, end_portal_size=DEFAULT_END_PORTAL,
                  verbose=True, seen=None):
    """Return (new_files, changes, notes).  Only PNGs listed below are touched."""
    new_files = dict(pack_files)
    changes = []
    notes = []
    seen = seen if seen is not None else set()

    # 1. the end portal / end sky texture
    if end_portal_size and END_PORTAL in new_files:
        try:
            img = pnglite.decode(new_files[END_PORTAL])
        except pnglite.PngError as exc:
            notes.append(f"{END_PORTAL}: left alone ({exc})")
        else:
            if img.width > end_portal_size or img.height > end_portal_size:
                small = img.scale_box(end_portal_size, end_portal_size)
                encoded = pnglite.encode(small)
                changes.append({
                    "file": END_PORTAL,
                    "kind": "end-portal",
                    "before": len(new_files[END_PORTAL]),
                    "after": len(encoded),
                    "before_size": [img.width, img.height],
                    "after_size": [small.width, small.height],
                })
                new_files[END_PORTAL] = encoded
            elif verbose:
                notes.append(f"{END_PORTAL}: already {img.width}x{img.height}")

    # 2. animated strips
    for name in sorted(pack_files):
        if not name.endswith(".png") or name in seen:
            continue
        meta_name = name + ".mcmeta"
        raw_meta = pack_files.get(meta_name)
        if raw_meta is None:
            continue
        try:
            parsed = json.loads(raw_meta.decode("utf-8", "replace"))
        except ValueError:
            continue
        anim = parsed.get("animation") if isinstance(parsed, dict) else None
        if not isinstance(anim, dict):
            continue
        try:
            img = pnglite.decode(pack_files[name])
        except pnglite.PngError as exc:
            notes.append(f"{name}: left alone ({exc})")
            continue
        seen.add(name)
        frame_h = int(anim.get("height", img.width))
        if frame_h <= 0 or img.height % frame_h:
            notes.append(f"{name}: strip height {img.height} is not a multiple of {frame_h}")
            continue
        count = img.height // frame_h
        effective, explicit = _anim_frames(anim, count)
        if effective is None or not effective:
            notes.append(f"{name}: unreadable frame list, left alone")
            continue
        if explicit and not rotation_of_range(effective, count):
            notes.append(f"{name}: its {len(effective)}-entry frame list is not the whole strip "
                         f"in order - left alone so the animation keeps playing the same way")
            continue
        # the strip is what costs memory and uploads, so the reduction is based
        # on the number of strip frames (the list is remapped onto them)
        factor = frame_factor(count, frames_target)
        if factor < 2:
            continue
        try:
            reduced = pnglite.keep_frames(img, frame_h, factor)
        except pnglite.PngError as exc:
            notes.append(f"{name}: {exc}")
            continue
        new_anim = _rewrite_anim_meta(anim, factor)
        if new_anim is None:
            notes.append(f"{name}: animation block not reducible, left alone")
            continue
        new_parsed = dict(parsed)
        new_parsed["animation"] = new_anim
        encoded = pnglite.encode(reduced)
        changes.append({
            "file": name,
            "meta": meta_name,
            "kind": "animation",
            "before": len(pack_files[name]),
            "after": len(encoded),
            "frames_before": count,
            "frames_after": reduced.height // frame_h,
            "frames_used_before": len(effective),
            "list_before": len(effective),
            "factor": factor,
            "frametime": f"{anim.get('frametime', 1)} -> {new_anim['frametime']}",
        })
        new_files[name] = encoded
        new_files[meta_name] = json.dumps(new_parsed, indent=2).encode("utf-8")
    return new_files, changes, notes


# --------------------------------------------------------------------------- #
# the end portal pass cap
#
# Going near a stronghold or the End's exit portal in the stock client is a
# known frame killer, and not because of the texture: RenderEndPortal draws the
# same quad once per "pass" (up to 15 of them), each with its own texture matrix
# change and a blended draw call.  In a browser every one of those GL calls
# crosses the wasm -> JS boundary, so a 3x3 portal is thousands of calls and a
# few hundred draw calls *per frame*.  Fewer passes = proportionally less work.
#
# The pass count is a pure function of the distance, compiled into a tiny
# function in classes.wasm.  The stock module looks like this (decoded from the
# committed client, offsets are the i32.const immediates):
#
#     if (d > 36864.0) i = 1;  else if (d > 25600.0) i = 3;
#     else if (d > 16384.0) i = 5;  else if (d > 9216.0) i = 7;
#     else if (d > 4096.0) i = 9;   else if (d > 1024.0) i = 11;
#     else if (d > 576.0) i = 13;   else if (d >= 256.0) i = 15;  else i = 14;
#
# Every one of those is a single byte (0x41 <n>), so lowering one is a one byte
# edit that cannot break the module: the chain stays monotonic, the function
# stays valid, and the module still compiles.  The cap only ever lowers a pass
# count, so nothing can get *heavier* than the stock client.
# --------------------------------------------------------------------------- #
def _read_uleb(buf, off):
    value, shift = 0, 0
    for _ in range(5):
        b = buf[off]
        off += 1
        value |= (b & 0x7F) << shift
        if not (b & 0x80):
            return value, off
        shift += 7
    raise ValueError("malformed LEB128")


def find_end_portal_passes(wasm):
    """Locate RenderEndPortal.getPasses()'s compiled chain inside classes.wasm.

    Returns the list of (offset, passes) for every pass count in the chain,
    including the final `else` branch, or raises when the module does not look
    exactly like the stock one (a rebuild with a different compiler, a patched
    client, ... - in that case the caller must not touch it).
    """
    needle = struct.pack("<d", PORTAL_THRESHOLDS[0])
    hits = []
    start = 0
    while True:
        at = wasm.find(needle, start)
        if at < 0:
            break
        start = at + 1
        op = at - 1                                   # the 0x44 f64.const opcode
        if op < 0 or wasm[op] != 0x44:
            continue
        for k, value in enumerate(PORTAL_THRESHOLDS):  # thresholds 21 bytes apart
            p = op + 21 * k
            if p + 9 > len(wasm) or wasm[p] != 0x44:
                break
            if struct.unpack_from("<d", wasm, p + 1)[0] != value:
                break
        else:
            hits.append(op)
    if len(hits) != 1:
        raise ValueError(f"expected exactly one getPasses chain in classes.wasm, found {len(hits)}")

    op = hits[0]
    out = []
    for k in range(len(PORTAL_THRESHOLDS)):
        cmp_off = op + 9 + 21 * k                      # the compare opcode
        if wasm[cmp_off] not in (0x63, 0x64, 0x65, 0x66):
            raise ValueError(f"getPasses: unexpected instruction at {cmp_off:#x}")
        if (wasm[cmp_off + 1], wasm[cmp_off + 2], wasm[cmp_off + 3]) != (0x04, 0x40, 0x41):
            raise ValueError(f"getPasses: unexpected if/const at {cmp_off + 1:#x}")
        value, after = _read_uleb(wasm, cmp_off + 4)
        if (wasm[after], wasm[after + 2], wasm[after + 3], wasm[after + 4]) != (0x21, 0x0C, 0x01, 0x0B):
            raise ValueError(f"getPasses: unexpected branch at {after:#x}")
        out.append((cmp_off + 4, value))
    # the `else` branch right after the last if-body (cmp + 10 bytes of body)
    tail = op + 9 + 21 * (len(PORTAL_THRESHOLDS) - 1) + 10
    if wasm[tail] != 0x41:
        raise ValueError(f"getPasses: no final else branch at {tail:#x}")
    value, after = _read_uleb(wasm, tail + 1)
    if (wasm[after], wasm[after + 2], wasm[after + 3], wasm[after + 4]) != (0x21, 0x0B, 0x20, 0x02):
        raise ValueError(f"getPasses: unexpected else tail at {after:#x}")
    out.append((tail + 1, value))
    return out


def cap_end_portal_passes(wasm, cap=DEFAULT_PORTAL_PASSES):
    """Lower every pass count above `cap` in getPasses.  Returns (wasm, changes)."""
    if cap == 0:
        return wasm, []
    if not 1 <= cap < PORTAL_MAX_STOCK_PASSES:
        raise SystemExit(f"--portal-passes must be 0 or 1..{PORTAL_MAX_STOCK_PASSES - 1}")
    chain = find_end_portal_passes(wasm)
    changes = []
    out = bytearray(wasm)
    for offset, passes in chain:
        if passes > cap:
            if out[offset] != passes or passes > 0x3F:
                raise SystemExit("internal error: unexpected pass count encoding")
            out[offset] = cap                          # one byte, same length
            changes.append({"kind": "end_portal_passes", "offset": offset,
                            "before": passes, "after": cap})
    if bytes(out) != bytes(wasm):
        confirm = find_end_portal_passes(bytes(out))
        if [p for _o, p in confirm] != [min(p, cap) for _o, p in chain]:
            raise SystemExit("internal error: the patched chain does not read back")
    return bytes(out), changes


# --------------------------------------------------------------------------- #
# rewriting the client
# --------------------------------------------------------------------------- #
def splice_component(epw, get_slice, new_blob, label="component"):
    """Put `new_blob` (an EPK) in place of an EPW component, xz-compressed.

    `get_slice(header)` returns the CompressedSlice to replace in a freshly
    parsed header, so it keeps working after the rebuild.
    """
    header = P.parse_header(epw)
    comp = get_slice(header)
    if not isinstance(comp, P.CompressedSlice):
        raise SystemExit(f"{label} is not a compressed component")
    old_comp_len = comp.compressed_length
    old_stream = P.xz_stream_info(comp.data)
    new_comp = P.compress_component(new_blob, old_stream)
    delta = len(new_comp) - old_comp_len
    if delta == 0 and comp.data == new_comp:
        return bytes(epw), 0
    moved_at = comp.offset + old_comp_len
    rebuilt = bytearray(epw[:comp.offset] + new_comp + epw[comp.offset + old_comp_len:])
    new_header = P.parse_header(rebuilt)
    for sl in P.epw_data_slices(new_header):
        if sl.length and sl.offset >= moved_at:
            sl.offset += delta
    target = get_slice(new_header)
    target.compressed_length = len(new_comp)
    target.decompressed_length = len(new_blob)
    P.p32(rebuilt, 8, len(rebuilt))
    P.p32(rebuilt, 12, _crc32(rebuilt[16:]))
    P.validate_epw(bytes(rebuilt))
    return bytes(rebuilt), delta


def _crc32(data):
    import zlib
    return zlib.crc32(bytes(data)) & 0xFFFFFFFF


def _epk_entries(header):
    """[(index, path, CompressedSlice)] of the EPK packages inside an EPW."""
    out = []
    for i, entry in enumerate(header["epks"]):
        path = entry["filePath"].data.decode("utf-8", "replace")
        out.append((i, path, entry["fileData"]))
    return out


def optimize_client(epw, frames_target, end_portal_size, portal_passes=DEFAULT_PORTAL_PASSES,
                    verbose=True):
    """Rebuild every EPK inside an EPW, then cap the end portal passes.

    Returns (epw, report).
    """
    report = {"packs": [], "changes": [], "notes": [], "code": []}
    for index, path, comp in _epk_entries(P.parse_header(epw)):
        if comp.compressed_length == 0:
            continue
        raw = P.decompress_component(comp)
        try:
            parsed = epk.read(raw)
        except epk.EpkError as exc:
            report["notes"].append(f"{path}: not an EPK ({exc}) - left alone")
            continue
        files = epk.files(parsed)
        new_files, changes, notes = optimize_pack(files, frames_target, end_portal_size, verbose)
        report["notes"].extend(f"{path}: {n}" for n in notes)
        if not changes:
            report["packs"].append({"epk": path, "records": len(parsed["records"]),
                                    "changed": 0, "bytes_before": len(raw),
                                    "bytes_after": len(raw)})
            continue
        rebuilt = epk.write(
            [(mark, name, new_files.get(name, payload) if mark == epk.FILE_MARK else payload)
             for mark, name, payload in parsed["records"]],
            pack_name=parsed["pack_name"], comment=parsed["comment"],
            timestamp=parsed["timestamp"], compression=parsed["compression"])
        back = epk.read(rebuilt)
        if len(back["records"]) != len(parsed["records"]):
            raise SystemExit(f"{path}: record count changed while rebuilding")
        back_files = epk.files(back)
        for mark, name, payload in parsed["records"]:
            if mark == epk.FILE_MARK and name not in new_files and back_files[name] != payload:
                raise SystemExit(f"{path}: untouched file {name} changed")
        epw, _delta = splice_component(
            epw, lambda h, i=index: h["epks"][i]["fileData"], rebuilt, label=path)
        for change in changes:
            change["epk"] = path
            report["changes"].append(change)
        report["packs"].append({"epk": path, "records": len(parsed["records"]),
                                "changed": len(changes), "bytes_before": len(raw),
                                "bytes_after": len(rebuilt)})

    if portal_passes:
        epw, report = cap_portal_passes_in_client(epw, portal_passes, report, verbose)
    return epw, report


def cap_portal_passes_in_client(epw, cap, report, verbose=True):
    """Apply the end portal pass cap to the classes.wasm inside an EPW."""
    comp = P.parse_header(epw)["slices"]["classesWASMData"]
    if comp.compressed_length == 0:
        report["notes"].append("no classes.wasm in this EPW - end portal passes left alone")
        return epw, report
    wasm = P.decompress_component(comp)
    try:
        patched, changes = cap_end_portal_passes(wasm, cap)
    except ValueError as exc:
        report["notes"].append(f"end portal passes left alone: {exc}")
        return epw, report
    entry = {"component": "classesWASMData", "bytes_before": len(wasm),
             "bytes_after": len(patched), "passes": cap,
             "before": [p for _o, p in find_end_portal_passes(wasm)]}
    if not changes:
        entry["changed"] = 0
        report["code"].append(entry)
        return epw, report
    epw, _delta = splice_component(epw, lambda h: h["slices"]["classesWASMData"], patched,
                                   label="classes.wasm")
    entry["changed"] = len(changes)
    report["code"].append(entry)
    report["changes"].extend(changes)
    return epw, report


def _env_credentials():
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        ".verified-client.env")
    out = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                out[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def load_client(html, user, password, verbose=True):
    """(epw bytes, mode, params) - mode is 'sealed' or 'plain'."""
    sealed = html.find(P.SEALED_MARKER) >= 0
    if sealed:
        if not user or not password:
            raise SystemExit("this client is gated: --user and --pass are required "
                             "(or put the pair in .verified-client.env)")
        params = P.gate_params(html)
        epw = P.unseal_client(html, user, password)
        return epw, "sealed", params
    start, end, epw = P.decode_assets_uri(html)
    return epw, "plain", None


def save_client(html, epw, mode, params, user, password, verbose=True):
    if mode == "plain":
        start, end, _ = P.decode_assets_uri(html)
        return html[:start] + base64.b64encode(epw) + html[end:]
    import aesgcm
    key = aesgcm.pbkdf2_key(user, password, params["salt"], params["iterations"])
    sealed = aesgcm.seal(key, params["iv"], epw)
    if aesgcm.open_(key, params["iv"], sealed) != epw:
        raise SystemExit("internal error: the re-sealed payload does not round-trip")
    start, end, _ = P.decode_sealed(html)
    out = html[:start] + base64.b64encode(sealed) + html[end:]
    if base64.b64encode(epw)[100:200] in out:
        raise SystemExit("internal error: the plaintext payload is still in the HTML")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("client", nargs="?", help="client HTML (sealed or plain)")
    ap.add_argument("--pack", help="optimize a resource-pack EPK file instead of a client")
    ap.add_argument("--output", "-o", help="output file (default: <input>.optimized)")
    ap.add_argument("--user", help="gate username (sealed clients)")
    ap.add_argument("--pass", dest="password", help="gate password (sealed clients)")
    ap.add_argument("--frames", type=int, default=DEFAULT_FRAMES,
                    help=f"keep at most this many frames per animation (default {DEFAULT_FRAMES})")
    ap.add_argument("--end-portal", type=int, default=DEFAULT_END_PORTAL,
                    help=f"size of entity/end_portal.png (default {DEFAULT_END_PORTAL}, 0 = leave it)")
    ap.add_argument("--portal-passes", type=int, default=DEFAULT_PORTAL_PASSES,
                    help="most passes the end portal may draw per block, stock is up to "
                         f"{PORTAL_MAX_STOCK_PASSES} (default {DEFAULT_PORTAL_PASSES}, 0 = leave it)")
    ap.add_argument("--dry-run", action="store_true", help="report only, write nothing")
    ap.add_argument("--report", help="write the report as JSON to this file")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    if not args.client and not args.pack:
        ap.error("give a client HTML or --pack <file.epk>")
    env = _env_credentials()
    user = args.user or env.get("VER_CLIENT_USER") or os.environ.get("VER_CLIENT_USER")
    password = args.password or env.get("VER_CLIENT_PASS") or os.environ.get("VER_CLIENT_PASS")
    verbose = not args.quiet

    if args.pack:
        raw = open(args.pack, "rb").read()
        parsed = epk.read(raw)
        new_files, changes, notes = optimize_pack(epk.files(parsed), args.frames, args.end_portal)
        rebuilt = epk.write(
            [(mark, name, new_files.get(name, payload) if mark == epk.FILE_MARK else payload)
             for mark, name, payload in parsed["records"]],
            pack_name=parsed["pack_name"], comment=parsed["comment"],
            timestamp=parsed["timestamp"], compression=parsed["compression"])
        epk.read(rebuilt)
        report = {"input": args.pack, "packs": [{"epk": os.path.basename(args.pack),
                                                 "records": len(parsed["records"]),
                                                 "changed": len(changes),
                                                 "bytes_before": len(raw),
                                                 "bytes_after": len(rebuilt)}],
                  "changes": changes, "notes": notes}
        _print_report(report, verbose)
        if args.report:
            json.dump(report, open(args.report, "w"), indent=2)
            print(f"report: {args.report}")
        if args.dry_run:
            return 0
        out = args.output or (args.pack + ".optimized")
        with open(out, "wb") as fh:
            fh.write(rebuilt)
        print(f"wrote {out} ({len(raw)} -> {len(rebuilt)} bytes)")
        return 0

    html = open(args.client, "rb").read()
    epw, mode, params = load_client(html, user, password, verbose)
    before = len(epw)
    epw, report = optimize_client(epw, args.frames, args.end_portal, args.portal_passes, verbose)
    report["input"] = args.client
    report["epw_bytes_before"] = before
    report["epw_bytes_after"] = len(epw)
    _print_report(report, verbose)
    if args.report:
        json.dump(report, open(args.report, "w"), indent=2)
        print(f"report: {args.report}")
    if args.dry_run:
        print("dry run: nothing written")
        return 0
    out_html = save_client(html, epw, mode, params, user, password, verbose)
    out = args.output or (args.client + ".optimized")
    with open(out, "wb") as fh:
        fh.write(out_html)
    print(f"wrote {out} ({len(html)} -> {len(out_html)} bytes)")
    return 0


def _print_report(report, verbose):
    total_before = total_after = 0
    for pack in report["packs"]:
        total_before += pack["bytes_before"]
        total_after += pack["bytes_after"]
    if verbose:
        for change in report["changes"]:
            if change["kind"] == "end_portal_passes":
                print(f"  end portal : pass {change['before']} -> {change['after']} "
                      f"(at {change['offset']:#x} in classes.wasm)")
            elif change["kind"] == "end-portal":
                print(f"  end portal : {change['before_size'][0]}x{change['before_size'][1]} -> "
                      f"{change['after_size'][0]}x{change['after_size'][1]} "
                      f"({change['before']} -> {change['after']} bytes)")
            else:
                print(f"  animation  : {change['file']} "
                      f"{change['frames_before']} -> {change['frames_after']} frames "
                      f"(every {change['factor']}th, frametime {change['frametime']}) "
                      f"{change['before']} -> {change['after']} bytes")
        for note in report["notes"]:
            print(f"  note       : {note}")
    print(f"changed {len(report['changes'])} file(s); EPK data {total_before} -> {total_after} bytes"
          + (f"; EPW {report['epw_bytes_before']} -> {report['epw_bytes_after']} bytes"
             if "epw_bytes_before" in report else ""))


if __name__ == "__main__":
    sys.exit(main())
