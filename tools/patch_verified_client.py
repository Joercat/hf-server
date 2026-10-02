#!/usr/bin/env python3
"""
patch_verified_client.py - turn an Eaglercraft 1.12 (WASM-GC / EPW) client into a
"verified client" that identifies itself to EaglerX servers.

How it works
------------
An EaglercraftX client reports who it is during the login handshake: it sends a
16-byte "client brand UUID" (protocol profile-data key `brand_uuid_v1`).  That
UUID is computed *on the client* from its brand name:

    brandUUID = UUID.nameUUIDFromBytes("EaglercraftXClient:" + brandName)

(a name-based MD5 UUID, RFC 4122 version 3), so it is a pure function of the
brand string.  The stock Eaglercraft 1.12 client uses the brand name
`Eaglercraft 1.12`, which produces `522b2ce5-c9b9-36cf-be7c-5d90f55e631a` - the
UUID the official EaglerX server registers as BRAND_EAGLERCRAFT_1_12.

This tool rewrites that brand name constant inside the client's compiled
`classes.wasm` (16 bytes -> 16 bytes, so no layout shifts are needed) and then
repairs the EPW container (component offsets + CRC32).  The result is a client
that reports a unique, recognisable brand UUID to the server, which is what
makes "is this really my client?" visible in the server logs.

Client file layout:

    HTML ->  <script> window.eaglercraftXOpts.assetsURI = "data:...;base64,<EPW>"
    EPW  ->  header (384 bytes, "EAG$WASM") + components
             +- classes.wasm        (XZ compressed)   <- the brand constant lives here
             +- eagruntime.js, loader.js/wasm, sprites, assets EPK files, ...

Only the brand constant inside classes.wasm is touched; everything else in the
client is byte-for-byte identical.
"""

import argparse
import base64
import hashlib
import lzma
import re
import struct
import sys
import uuid
import zlib

EPW_MAGIC = b"EAG$WASM"
HEADER_FIXED = 276      # header size without the assetsEPKs table
ASSET_EPK_ENTRY = 32    # bytes per assetsEPKs[] entry
BRAND_PREFIX = "EaglercraftXClient:"
EXPECTED_BRAND_LEN = 16                 # the stock brand string is 16 bytes long
STOCK_BRAND = "Eaglercraft 1.12"
STOCK_BRAND_UUID = "522b2ce5-c9b9-36cf-be7c-5d90f55e631a"

# The EPW loader (loader.wasm -> main.c) decompresses every component with
#     xz_dec_init(XZ_DYNALLOC, 33554432)
# i.e. an LZMA2 dictionary of AT MOST 32 MiB.  A stream compressed with a bigger
# dictionary fails with XZ_OPTIONS_ERROR ("Decompression failed, code 6!") and
# the client shows "EPW file is invalid / Try again later", so every component
# must stay within these limits.  The stock 1.12 client uses a 32 MiB dictionary
# and no integrity check; we match that.
EAGLER_MAX_DICT = 32 * 1024 * 1024
XZ_CHECK_NONE, XZ_CHECK_CRC32, XZ_CHECK_CRC64, XZ_CHECK_SHA256 = 0, 1, 4, 10
LZMA_CHECK_IDS = {XZ_CHECK_NONE: lzma.CHECK_NONE,
                  XZ_CHECK_CRC32: lzma.CHECK_CRC32,
                  XZ_CHECK_CRC64: lzma.CHECK_CRC64}

ASSETS_URI_MARKER = b'window.eaglercraftXOpts.assetsURI = "data:application/octet-stream;base64,'

# string-pool entry: <len byte><brand><next entry len><next entry>
BRAND_POOL_RE = re.compile(rb"\x10([\x20-\x7e]{16})\x16EaglercraftXClientOld:")


# --------------------------------------------------------------------------- #
# brand UUID
# --------------------------------------------------------------------------- #
def brand_uuid(brand: str) -> uuid.UUID:
    """EagUtils.makeClientBrandUUID(name) - same algorithm as the client/server."""
    h = bytearray(hashlib.md5((BRAND_PREFIX + brand).encode("utf-8")).digest())
    h[6] = (h[6] & 0x0F) | 0x30   # UUID version 3
    h[8] = (h[8] & 0x3F) | 0x80   # RFC 4122 variant
    return uuid.UUID(bytes=bytes(h))


# --------------------------------------------------------------------------- #
# EPW container
# --------------------------------------------------------------------------- #
def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def p32(buf, off, value):
    struct.pack_into("<I", buf, off, value)


class Slice:
    """A (offset, length) pointer into the EPW, bound to its backing buffer."""

    def __init__(self, buf, field_off, name):
        self.buf = buf
        self.field_off = field_off
        self.name = name

    @property
    def offset(self):
        return u32(self.buf, self.field_off)

    @offset.setter
    def offset(self, value):
        p32(self.buf, self.field_off, value)

    @property
    def length(self):
        return u32(self.buf, self.field_off + 4)

    @property
    def data(self):
        return bytes(self.buf[self.offset:self.offset + self.length])


class CompressedSlice(Slice):
    """(offset, compressedLength, decompressedLength, reserved)."""

    @property
    def compressed_length(self):
        return u32(self.buf, self.field_off + 4)

    @compressed_length.setter
    def compressed_length(self, value):
        p32(self.buf, self.field_off + 4, value)

    @property
    def decompressed_length(self):
        return u32(self.buf, self.field_off + 8)

    @decompressed_length.setter
    def decompressed_length(self, value):
        p32(self.buf, self.field_off + 8, value)


SLICE_FIELDS = {
    "clientPackageName": (24, Slice),
    "clientOriginName": (32, Slice),
    "clientOriginVersion": (40, Slice),
    "clientOriginVendor": (48, Slice),
    "clientForkName": (56, Slice),
    "clientForkVersion": (64, Slice),
    "clientForkVendor": (72, Slice),
    "metadataSegment": (80, Slice),
    "splashImageData": (100, Slice),
    "splashImageMIME": (108, Slice),
    "pressAnyKeyImageData": (116, Slice),
    "pressAnyKeyImageMIME": (124, Slice),
    "crashImageData": (132, Slice),
    "crashImageMIME": (140, Slice),
    "faviconImageData": (148, Slice),
    "faviconImageMIME": (156, Slice),
    "loaderJSData": (164, Slice),
    "loaderWASMData": (180, Slice),
    "JSPIUnavailableData": (196, CompressedSlice),
    "eagruntimeJSData": (212, CompressedSlice),
    "classesWASMData": (228, CompressedSlice),
    "classesDeobfTEADBGData": (244, CompressedSlice),
    "classesDeobfWASMData": (260, CompressedSlice),
}


def parse_header(buf):
    if bytes(buf[:8]) != EPW_MAGIC:
        raise SystemExit("not an EPW file (bad magic)")
    num_epks = u32(buf, 96)
    header_len = (HEADER_FIXED + ASSET_EPK_ENTRY * num_epks + 127) & ~127
    if header_len > len(buf):
        raise SystemExit("EPW file is truncated")
    slices = {name: cls(buf, off, name) for name, (off, cls) in SLICE_FIELDS.items()}
    epks = []
    for i in range(num_epks):
        base = HEADER_FIXED + i * ASSET_EPK_ENTRY
        epks.append({
            "filePath": Slice(buf, base, f"asset[{i}].filePath"),
            "loadPath": Slice(buf, base + 8, f"asset[{i}].loadPath"),
            "fileData": CompressedSlice(buf, base + 16, f"asset[{i}].fileData"),
        })
    return {"num_epks": num_epks, "header_len": header_len, "slices": slices, "epks": epks}


def epw_data_slices(header):
    out = list(header["slices"].values())
    for epk in header["epks"]:
        out.extend(epk.values())
    return out


def read_vli(buf, off):
    """XZ variable length integer: 7 bits per byte, little endian."""
    value, shift = 0, 0
    for _ in range(9):
        b = buf[off]
        off += 1
        value |= (b & 0x7F) << shift
        if not (b & 0x80):
            return value, off
        shift += 7
    raise ValueError("malformed XZ VLI")


def lzma2_dict_size(prop):
    """Dictionary size encoded in the LZMA2 filter property byte."""
    if prop > 40:
        raise ValueError(f"invalid LZMA2 property byte {prop}")
    if prop == 40:
        return 0xFFFFFFFF
    return (2 | (prop & 1)) << (prop // 2 + 11)


def xz_stream_info(blob):
    """Decode an XZ stream header far enough to see the LZMA2 options.

    The loader reads these itself: a dictionary above EAGLER_MAX_DICT or an
    integrity check it was not built with makes it refuse the whole file.
    """
    if bytes(blob[:6]) != b"\xfd7zXZ\x00":
        raise ValueError("slice does not start with an XZ stream header")
    check = blob[6]
    i = 12                                    # 6 magic + 2 flags + 4 flags-CRC32
    header_size = blob[i]
    i += 1
    block_flags = blob[i]
    i += 1
    if block_flags & 0x3F:
        raise ValueError("unknown block header flags")
    if block_flags & 0x40:                    # compressed size field
        _, i = read_vli(blob, i)
    if block_flags & 0x80:                    # uncompressed size field
        _, i = read_vli(blob, i)
    filter_id, i = read_vli(blob, i)
    props_size, i = read_vli(blob, i)
    props = bytes(blob[i:i + props_size])
    info = {"check": check, "filter": filter_id, "props": props,
            "dict_size": None, "block_header_size": header_size}
    if filter_id == 0x21 and props_size == 1:     # LZMA2
        info["dict_size"] = lzma2_dict_size(props[0])
    return info


def lzma2_filter(dict_size, preset=9):
    return {"id": lzma.FILTER_LZMA2, "preset": preset, "dict_size": dict_size}


def compress_component(blob, original_stream_info):
    """Recompress an EPW component the way the loader can actually read it."""
    dict_size = original_stream_info["dict_size"] or EAGLER_MAX_DICT
    dict_size = min(dict_size, EAGLER_MAX_DICT)
    check = LZMA_CHECK_IDS.get(original_stream_info["check"], lzma.CHECK_NONE)
    out = lzma.compress(bytes(blob), format=lzma.FORMAT_XZ, check=check,
                        filters=[lzma2_filter(dict_size)])
    info = xz_stream_info(out)
    if info["dict_size"] is None or info["dict_size"] > EAGLER_MAX_DICT:
        raise ValueError("internal error: recompressed stream exceeds the loader's dictionary limit")
    if info["check"] != original_stream_info["check"]:
        raise ValueError("internal error: recompressed stream changed the integrity check")
    return out


def validate_wasm(blob):
    """Minimal WebAssembly binary walk: every section must fit exactly."""
    if blob[:8] != b"\x00asm\x01\x00\x00\x00":
        raise ValueError("payload is not a wasm module")
    i, sections = 8, 0
    while i < len(blob):
        sec_id = blob[i]
        i += 1
        size, shift = 0, 0
        while True:
            if i >= len(blob):
                raise ValueError("truncated section size")
            b = blob[i]
            i += 1
            size |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80):
                break
        if i + size > len(blob):
            raise ValueError(f"section {sec_id} overruns the module")
        if sec_id == 0 and size == 0:
            raise ValueError("empty custom section is invalid")
        i += size
        sections += 1
        if sections > 100000:
            raise ValueError("too many sections")
    if i != len(blob):
        raise ValueError("trailing bytes in module")


def decompress_component(sl, strict=True):
    """Decode one compressed EPW component exactly like loader.wasm does.

    loader.wasm (main.c) runs the stream through xz-embedded with a 32 MiB
    dictionary limit and requires that the stream ends *exactly* at the end of
    the declared slice ("Decompression completed, but there is still some input
    data remaining" -> "EPW file is invalid").
    """
    data = sl.data
    info = xz_stream_info(data)
    if info["dict_size"] is None:
        raise ValueError(f"{sl.name}: not an LZMA2 XZ stream (filter 0x{info['filter']:02x})")
    if info["dict_size"] > EAGLER_MAX_DICT:
        raise ValueError(f"{sl.name}: dictionary {info['dict_size']} exceeds the loader's "
                         f"{EAGLER_MAX_DICT} byte limit (XZ_OPTIONS_ERROR, code 6)")
    if info["check"] not in LZMA_CHECK_IDS:
        raise ValueError(f"{sl.name}: unsupported integrity check {info['check']}")
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
    blob = dec.decompress(data)
    if strict:
        if not dec.eof:
            raise ValueError(f"{sl.name}: XZ stream is truncated")
        if dec.unused_data:
            raise ValueError(f"{sl.name}: {len(dec.unused_data)} bytes of trailing data in the "
                             "slice (the loader would refuse it)")
    if len(blob) != sl.decompressed_length:
        raise ValueError(f"{sl.name}: decompressed {len(blob)} bytes, header says "
                         f"{sl.decompressed_length}")
    return blob


def validate_epw(data, verbose=False):
    """Repeat every structural check the Eaglercraft EPW loader performs."""
    if bytes(data[:8]) != EPW_MAGIC:
        raise ValueError("bad EPW magic")
    if u32(data, 8) != len(data):
        raise ValueError("fileLength field does not match the file size")
    if u32(data, 12) != (zlib.crc32(bytes(data[16:])) & 0xFFFFFFFF):
        raise ValueError("fileCRC32 does not match (the loader would refuse to start)")
    header = parse_header(data)
    for sl in epw_data_slices(header):
        if sl.length and (sl.offset < header["header_len"] or sl.offset + sl.length > len(data)):
            raise ValueError(f"slice {sl.name} is out of bounds")
    for sl in epw_data_slices(header):
        if isinstance(sl, CompressedSlice):
            decompress_component(sl)
    if verbose:
        dicts = sorted({xz_stream_info(s.data)["dict_size"]
                        for s in epw_data_slices(header) if isinstance(s, CompressedSlice)})
        print(f"    EPW ok: {len(data)} bytes, {header['num_epks']} asset EPK(s), CRC32 ok, "
              f"XZ dictionaries {'/'.join(str(d // 1048576) + 'MiB' for d in dicts)}")
    return header


def decode_assets_uri(html):
    pos = html.find(ASSETS_URI_MARKER)
    if pos < 0:
        raise SystemExit("could not find window.eaglercraftXOpts.assetsURI data URI in the HTML")
    start = pos + len(ASSETS_URI_MARKER)
    end = html.find(b'"', start)
    if end < 0:
        raise SystemExit("unterminated base64 data URI")
    return start, end, base64.b64decode(html[start:end])


def read_brand(wasm):
    m = BRAND_POOL_RE.search(wasm)
    return m.group(1).decode("ascii") if m else None


# --------------------------------------------------------------------------- #
# the patch
# --------------------------------------------------------------------------- #
def patch_html(html, new_brand, verbose=True):
    if len(new_brand) != EXPECTED_BRAND_LEN:
        raise SystemExit(f"--brand must be exactly {EXPECTED_BRAND_LEN} ASCII characters "
                         f"(got {len(new_brand)})")
    try:
        new_brand_b = new_brand.encode("ascii")
    except UnicodeEncodeError:
        raise SystemExit("--brand must be plain ASCII")

    start, end, decoded = decode_assets_uri(html)
    data = bytearray(decoded)
    header = parse_header(data)
    comp = header["slices"]["classesWASMData"]
    old_comp_len = comp.compressed_length

    if verbose:
        print(f"[+] EPW   : {len(data)} bytes, version "
              f"{struct.unpack_from('<H', data, 16)[0]}.{struct.unpack_from('<H', data, 18)[0]}, "
              f"fork={header['slices']['clientForkName'].data.decode('utf-8', 'replace')!r}")

    orig_stream = xz_stream_info(comp.data)
    wasm = bytearray(decompress_component(comp))
    if len(wasm) != comp.decompressed_length:
        raise SystemExit("classes.wasm decompressed size mismatch")
    if verbose:
        print(f"[+] xz    : dictionary {orig_stream['dict_size'] // 1048576}MiB, "
              f"check={'none' if orig_stream['check'] == 0 else orig_stream['check']} "
              f"(the loader allows at most {EAGLER_MAX_DICT // 1048576}MiB)")

    old_brand = read_brand(wasm)
    if old_brand is None:
        raise SystemExit("could not locate the client brand constant inside classes.wasm")
    if old_brand == new_brand:
        if verbose:
            print(f"[=] client already reports brand {new_brand!r} - nothing to do")
        return html
    if verbose:
        print(f"[+] brand : {old_brand!r} -> {new_brand!r}  (UUID "
              f"{brand_uuid(old_brand)} -> {brand_uuid(new_brand)})")

    m = BRAND_POOL_RE.search(wasm)
    wasm[m.start(1):m.end(1)] = new_brand_b
    validate_wasm(bytes(wasm))

    new_comp = compress_component(wasm, orig_stream)
    if verbose:
        print(f"[+] wasm  : {len(wasm)} bytes unchanged; XZ {old_comp_len} -> {len(new_comp)} bytes")

    delta = len(new_comp) - old_comp_len
    rebuilt = bytearray(data[:comp.offset] + new_comp + data[comp.offset + old_comp_len:])

    moved_at = comp.offset + old_comp_len
    new_header = parse_header(rebuilt)
    for sl in epw_data_slices(new_header):
        if sl.length and sl.offset >= moved_at:
            sl.offset += delta
    new_comp_slice = new_header["slices"]["classesWASMData"]
    new_comp_slice.compressed_length = len(new_comp)
    new_comp_slice.decompressed_length = len(wasm)

    p32(rebuilt, 8, len(rebuilt))
    p32(rebuilt, 12, zlib.crc32(bytes(rebuilt[16:])) & 0xFFFFFFFF)

    validate_epw(bytes(rebuilt), verbose=verbose)

    # sanity: the patched payload is what it should be
    check = decompress_component(new_header["slices"]["classesWASMData"])
    validate_wasm(check)
    if read_brand(check) != new_brand:
        raise SystemExit("internal error: patched brand not found after rebuild")

    out_html = html[:start] + base64.b64encode(bytes(rebuilt)) + html[end:]
    if verbose:
        print(f"[+] html  : {len(html)} -> {len(out_html)} bytes")
    return out_html


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("html", nargs="?", help="client HTML file (e.g. client/1.12.html)")
    ap.add_argument("--brand", default="Eaglercraft[VER]",
                    help="new client brand, exactly 16 ASCII characters (default: %(default)r)")
    ap.add_argument("--output", help="write to this file instead of patching in place")
    ap.add_argument("--print-uuid", action="store_true",
                    help="only print the UUID a brand produces, then exit")
    ap.add_argument("--check", action="store_true",
                    help="verify an existing client and report its brand, do not modify it")
    args = ap.parse_args()

    if args.print_uuid:
        print(f"brand     : {args.brand!r}")
        print(f"brandUUID : {brand_uuid(args.brand)}")
        print(f"stock     : {STOCK_BRAND_UUID}  ({STOCK_BRAND!r})")
        return

    if not args.html:
        ap.error("a client HTML file is required (or use --print-uuid)")
    html = open(args.html, "rb").read()

    if args.check:
        start, end, data = decode_assets_uri(html)
        try:
            header = validate_epw(data, verbose=True)
        except ValueError as exc:
            raise SystemExit(f"    INVALID - the Eaglercraft loader would refuse this file:\n"
                             f"      {exc}")
        wasm = decompress_component(header["slices"]["classesWASMData"])
        brand = read_brand(wasm)
        print(f"    brand     : {brand!r}")
        print(f"    brandUUID : {brand_uuid(brand) if brand else '?'}")
        print(f"    stock     : {STOCK_BRAND_UUID}  ({STOCK_BRAND!r})")
        return

    out_html = patch_html(html, args.brand)
    target = args.output or args.html
    with open(target, "wb") as fh:
        fh.write(out_html)
    print()
    print(f"[ok] wrote {target}")
    print(f"     brand     : {args.brand}")
    print(f"     brandUUID : {brand_uuid(args.brand)}")
    print("     -> put that UUID in start.sh as VERIFIED_CLIENT_UUID to switch detection on")


if __name__ == "__main__":
    main()
