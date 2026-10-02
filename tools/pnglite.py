#!/usr/bin/env python3
"""pnglite.py - the small PNG subset the client's own decoder understands.

Only what the client's assets need: 8-bit images, no interlacing, colour types
0 (gray), 2 (RGB), 3 (palette, with optional tRNS), 4 (gray+alpha) and 6 (RGBA).
Everything is decoded to RGBA8 and encoded back as RGBA8, which is exactly what
the game's texture loader produces internally, so the client sees no difference
apart from the pixels themselves.

The point of this module is scale: `scale_box()` and `keep_frames()` are the two
operations the client-side optimiser needs (shrink a texture, keep every n-th
frame of an animated strip).  No external image library is used - the sandbox and
the Space both only have Python.

usage:
  python3 tools/pnglite.py info    <file.png>
  python3 tools/pnglite.py scale   <in.png> <out.png> --size 32
  python3 tools/pnglite.py selftest
"""

import argparse
import struct
import sys
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"


class PngError(ValueError):
    pass


class Image:
    """An RGBA8 image: width, height and a bytearray of w*h*4 bytes."""

    def __init__(self, width, height, pixels=None):
        self.width = width
        self.height = height
        self.pixels = bytearray(pixels) if pixels is not None else bytearray(width * height * 4)

    def __repr__(self):
        return f"<Image {self.width}x{self.height}>"

    def rows(self, first, count):
        """A sub-image of `count` full rows starting at `first`."""
        start = first * self.width * 4
        end = (first + count) * self.width * 4
        return Image(self.width, count, self.pixels[start:end])

    def vstack(self, other):
        if other.width != self.width:
            raise PngError("cannot stack images of different width")
        out = Image(self.width, self.height + other.height)
        out.pixels[:len(self.pixels)] = self.pixels
        out.pixels[len(self.pixels):] = other.pixels
        return out

    def scale_box(self, new_w, new_h):
        """Box-filter downscale (averages every source block, alpha included).

        Averages are computed on premultiplied colours so transparent pixels do
        not bleed their colour into the result - the same way a texture would be
        filtered by the GPU's mipmaps.
        """
        if new_w <= 0 or new_h <= 0:
            raise PngError("target size must be positive")
        if new_w > self.width or new_h > self.height:
            raise PngError("box scaling only shrinks (asked %dx%d from %dx%d)"
                           % (new_w, new_h, self.width, self.height))
        out = Image(new_w, new_h)
        sx = self.width / new_w
        sy = self.height / new_h
        for y in range(new_h):
            y0, y1 = int(y * sy), max(int((y + 1) * sy), int(y * sy) + 1)
            for x in range(new_w):
                x0, x1 = int(x * sx), max(int((x + 1) * sx), int(x * sx) + 1)
                r = g = b = a = 0
                n = 0
                for yy in range(y0, min(y1, self.height)):
                    base = yy * self.width * 4
                    for xx in range(x0, min(x1, self.width)):
                        i = base + xx * 4
                        av = self.pixels[i + 3]
                        r += self.pixels[i] * av
                        g += self.pixels[i + 1] * av
                        b += self.pixels[i + 2] * av
                        a += av
                        n += 1
                o = (y * new_w + x) * 4
                if a:
                    out.pixels[o] = min(255, round(r / a))
                    out.pixels[o + 1] = min(255, round(g / a))
                    out.pixels[o + 2] = min(255, round(b / a))
                    out.pixels[o + 3] = min(255, round(a / n))
                else:
                    out.pixels[o + 3] = 0
        return out


def _chunks(data):
    pos = 8
    while pos + 8 <= len(data):
        length, kind = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + length]
        yield kind, body
        pos += 12 + length          # length + type + body + crc


def decode(data) -> Image:
    data = bytes(data)
    if not data.startswith(PNG_SIG):
        raise PngError("not a PNG")
    width = height = depth = colour = interlace = None
    palette = None
    trns = None
    idat = []
    for kind, body in _chunks(data):
        if kind == b"IHDR":
            width, height, depth, colour, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            palette = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    if width is None:
        raise PngError("no IHDR chunk")
    if interlace:
        raise PngError("interlaced PNGs are not supported")
    if depth != 8:
        raise PngError(f"only 8-bit PNGs are supported (got {depth}-bit)")
    if colour not in (0, 2, 3, 4, 6):
        raise PngError(f"unsupported colour type {colour}")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
    try:
        raw = zlib.decompress(b"".join(idat))
    except zlib.error as exc:
        raise PngError(f"corrupt image data: {exc}") from exc
    stride = width * channels
    if len(raw) != (stride + 1) * height:
        raise PngError("image data length does not match the header")

    # undo the per-row filters
    out = bytearray(stride * height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        filt = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filt == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filt == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filt == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filt == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif filt != 0:
            raise PngError(f"unknown row filter {filt}")
        out[y * stride:(y + 1) * stride] = line
        prev = line

    img = Image(width, height)
    px = img.pixels
    for i in range(width * height):
        s = i * channels
        o = i * 4
        if colour == 6:
            px[o:o + 4] = out[s:s + 4]
        elif colour == 2:
            px[o:o + 3] = out[s:s + 3]
            px[o + 3] = 255
        elif colour == 4:
            px[o] = px[o + 1] = px[o + 2] = out[s]
            px[o + 3] = out[s + 1]
        elif colour == 0:
            px[o] = px[o + 1] = px[o + 2] = out[s]
            px[o + 3] = 255
        else:                                   # palette
            idx = out[s]
            if palette is None or idx >= len(palette):
                raise PngError("palette index out of range")
            px[o], px[o + 1], px[o + 2] = palette[idx]
            px[o + 3] = trns[idx] if trns is not None and idx < len(trns) else 255
    return img


def encode(img: Image, level=9) -> bytes:
    """Encode an RGBA8 image as a PNG (colour type 6, no interlace)."""
    raw = bytearray()
    for y in range(img.height):
        raw.append(0)                            # filter: none
        raw += img.pixels[y * img.width * 4:(y + 1) * img.width * 4]

    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body +
                struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    return (PNG_SIG +
            chunk(b"IHDR", struct.pack(">IIBBBBB", img.width, img.height, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(bytes(raw), level)) +
            chunk(b"IEND", b""))


def keep_frames(img: Image, frame_height: int, factor: int) -> Image:
    """Keep every `factor`-th frame of a vertical animation strip."""
    if factor < 2:
        raise PngError("frame factor must be >= 2")
    frames = img.height // frame_height
    if frames * frame_height != img.height:
        raise PngError("strip height is not a multiple of the frame height")
    kept = [i for i in range(frames) if i % factor == 0]
    if len(kept) < 2:
        raise PngError("that would leave fewer than two frames")
    out = img.rows(kept[0] * frame_height, frame_height)
    for i in kept[1:]:
        out = out.vstack(img.rows(i * frame_height, frame_height))
    return out


def _selftest() -> int:
    # a small image with alpha so premultiplication is exercised
    img = Image(4, 2)
    img.pixels[0:4] = bytes((255, 0, 0, 255))
    img.pixels[4:8] = bytes((0, 255, 0, 128))
    img.pixels[8:12] = bytes((0, 0, 255, 0))
    img.pixels[12:16] = bytes((10, 20, 30, 255))
    img.pixels[16:20] = bytes((255, 255, 0, 255))
    img.pixels[20:24] = bytes((0, 255, 255, 255))
    img.pixels[24:28] = bytes((255, 0, 255, 128))
    img.pixels[28:32] = bytes((0, 0, 0, 0))

    blob = encode(img)
    back = decode(blob)
    if (back.width, back.height) != (4, 2) or bytes(back.pixels) != bytes(img.pixels):
        print("selftest: round-trip mismatch")
        return 1
    if decode(blob).pixels[3] != 255 or decode(blob).pixels[11] != 0:
        print("selftest: alpha lost")
        return 1

    # palette + tRNS must decode like the client's decoder does
    pal = bytearray()
    pal += struct.pack(">I", 13) + b"IHDR" + struct.pack(">IIBBBBB", 2, 1, 8, 3, 0, 0, 0) + b"\x00\x00\x00\x00"
    plte = bytes((255, 0, 0, 0, 255, 0, 0, 0, 255))
    pal += struct.pack(">I", len(plte)) + b"PLTE" + plte + b"\x00\x00\x00\x00"
    trns = bytes((255, 128))
    pal += struct.pack(">I", len(trns)) + b"tRNS" + trns + b"\x00\x00\x00\x00"
    idat = zlib.compress(bytes((0, 0, 1)))       # row filter 0, indices 0 and 1
    pal += struct.pack(">I", len(idat)) + b"IDAT" + idat + b"\x00\x00\x00\x00"
    pal += struct.pack(">I", 0) + b"IEND" + b"\x00\x00\x00\x00"
    pimg = decode(PNG_SIG + bytes(pal))
    if bytes(pimg.pixels) != bytes((255, 0, 0, 255, 0, 255, 0, 128)):
        print("selftest: palette/tRNS decode wrong:", list(pimg.pixels))
        return 1

    # box downscale of a solid colour must keep the colour and the alpha
    solid = Image(8, 8, bytes((40, 80, 120, 200)) * 64)
    small = solid.scale_box(2, 2)
    if bytes(small.pixels) != bytes((40, 80, 120, 200)) * 4:
        print("selftest: box scale changed a solid colour")
        return 1
    # and a transparent half must end up with ~half the alpha, not half the colour
    half = Image(4, 1)
    for x in range(4):
        o = x * 4
        half.pixels[o:o + 4] = bytes((255, 255, 255, 255 if x < 2 else 0))
    scaled = half.scale_box(2, 1)
    if bytes(scaled.pixels[0:4]) != bytes((255, 255, 255, 255)):
        print("selftest: opaque block did not stay opaque:", list(scaled.pixels))
        return 1
    blended = half.scale_box(1, 1)
    if blended.pixels[0] != 255 or not 120 <= blended.pixels[3] <= 135:
        print("selftest: alpha-aware scaling wrong:", list(blended.pixels))
        return 1

    # frame stripping: keep every 2nd frame of a 4-frame strip
    strip = Image(2, 8)
    for f in range(4):
        for y in range(2):
            for x in range(2):
                o = ((f * 2 + y) * 2 + x) * 4
                strip.pixels[o:o + 4] = bytes((f * 10, 0, 0, 255))
    kept = keep_frames(strip, 2, 2)
    if (kept.width, kept.height) != (2, 4) or bytes(kept.pixels[0:4]) != bytes((0, 0, 0, 255)) \
            or bytes(kept.pixels[16:20]) != bytes((20, 0, 0, 255)):
        print("selftest: keep_frames wrong")
        return 1
    print("selftest: OK (round-trip, palette+tRNS, alpha-aware box scale, frame strip)")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="small PNG reader/writer for the client optimiser")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info")
    p.add_argument("png")
    p = sub.add_parser("scale")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--size", type=int, required=True)
    sub.add_parser("selftest")
    args = ap.parse_args(argv)

    if args.cmd == "selftest":
        return _selftest()
    if args.cmd == "info":
        img = decode(open(args.png, "rb").read())
        print(f"{args.png}: {img.width}x{img.height}, {len(img.pixels)} bytes RGBA")
        return 0
    if args.cmd == "scale":
        img = decode(open(args.input, "rb").read())
        out = img.scale_box(args.size, args.size)
        with open(args.output, "wb") as fh:
            fh.write(encode(out))
        print(f"{args.input}: {img.width}x{img.height} -> {args.size}x{args.size}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
