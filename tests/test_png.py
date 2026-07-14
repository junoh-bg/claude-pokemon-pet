import os, struct, sys, unittest, zlib

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import petpng


def rgba_rows(px):
    """Build RGBA bytes from a list-of-rows of (r,g,b,a)."""
    return bytes(v for row in px for p in row for v in p)


class TestPng(unittest.TestCase):
    def test_roundtrip_rgba(self):
        rgba = rgba_rows([[(255, 0, 0, 255), (0, 255, 0, 128)],
                          [(0, 0, 255, 255), (255, 255, 255, 255)]])
        data = petpng.encode(rgba, 2, 2)
        out, w, h = petpng.decode(data)
        self.assertEqual((w, h), (2, 2))
        self.assertEqual(out, rgba)

    def test_decode_rgb_no_alpha(self):
        # craft an RGB (color type 2) PNG by hand — digi-api's actual format
        raw = b"".join(b"\x00" + bytes([255, 255, 255, 200, 10, 10]) for _ in range(2))
        def chunk(tag, d):
            c = tag + d
            return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
        data = (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
        out, w, h = petpng.decode(data)
        self.assertEqual((w, h), (2, 2))
        self.assertEqual(out[0:4], bytes([255, 255, 255, 255]))   # alpha synthesized
        self.assertEqual(out[4:8], bytes([200, 10, 10, 255]))

    def test_floodfill_keeps_interior_white(self):
        # 5x5: white border ring, red ring, white CENTER — center must survive
        W, R = (255, 255, 255, 255), (200, 10, 10, 255)
        rows = [[W, W, W, W, W],
                [W, R, R, R, W],
                [W, R, W, R, W],
                [W, R, R, R, W],
                [W, W, W, W, W]]
        out = petpng.floodfill_whitekey(rgba_rows(rows), 5, 5)
        self.assertEqual(out[3], 0)                      # border white keyed
        center = (2 * 5 + 2) * 4
        self.assertEqual(out[center + 3], 255)           # interior white KEPT
        self.assertEqual(out[(1 * 5 + 1) * 4 + 3], 255)  # red untouched

    def test_resize_and_mirror(self):
        rgba = rgba_rows([[(255, 0, 0, 255), (0, 255, 0, 255)]])
        big = petpng.resize_nearest(rgba, 2, 1, 4, 2)
        self.assertEqual(big[0:4], bytes([255, 0, 0, 255]))
        self.assertEqual(big[8:12], bytes([0, 255, 0, 255]))
        self.assertEqual(len(big), 4 * 2 * 4)
        m = petpng.mirror(rgba, 2, 1)
        self.assertEqual(m[0:4], bytes([0, 255, 0, 255]))

    def test_truncated_raises(self):
        with self.assertRaises(ValueError):
            petpng.decode(b"\x89PNG\r\n\x1a\nnope")
        with self.assertRaises(ValueError):
            petpng.decode(b"not a png at all")


if __name__ == "__main__":
    unittest.main()
