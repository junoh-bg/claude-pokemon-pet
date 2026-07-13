import os, struct, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import petgif


def build_gif(frames, w=2, h=2, palette=((0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255)),
              transparent=None, disposal=1, delay_cs=20, interlace=False, lct=None):
    """Build a minimal GIF89a: each frame is a full-canvas list of palette indices.
    disposal may be an int (all frames) or a per-frame list. interlace stores
    rows in interlaced pass order. lct (list of 4 rgb tuples) adds a local
    color table to every frame."""
    out = bytearray(b"GIF89a")
    out += struct.pack("<HH", w, h)
    out += bytes([0x80 | 0x01, 0, 0])          # GCT flag, 2-bit → 4 entries
    for r, g, b in palette:
        out += bytes([r, g, b])
    for fi, idx_data in enumerate(frames):
        disp = disposal[fi] if isinstance(disposal, (list, tuple)) else disposal
        out += b"\x21\xf9\x04"                  # GCE
        flags = (disp << 2) | (1 if transparent is not None else 0)
        out += bytes([flags]) + struct.pack("<H", delay_cs)
        out += bytes([transparent if transparent is not None else 0, 0])
        iflags = (0x40 if interlace else 0) | (0x80 | 0x01 if lct else 0)
        out += b"\x2c" + struct.pack("<HHHH", 0, 0, w, h) + bytes([iflags])
        if lct:
            for r, g, b in lct:
                out += bytes([r, g, b])
        if interlace:                           # store rows in pass order
            rows = [idx_data[i * w:(i + 1) * w] for i in range(h)]
            order = list(range(0, h, 8)) + list(range(4, h, 8)) + \
                    list(range(2, h, 4)) + list(range(1, h, 2))
            idx_data = [px for r_i in order for px in rows[r_i]]
        out += bytes([2])                       # LZW min code size
        out += lzw_encode(idx_data, 2)
        out += b"\x00"                          # block terminator
    out += b"\x3b"
    return bytes(out)


def lzw_encode(indices, min_code):
    """Tiny LZW encoder (clear code before every symbol — valid, inefficient)."""
    clear, eoi = 1 << min_code, (1 << min_code) + 1
    codes, size = [], min_code + 1
    for i in indices:
        codes += [clear, i]
    codes.append(eoi)
    bitbuf = nbits = 0
    outb = bytearray()
    for c in codes:
        bitbuf |= c << nbits
        nbits += size
        while nbits >= 8:
            outb.append(bitbuf & 0xFF)
            bitbuf >>= 8
            nbits -= 8
    if nbits:
        outb.append(bitbuf & 0xFF)
    chunks = bytearray()
    for i in range(0, len(outb), 255):
        part = outb[i:i + 255]
        chunks += bytes([len(part)]) + part
    return bytes(chunks)


class TestDecode(unittest.TestCase):
    def test_single_frame_colors(self):
        anim = petgif.decode(build_gif([[0, 1, 2, 3]]))
        self.assertEqual((anim.width, anim.height), (2, 2))
        self.assertEqual(len(anim.frames), 1)
        f = anim.frames[0].rgba
        self.assertEqual(f[0:4], bytes([0, 0, 0, 255]))        # idx 0 black
        self.assertEqual(f[4:8], bytes([255, 0, 0, 255]))      # idx 1 red
        self.assertEqual(anim.frames[0].delay_ms, 200)

    def test_transparency_alpha_zero(self):
        anim = petgif.decode(build_gif([[1, 1, 3, 3]], transparent=3))
        f = anim.frames[0].rgba
        self.assertEqual(f[3], 255)
        self.assertEqual(f[11], 0)                              # idx 3 transparent

    def test_disposal_keep_composites(self):
        # frame2 paints transparent everywhere except one pixel: disposal 1 keeps frame1 under it
        anim = petgif.decode(build_gif([[1, 1, 1, 1], [3, 2, 3, 3]], transparent=3, disposal=1))
        f2 = anim.frames[1].rgba
        self.assertEqual(f2[0:4], bytes([255, 0, 0, 255]))      # kept from frame 1
        self.assertEqual(f2[4:8], bytes([0, 255, 0, 255]))      # newly painted green

    def test_disposal_background_clears(self):
        anim = petgif.decode(build_gif([[1, 1, 1, 1], [3, 2, 3, 3]], transparent=3, disposal=2))
        f2 = anim.frames[1].rgba
        self.assertEqual(f2[3], 0)                              # cleared to transparent
        self.assertEqual(f2[4:8], bytes([0, 255, 0, 255]))

    def test_zero_delay_defaults_100ms(self):
        anim = petgif.decode(build_gif([[0, 0, 0, 0]], delay_cs=0))
        self.assertEqual(anim.frames[0].delay_ms, 100)

    def test_mirror(self):
        anim = petgif.decode(build_gif([[1, 2, 3, 0]]))
        m = petgif.mirror(anim.frames[0].rgba, 2, 2)
        self.assertEqual(m[0:4], bytes([0, 255, 0, 255]))       # green now left
        self.assertEqual(m[4:8], bytes([255, 0, 0, 255]))

    def test_truncated_raises_valueerror(self):
        g = build_gif([[0, 1, 2, 3]])
        for cut in (8, 10, len(g) - 2):
            with self.assertRaises(ValueError, msg="cut=%d" % cut):
                petgif.decode(g[:cut])
        with self.assertRaises(ValueError):
            petgif.decode(b"not a gif at all")

    def test_disposal_restore_previous(self):
        # frame2 has disposal 3: after it, the canvas reverts to frame1's
        # state, so an all-transparent frame3 shows frame1 again
        anim = petgif.decode(build_gif([[1, 1, 1, 1], [2, 2, 2, 2], [3, 3, 3, 3]],
                                       transparent=3, disposal=[1, 3, 1]))
        self.assertEqual(anim.frames[1].rgba[0:4], bytes([0, 255, 0, 255]))  # green shown
        self.assertEqual(anim.frames[2].rgba[0:4], bytes([255, 0, 0, 255]))  # back to red

    def test_interlaced_rows_reordered(self):
        # 2x4, each row a distinct color, stored interlaced: decoder must
        # return them in natural top-to-bottom order
        idx = [0, 0, 1, 1, 2, 2, 3, 3]
        anim = petgif.decode(build_gif([idx], w=2, h=4, interlace=True))
        f = anim.frames[0].rgba
        self.assertEqual(f[0:4], bytes([0, 0, 0, 255]))          # row0 black
        self.assertEqual(f[8:12], bytes([255, 0, 0, 255]))       # row1 red
        self.assertEqual(f[16:20], bytes([0, 255, 0, 255]))      # row2 green
        self.assertEqual(f[24:28], bytes([0, 0, 255, 255]))      # row3 blue

    def test_local_color_table_wins(self):
        lct = ((255, 255, 255), (9, 9, 9), (7, 7, 7), (1, 1, 1))
        anim = petgif.decode(build_gif([[1, 1, 1, 1]], lct=lct))
        self.assertEqual(anim.frames[0].rgba[0:4], bytes([9, 9, 9, 255]))

    def test_real_sprite_if_cached(self):
        p = os.path.expanduser("~/.cache/claude-pokemon-pet/sprites/charmander.gif")
        if not os.path.exists(p):
            self.skipTest("sprite cache absent")
        with open(p, "rb") as fh:
            anim = petgif.decode(fh.read())
        self.assertGreater(len(anim.frames), 10)
        self.assertEqual(len(anim.frames[0].rgba), anim.width * anim.height * 4)
        self.assertTrue(any(px == 0 for px in anim.frames[0].rgba[3::4]))  # has transparency


if __name__ == "__main__":
    unittest.main()
