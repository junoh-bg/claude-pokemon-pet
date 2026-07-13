"""Pure-stdlib GIF89a decoder for claude-pokemon-pet's terminal renderer.

decode(data) -> Anim(width, height, frames[Frame(rgba, delay_ms)])
Frames are composited onto the full canvas (sub-rectangles, disposal
methods 0-3, transparency -> alpha 0). mirror() flips a frame horizontally.
"""
from collections import namedtuple
import struct

Anim = namedtuple("Anim", "width height frames")
Frame = namedtuple("Frame", "rgba delay_ms")


def _lzw_decode(min_code_size, data):
    clear, eoi = 1 << min_code_size, (1 << min_code_size) + 1
    out = bytearray()

    def reset():
        return {i: bytes([i]) for i in range(clear)}, min_code_size + 1

    table, size = reset()
    prev = None
    bitbuf = nbits = pos = 0
    while True:
        while nbits < size:
            if pos >= len(data):
                return bytes(out)
            bitbuf |= data[pos] << nbits
            nbits += 8
            pos += 1
        code = bitbuf & ((1 << size) - 1)
        bitbuf >>= size
        nbits -= size
        if code == clear:
            table, size = reset()
            prev = None
            continue
        if code == eoi:
            return bytes(out)
        if prev is None:
            entry = table[code]
        elif code in table:
            entry = table[code]
            table[len(table) + 2] = prev + entry[:1]
        else:
            entry = prev + prev[:1]
            table[len(table) + 2] = entry
        out += entry
        if len(table) + 2 >= (1 << size) and size < 12:
            size += 1
        prev = entry


def _blocks(data, pos):
    chunks = bytearray()
    while True:
        n = data[pos]
        pos += 1
        if n == 0:
            return bytes(chunks), pos
        chunks += data[pos:pos + n]
        pos += n


def _deinterlace(indices, w, h):
    rows = [indices[i * w:(i + 1) * w] for i in range(h)]
    order = list(range(0, h, 8)) + list(range(4, h, 8)) + \
            list(range(2, h, 4)) + list(range(1, h, 2))
    fixed = [None] * h
    for src, dst in enumerate(order):
        fixed[dst] = rows[src]
    return b"".join(fixed)


def decode(data):
    if data[:6] not in (b"GIF89a", b"GIF87a"):
        raise ValueError("not a GIF")
    w, h = struct.unpack("<HH", data[6:10])
    flags = data[10]
    pos = 13
    gct = None
    if flags & 0x80:
        n = 2 << (flags & 7)
        gct = data[pos:pos + 3 * n]
        pos += 3 * n

    canvas = bytearray(w * h * 4)          # starts fully transparent
    frames = []
    delay_ms, transparent, disposal = 100, None, 0

    while pos < len(data):
        b = data[pos]
        pos += 1
        if b == 0x3B:                       # trailer
            break
        if b == 0x21:                       # extension
            label = data[pos]
            pos += 1
            if label == 0xF9:               # graphic control
                blk, pos = _blocks(data, pos)
                gflags = blk[0]
                disposal = (gflags >> 2) & 7
                d = struct.unpack("<H", blk[1:3])[0] * 10
                delay_ms = d if d > 0 else 100
                transparent = blk[3] if gflags & 1 else None
            else:                           # comment/app/plaintext: skip
                _, pos = _blocks(data, pos)
            continue
        if b != 0x2C:                       # image descriptor expected
            raise ValueError("bad GIF block 0x%02x" % b)
        x, y, fw, fh = struct.unpack("<HHHH", data[pos:pos + 8])
        iflags = data[pos + 8]
        pos += 9
        lct = None
        if iflags & 0x80:
            n = 2 << (iflags & 7)
            lct = data[pos:pos + 3 * n]
            pos += 3 * n
        palette = lct or gct
        min_code = data[pos]
        pos += 1
        raw, pos = _blocks(data, pos)
        indices = _lzw_decode(min_code, raw)[:fw * fh]
        if iflags & 0x40:
            indices = _deinterlace(indices, fw, fh)

        saved = bytes(canvas) if disposal == 3 else None
        for row in range(fh):
            cy = y + row
            if cy >= h:
                break
            for col in range(fw):
                cx = x + col
                if cx >= w:
                    continue
                idx = indices[row * fw + col]
                if transparent is not None and idx == transparent:
                    continue
                o = (cy * w + cx) * 4
                p = idx * 3
                canvas[o:o + 4] = bytes([palette[p], palette[p + 1], palette[p + 2], 255])

        frames.append(Frame(bytes(canvas), delay_ms))

        if disposal == 2:                   # restore to background = transparent
            span = min(fw, w - x)
            for row in range(fh):
                cy = y + row
                if cy >= h:
                    break
                o = (cy * w + x) * 4
                canvas[o:o + 4 * span] = b"\x00" * (4 * span)
        elif disposal == 3 and saved is not None:
            canvas = bytearray(saved)
        disposal, transparent, delay_ms = 0, None, 100

    if not frames:
        raise ValueError("GIF has no frames")
    return Anim(w, h, frames)


def mirror(rgba, width, height):
    out = bytearray(len(rgba))
    for row in range(height):
        base = row * width * 4
        for col in range(width):
            src = base + col * 4
            dst = base + (width - 1 - col) * 4
            out[dst:dst + 4] = rgba[src:src + 4]
    return bytes(out)
