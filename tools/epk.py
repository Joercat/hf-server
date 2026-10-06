#!/usr/bin/env python3
"""epk.py - read and write Eaglercraft EPK v2.0 packages ("EAGPKG$$").

An EPK is the archive the client loads its assets from (`assets.epk` inside the
EPW container).  The format is a small record stream:

    EAGPKG$$ <len>"ver2.0" <len>packname <u16>comment comment <u64>timestamp
             <u32>recordcount <compression byte> <stream> :::YEE:>

and the stream (uncompressed, or gzip/zlib compressed) holds:

    HEAD <len>key <u32>len value >                     (metadata, e.g. file-type)
    FILE <len>path <u32>len+5 <u32>crc32 data : >      (one file)
    END$                                               (end of stream)

This is a byte-exact port of lax1dude's EaglerBinaryTools EPKCompiler /
EPKDecompiler (the tools that produced the file), so a package read and written
by this module is the same package the client would have downloaded.

usage:
  python3 tools/epk.py list  <file.epk> [--filter TEXT]
  python3 tools/epk.py get   <file.epk> <path> [-o out.bin]
  python3 tools/epk.py pack  <dir> <out.epk> [--compression none|zlib|gzip]
  python3 tools/epk.py selftest
"""

import argparse
import os
import struct
import sys
import zlib

MAGIC = b"EAGPKG$$"
TRAILER = b":::YEE:>"
VERSION = b"ver2.0"
END_MARK = "END$"
HEAD_MARK = "HEAD"
FILE_MARK = "FILE"
COMPRESSIONS = {"0": "none", "Z": "zlib", "G": "gzip"}
COMPRESSION_BYTES = {"none": "0", "zlib": "Z", "gzip": "G"}


class EpkError(ValueError):
    pass


def is_epk(data) -> bool:
    return bytes(data[:8]) == MAGIC


def _u16(data, off):
    return struct.unpack_from(">H", data, off)[0]


def _u32(data, off):
    return struct.unpack_from(">I", data, off)[0]


def _u64(data, off):
    return struct.unpack_from(">Q", data, off)[0]


def read(data):
    """Parse a whole EPK.  Returns a dict with the header fields and the records.

    records is a list of (mark, name, payload) in file order; `name` is the
    record's name ("" for END$).  Anything malformed is refused with EpkError -
    a truncated package must never be silently accepted.
    """
    try:
        return _read(data)
    except EpkError:
        raise
    except (struct.error, IndexError, UnicodeDecodeError, zlib.error) as exc:
        raise EpkError(f"truncated or corrupt EPK: {exc}") from exc


def _read(data):
    data = bytes(data)
    if not is_epk(data):
        raise EpkError("not an EPK (bad magic)")
    off = 8
    vlen = data[off]
    off += 1
    version = data[off:off + vlen].decode("latin1")
    off += vlen
    if not version.startswith("ver2."):
        raise EpkError(f"unsupported EPK version {version!r}")
    nlen = data[off]
    off += 1
    pack_name = data[off:off + nlen].decode("utf-8", "replace")
    off += nlen
    clen = _u16(data, off)
    off += 2
    comment = data[off:off + clen].decode("utf-8", "replace")
    off += clen
    timestamp = _u64(data, off)
    off += 8
    count = _u32(data, off)
    off += 4
    comp = chr(data[off])
    off += 1
    if comp not in COMPRESSIONS:
        raise EpkError(f"unknown compression type {comp!r}")
    body = data[off:-len(TRAILER)] if data.endswith(TRAILER) else data[off:]
    if comp == "Z":
        body = zlib.decompress(body)
    elif comp == "G":
        body = zlib.decompress(body, 16 + zlib.MAX_WBITS)

    records = []
    pos = 0
    while True:
        mark = body[pos:pos + 4].decode("latin1")
        pos += 4
        if mark == "END$":
            records.append((mark, "", b""))
            break
        nl = body[pos]
        pos += 1
        name = body[pos:pos + nl].decode("utf-8", "replace")
        pos += nl
        blen = _u32(body, pos)
        pos += 4
        if mark == FILE_MARK:
            if blen < 5:
                raise EpkError(f"{name}: file record too short ({blen})")
            crc = _u32(body, pos)
            pos += 4
            payload = body[pos:pos + blen - 5]
            pos += blen - 5
            if zlib.crc32(payload) & 0xFFFFFFFF != crc:
                raise EpkError(f"{name}: CRC32 mismatch")
            if body[pos] != 0x3A:
                raise EpkError(f"{name}: missing ':' terminator")
            pos += 1
        else:
            payload = body[pos:pos + blen]
            pos += blen
        if body[pos] != 0x3E:
            raise EpkError(f"{name}: missing '>' terminator")
        pos += 1
        records.append((mark, name, payload))
        if len(records) > 1000000:
            raise EpkError("too many records")
    return {"version": version, "pack_name": pack_name, "comment": comment,
            "timestamp": timestamp, "count": count, "compression": comp,
            "records": records}


def files(data):
    """{path: bytes} for a parsed or raw EPK."""
    parsed = read(data) if isinstance(data, (bytes, bytearray)) else data
    return {name: payload for mark, name, payload in parsed["records"] if mark == FILE_MARK}


def write(records, pack_name="assets.epk", comment=None, timestamp=None,
          compression="0", file_type="epk/resources"):
    """Build an EPK.  `records` is [(mark, name, payload)] or {name: bytes}."""
    if isinstance(compression, str) and compression in COMPRESSIONS:
        compression = COMPRESSIONS[compression]        # accept the raw marker too
    if compression not in COMPRESSION_BYTES:
        raise EpkError(f"unknown compression {compression!r}")
    if timestamp is None:
        import time
        timestamp = int(time.time() * 1000)
    if comment is None:
        import datetime
        when = datetime.datetime.fromtimestamp(timestamp / 1000.0)
        comment = ("\n\n #  Eagler EPK v2.0 (c) 2025 lax1dude\n"
                   f" #  update: on {when:%m/%d/%Y} at {when:%I:%M:%S %p}\n\n")

    if isinstance(records, dict):
        records = [(FILE_MARK, name, payload) for name, payload in records.items()]
    has_head = any(mark == HEAD_MARK for mark, _, _ in records)
    body = bytearray()
    count = 0
    if not has_head:
        value = file_type.encode("utf-8")
        body += HEAD_MARK.encode("ascii") + bytes([9]) + b"file-type" + struct.pack(">I", len(value)) + value + b">"
        count += 1
    for mark, name, payload in records:
        if mark == END_MARK:
            continue
        raw_name = name.encode("utf-8")
        if len(raw_name) > 255:
            raise EpkError(f"{name}: name too long for the EPK format")
        mark_bytes = mark.encode("ascii") if isinstance(mark, str) else bytes(mark)
        body += mark_bytes + bytes([len(raw_name)]) + raw_name
        if mark == FILE_MARK:
            body += struct.pack(">I", len(payload) + 5)
            body += struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
            body += payload + b":>"
        else:
            body += struct.pack(">I", len(payload)) + payload + b">"
        count += 1
    body += END_MARK.encode("ascii")

    name_bytes = pack_name.encode("utf-8")
    comment_bytes = comment.encode("utf-8")
    out = bytearray()
    out += MAGIC + bytes([len(VERSION)]) + VERSION
    out += bytes([len(name_bytes)]) + name_bytes
    out += struct.pack(">H", len(comment_bytes)) + comment_bytes
    out += struct.pack(">Q", timestamp)
    # the count field is the number of records before END$ (HEAD included) -
    # that is what EaglerBinaryTools' EPKCompiler writes (+1 for END$) and what
    # the client's own reader expects
    out += struct.pack(">I", count)
    out += COMPRESSION_BYTES[compression].encode("ascii")
    if compression == "zlib":
        out += zlib.compress(bytes(body), 9)
    elif compression == "gzip":
        import gzip
        import io
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
            gz.write(bytes(body))
        out += buf.getvalue()
    else:
        out += body
    out += TRAILER
    return bytes(out)


def _selftest() -> int:
    import hashlib
    payloads = {
        "assets/.mcassetsroot": b"",
        "assets/minecraft/textures/blocks/water_still.png": b"\x89PNG\r\n\x1a\n" + os.urandom(4096),
        "assets/minecraft/textures/entity/end_portal.png": os.urandom(5000),
        "assets/minecraft/sounds/random/click.ogg": os.urandom(700),
        "weird name/with space & ünicode.txt": b"hello",
    }
    for comp in ("none", "zlib", "gzip"):
        blob = write(payloads, pack_name="assets.epk", compression=comp,
                     timestamp=1743358932794)
        back = read(blob)
        got = files(back)
        if got != payloads:
            print(f"selftest: {comp}: round-trip mismatch")
            return 1
        if back["compression"] != COMPRESSION_BYTES[comp]:
            print(f"selftest: {comp}: compression marker wrong")
            return 1
        # rebuilding byte-for-byte from the parsed records must be stable
        again = write(back["records"], pack_name=back["pack_name"], comment=back["comment"],
                      timestamp=back["timestamp"], compression=back["compression"])
        if comp == "none" and hashlib.sha256(again).hexdigest() != hashlib.sha256(blob).hexdigest():
            print(f"selftest: {comp}: rebuild not byte-identical")
            return 1
    # a truncated / corrupted package must be refused, not silently accepted
    blob = write(payloads, compression="none", timestamp=1)
    try:
        read(blob[:-40])
        print("selftest: truncated package accepted")
        return 1
    except EpkError:
        pass
    bad = bytearray(blob)
    i = bad.find(b"water_still.png")
    bad[i:i + 20] = b"water_stillXpng" + bytes(5)
    try:
        read(bytes(bad))
        print("selftest: corrupted file content accepted (CRC check missing)")
        return 1
    except EpkError:
        pass
    print("selftest: OK (round-trip, byte-identical rebuild, corruption refused)")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="read/write Eaglercraft EPK v2 packages")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list")
    p.add_argument("epk")
    p.add_argument("--filter", default="")

    p = sub.add_parser("get")
    p.add_argument("epk")
    p.add_argument("path")
    p.add_argument("-o", "--output")

    p = sub.add_parser("pack")
    p.add_argument("directory")
    p.add_argument("output")
    p.add_argument("--compression", choices=sorted(COMPRESSION_BYTES), default="none")

    sub.add_parser("selftest")
    args = ap.parse_args(argv)

    if args.cmd == "selftest":
        return _selftest()
    if args.cmd == "list":
        parsed = read(open(args.epk, "rb").read())
        print(f"{args.epk}: {parsed['count']} records, pack {parsed['pack_name']!r}, "
              f"compression {COMPRESSIONS[parsed['compression']]}")
        for mark, name, payload in parsed["records"]:
            if args.filter and args.filter not in name:
                continue
            print(f"  {mark} {len(payload):9d}  {name}")
        return 0
    if args.cmd == "get":
        payload = files(open(args.epk, "rb").read()).get(args.path)
        if payload is None:
            print(f"{args.path}: not in {args.epk}", file=sys.stderr)
            return 1
        if args.output:
            with open(args.output, "wb") as fh:
                fh.write(payload)
        else:
            sys.stdout.buffer.write(payload)
        return 0
    if args.cmd == "pack":
        collected = {}
        for root, _dirs, names in os.walk(args.directory):
            for name in sorted(names):
                full = os.path.join(root, name)
                rel = os.path.relpath(full, args.directory).replace(os.sep, "/")
                collected[rel] = open(full, "rb").read()
        blob = write(collected, pack_name=os.path.basename(args.output),
                     compression=args.compression)
        with open(args.output, "wb") as fh:
            fh.write(blob)
        print(f"wrote {args.output}: {len(collected)} files, {len(blob)} bytes")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
