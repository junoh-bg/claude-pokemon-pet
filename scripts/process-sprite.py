#!/usr/bin/env python3
"""process-sprite.py IN.png OUT.png OUT_FLIP.png TARGET_PX

Install-time sprite processing for PNG franchise packs: border flood-fill
white-keying (interior whites survive) + nearest-neighbor scale to TARGET_PX
(max dimension) + a mirrored flip variant. Exits non-zero on any failure so
get-sprites.sh can report it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import petpng


def main(argv):
    if len(argv) != 5:
        sys.stderr.write(__doc__)
        return 2
    src, dst, dst_flip, target = argv[1], argv[2], argv[3], int(argv[4])
    with open(src, "rb") as fh:
        rgba, w, h = petpng.decode(fh.read())
    rgba = petpng.floodfill_whitekey(rgba, w, h)
    scale = target / max(w, h)
    tw, th = max(1, round(w * scale)), max(1, round(h * scale))
    rgba = petpng.resize_nearest(rgba, w, h, tw, th)
    with open(dst, "wb") as fh:
        fh.write(petpng.encode(rgba, tw, th))
    with open(dst_flip, "wb") as fh:
        fh.write(petpng.encode(petpng.mirror(rgba, tw, th), tw, th))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:
        sys.stderr.write("process-sprite: %s\n" % e)
        sys.exit(1)
