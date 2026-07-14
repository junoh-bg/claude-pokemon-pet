"""Pure-stdlib PNG toolkit for claude-pokemon-pet's colorful sprites.

decode(data) -> (rgba: bytes, width, height) — 8-bit color types 2 (RGB,
alpha synthesized) and 6 (RGBA), non-interlaced; anything else or malformed
raises ValueError (callers rely on catching ValueError, like petgif).

floodfill_whitekey() keys out ONLY near-white connected to the image border
— interior whites (Angemon's wings, Patamon's belly) survive. Never use a
global chroma key for sprite backgrounds (see CLAUDE.md).
"""
import struct
import zlib


def decode(data):
    try:
        return _decode(data)
    except (IndexError, struct.error, zlib.error) as e:
        raise ValueError("malformed PNG: %s" % e)


def _decode(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    w = h = None
    depth = ctype = interlace = None
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if len(body) < length:
            raise ValueError("truncated chunk")
        pos += 12 + length
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
    if w is None or not idat:
        raise ValueError("missing IHDR/IDAT")
    if depth != 8 or ctype not in (2, 6) or interlace != 0:
        raise ValueError("unsupported PNG (need 8-bit RGB/RGBA, non-interlaced)")
    nch = 3 if ctype == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = w * nch
    if len(raw) < h * (stride + 1):
        raise ValueError("short pixel data")

    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    for y in range(h):
        off = y * (stride + 1)
        f = raw[off]
        line = bytearray(raw[off + 1:off + 1 + stride])
        if f == 1:      # Sub
            for i in range(nch, stride):
                line[i] = (line[i] + line[i - nch]) & 0xFF
        elif f == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:    # Average
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:    # Paeth
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                b = prev[i]
                c = prev[i - nch] if i >= nch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif f != 0:
            raise ValueError("bad filter %d" % f)
        prev = line
        o = y * w * 4
        if nch == 4:
            out[o:o + stride] = line
        else:
            for x in range(w):
                out[o + x * 4:o + x * 4 + 3] = line[x * 3:x * 3 + 3]
                out[o + x * 4 + 3] = 255
    return bytes(out), w, h


def encode(rgba, w, h):
    raw = b"".join(b"\x00" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))

    def chunk(tag, d):
        c = tag + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def floodfill_whitekey(rgba, w, h, thresh=235):
    """Alpha-zero every near-white pixel CONNECTED TO THE BORDER.

    Threshold 235 also swallows the anti-aliased fringe between the art and
    the white background; interior whites are safe regardless because the
    fill can't cross non-white outline pixels."""
    out = bytearray(rgba)

    def is_bg(i):
        o = i * 4
        return (out[o] >= thresh and out[o + 1] >= thresh
                and out[o + 2] >= thresh and out[o + 3] == 255)

    seen = bytearray(w * h)
    stack = []
    for x in range(w):
        stack.append(x)
        stack.append((h - 1) * w + x)
    for y in range(h):
        stack.append(y * w)
        stack.append(y * w + w - 1)
    while stack:
        i = stack.pop()
        if seen[i] or not is_bg(i):
            seen[i] = 1
            continue
        seen[i] = 1
        out[i * 4 + 3] = 0
        x, y = i % w, i // w
        if x > 0:
            stack.append(i - 1)
        if x < w - 1:
            stack.append(i + 1)
        if y > 0:
            stack.append(i - w)
        if y < h - 1:
            stack.append(i + w)
    return bytes(out)


def resize_nearest(rgba, w, h, tw, th):
    out = bytearray(tw * th * 4)
    for y in range(th):
        sy = y * h // th
        for x in range(tw):
            sx = x * w // tw
            so = (sy * w + sx) * 4
            do = (y * tw + x) * 4
            out[do:do + 4] = rgba[so:so + 4]
    return bytes(out)


def mirror(rgba, w, h):
    out = bytearray(len(rgba))
    for y in range(h):
        base = y * w * 4
        for x in range(w):
            out[base + (w - 1 - x) * 4:base + (w - x) * 4] = rgba[base + x * 4:base + x * 4 + 4]
    return bytes(out)
