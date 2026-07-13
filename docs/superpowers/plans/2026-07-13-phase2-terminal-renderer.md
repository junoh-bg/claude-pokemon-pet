# Phase 2: Terminal Renderer + Statusline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-stdlib Python terminal renderer (`claude-pokemon-pet term`) that draws the animated pet inside any terminal — kitty/WezTerm/Ghostty graphics, iTerm2 inline images, or ANSI half-blocks — plus a one-line statusline script; together they ship Linux/SSH/RunPod support.

**Architecture:** Renderers stay pure views of `resolved.json` (Phase 1 contract, date-stamped). `pet-term.py` polls it at 1 Hz, animates GIF frames decoded by a small pure-Python GIF decoder (`petgif.py`), and kicks `pet-core.sh resolve` (≤1/min) when the date stamp is stale. `pet-statusline.sh` renders the same file as one line for Claude Code's statusline.

**Tech Stack:** Python ≥3.8 stdlib only (zlib not even needed — GIF is LZW); bash 3.2 + jq for the statusline; existing bash test harness wrapping `python3 -m unittest`.

## Global Constraints

- **Python ≥3.8, stdlib only** — no pip installs ever; no walrus-dependent syntax beyond 3.8, no `match`.
- **bash 3.2** for all shell (macOS `/bin/bash`); GNU/BSD portability now matters (Linux!): `stat -f %m || stat -c %Y`, `date -v-1d || date -d yesterday`.
- Renderers contain **zero game logic** — they read `resolved.json`; staleness → subprocess `pet-core.sh resolve`, never compute levels locally. Mood decay by age (45 s done/hello, 600 s active) and caption templates are presentation and live in each renderer (same as the overlay).
- Runtime writes only under `~/.cache/claude-pokemon-pet/`.
- Statusline script must be fast (pure jq read; re-resolve only when the date stamp is stale) and must never exit non-zero.
- Terminal mode must work **without gifsicle and without osascript** (Linux boxes); it uses the small originals in `$CACHE/sprites/`, mirroring frames in Python.
- Tests: `bash tests/run.sh` green before every commit; Python tests hermetic (synthetic GIFs built in-test; real-sprite tests skip when cache absent; no host locale/size dependence).
- Real sprite facts (verified): GIF89a, ~41×42 logical screen, 16-color global palette, per-frame sub-rectangles with offsets, transparency index set, disposal "do not dispose" (1), delays ~0.20 s, ~55 frames.
- Conventional commits, colon separator.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `scripts/petgif.py` | create | pure-stdlib GIF89a decoder → RGBA frames + delays; `mirror()` |
| `scripts/pet-term.py` | create | terminal renderer: backend pick, ANSI/kitty/iTerm2 drawing, UI loop, staleness kick |
| `scripts/pet-statusline.sh` | create | one-line statusline formatter (bash+jq) |
| `scripts/claude-pokemon-pet` | modify | `term` + `statusline` subcommands; per-mode dep checks; portable `stat` |
| `scripts/get-sprites.sh` | modify | works without gifsicle (skips upscale step with a note) |
| `tests/test_gif.py` | create | decoder unit tests (synthetic GIF + real-sprite smoke) |
| `tests/test_term.py` | create | backend pick, half-blocks, EXP bar, captions, escape sequences |
| `tests/test-python.sh` | create | harness wrapper: runs both Python test modules |
| `tests/test-statusline.sh` | create | statusline output + staleness behavior |
| `README.md`, `.claude-plugin/plugin.json` | modify | terminal/statusline docs; keywords + version 0.5.0 |

---

### Task 1: Pure-Python GIF decoder (`petgif.py`)

**Files:**
- Create: `scripts/petgif.py`
- Create: `tests/test_gif.py`, `tests/test-python.sh`

**Interfaces:**
- Produces (used by Task 2/3):
  - `petgif.decode(data: bytes) -> Anim` — `Anim = namedtuple("Anim", "width height frames")`, `frames: list[Frame]`, `Frame = namedtuple("Frame", "rgba delay_ms")`, `rgba: bytes` of length `width*height*4`, full-canvas composited (sub-rectangles, disposal 0/1/2/3, transparency → alpha 0). `delay_ms` defaults to 100 when the GIF says 0.
  - `petgif.mirror(rgba: bytes, width: int, height: int) -> bytes` — horizontal flip.

- [ ] **Step 1: Write the failing tests.** `tests/test_gif.py`:

```python
import os, struct, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import petgif


def build_gif(frames, w=2, h=2, palette=((0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255)),
              transparent=None, disposal=1, delay_cs=20):
    """Build a minimal GIF89a: each frame is a full-canvas list of palette indices."""
    out = bytearray(b"GIF89a")
    out += struct.pack("<HH", w, h)
    out += bytes([0x80 | 0x01, 0, 0])          # GCT flag, 2-bit → 4 entries
    for r, g, b in palette:
        out += bytes([r, g, b])
    for idx_data in frames:
        out += b"\x21\xf9\x04"                  # GCE
        flags = (disposal << 2) | (1 if transparent is not None else 0)
        out += bytes([flags]) + struct.pack("<H", delay_cs)
        out += bytes([transparent if transparent is not None else 0, 0])
        out += b"\x2c" + struct.pack("<HHHH", 0, 0, w, h) + b"\x00"   # image desc, no LCT
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
    bits = bitbuf = nbits = 0
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
```

`tests/test-python.sh`:

```bash
#!/bin/bash
# Harness wrapper for the Python unit tests (skips cleanly if python3 absent).
cd "$(dirname "$0")" || exit 1
command -v python3 >/dev/null || { echo "-- test-python.sh: SKIP (no python3)"; exit 0; }
rc=0
for m in test_gif test_term; do
    [ -f "$m.py" ] || continue
    python3 -m unittest -q "$m" || rc=1
done
echo "-- test-python.sh: $([ $rc -eq 0 ] && echo 'pass' || echo 'FAIL')"
exit $rc
```

- [ ] **Step 2: Run to verify failure.** `bash tests/run.sh` → test-python fails with `ModuleNotFoundError: petgif`.

- [ ] **Step 3: Implement `scripts/petgif.py`:**

```python
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
    table, size = None, 0

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
            for row in range(fh):
                cy = y + row
                if cy >= h:
                    break
                o = (cy * w + x) * 4
                canvas[o:o + 4 * min(fw, w - x)] = b"\x00" * 4 * min(fw, w - x)
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
```

- [ ] **Step 4: Run tests.** `bash tests/run.sh` → `test-python.sh: pass` (7 tests, real-sprite one may skip on bare machines) and all Phase 1 suites still green.

- [ ] **Step 5: Commit.** `git add scripts/petgif.py tests/test_gif.py tests/test-python.sh && git commit -m "feat: pure-stdlib GIF decoder for terminal rendering"`

---

### Task 2: Terminal renderer — pure functions + ANSI backend + UI loop

**Files:**
- Create: `scripts/pet-term.py`
- Create: `tests/test_term.py`

**Interfaces:**
- Consumes: `petgif.decode/mirror` (Task 1); `resolved.json` fields `date species name type stage stages final tasks mistakes streak exp_pct exp_gold moves lang state state_ts` (Phase 1).
- Produces (Task 3 extends, tests import):
  - `pick_backend(env: dict) -> str` — `"kitty" | "iterm" | "ansi"`.
  - `halfblocks(rgba: bytes, w: int, h: int, max_cols: int, truecolor: bool) -> list[str]` — ANSI lines, `▀` glyphs, transparent-aware.
  - `exp_bar(pct: int, gold: bool, width: int = 10) -> str` — `▰▱` with SGR color.
  - `caption(r: dict, now: float) -> tuple[str, str]` — `(state_after_decay, mood_line)`; ports the overlay's decay + en/ko templates incl. `josa`.
  - `load_resolved(cache: str) -> dict | None`; `maybe_kick(root: str, r: dict, last_kick: float, now: float) -> float`.
  - `main(argv)` — alt-screen loop, SIGINT/SIGTERM-safe restore.

- [ ] **Step 1: Write the failing tests.** `tests/test_term.py`:

```python
import importlib.util, json, os, sys, time, unittest

spec = importlib.util.spec_from_file_location(
    "pet_term", os.path.join(os.path.dirname(__file__), "..", "scripts", "pet-term.py"))
pet_term = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pet_term)

R = {"date": "2026-07-13", "species": "charmeleon", "name": "CHARMELEON",
     "type": "fire", "stage": 2, "stages": 3, "final": False, "tasks": 7,
     "mistakes": 1, "streak": 3, "shiny": False, "exp_pct": 10, "exp_gold": False,
     "line": ["charmander", "charmeleon", "charizard"],
     "moves": ["EMBER", "FLAMETHROWER", "FIRE BLAST"],
     "lang": "en", "state": "working", "state_ts": 1789300000}


class TestBackend(unittest.TestCase):
    def test_kitty_by_env(self):
        self.assertEqual(pet_term.pick_backend({"KITTY_WINDOW_ID": "1"}), "kitty")
        self.assertEqual(pet_term.pick_backend({"TERM": "xterm-kitty"}), "kitty")
        self.assertEqual(pet_term.pick_backend({"TERM_PROGRAM": "WezTerm"}), "kitty")
        self.assertEqual(pet_term.pick_backend({"TERM_PROGRAM": "ghostty"}), "kitty")

    def test_iterm(self):
        self.assertEqual(pet_term.pick_backend({"TERM_PROGRAM": "iTerm.app"}), "iterm")

    def test_default_and_tmux_force_ansi(self):
        self.assertEqual(pet_term.pick_backend({"TERM": "xterm-256color"}), "ansi")
        self.assertEqual(pet_term.pick_backend({"TMUX": "/x", "KITTY_WINDOW_ID": "1"}), "ansi")

    def test_explicit_override_wins(self):
        self.assertEqual(pet_term.pick_backend({"PET_TERM_MODE": "kitty", "TMUX": "/x"}), "kitty")


class TestDrawing(unittest.TestCase):
    def test_halfblocks_shape_and_transparency(self):
        # 2x2: red over transparent -> one column, one line, top fg red, bottom default bg
        rgba = bytes([255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 255])
        lines = pet_term.halfblocks(rgba, 2, 2, max_cols=10, truecolor=True)
        self.assertEqual(len(lines), 1)
        self.assertIn("38;2;255;0;0", lines[0])
        self.assertIn("▀", lines[0])

    def test_halfblocks_downscales(self):
        rgba = bytes([10, 20, 30, 255]) * (100 * 10)
        lines = pet_term.halfblocks(rgba, 100, 10, max_cols=20, truecolor=True)
        self.assertLessEqual(max(pet_term.visible_len(l) for l in lines), 20)

    def test_exp_bar(self):
        bar = pet_term.exp_bar(50, False, width=10)
        self.assertEqual(bar.count("▰"), 5)
        self.assertEqual(bar.count("▱"), 5)
        self.assertIn("38;5;220", pet_term.exp_bar(0, True, width=10))


class TestCaption(unittest.TestCase):
    def test_working_caption_uses_move(self):
        st, line = pet_term.caption(dict(R), now=1789300005)
        self.assertEqual(st, "working")
        self.assertTrue(line.startswith("CHARMELEON used "))

    def test_decay_to_idle(self):
        st, line = pet_term.caption(dict(R, state="done"), now=1789300000 + 46)
        self.assertEqual(st, "idle")
        self.assertIn("asleep", line)

    def test_korean_josa(self):
        r = dict(R, lang="ko", name="리자드", state="waiting")
        st, line = pet_term.caption(r, now=1789300005)
        self.assertIn("리자드는", line)


class TestResolved(unittest.TestCase):
    def test_load_missing_returns_none(self):
        self.assertIsNone(pet_term.load_resolved("/nonexistent-dir-xyz"))

    def test_stale_kick_rate_limited(self):
        r = dict(R, date="2020-01-01")
        calls = []
        pet_term.KICK = lambda root: calls.append(root)
        now = time.time()
        last = pet_term.maybe_kick("/root", r, last_kick=0, now=now)
        self.assertEqual(len(calls), 1)
        last2 = pet_term.maybe_kick("/root", r, last_kick=last, now=now + 5)
        self.assertEqual(len(calls), 1)          # rate-limited
        self.assertEqual(last2, last)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify failure.** `bash tests/run.sh` → test-python FAIL (no pet-term.py).

- [ ] **Step 3: Implement `scripts/pet-term.py`:**

```python
#!/usr/bin/env python3
"""claude-pokemon-pet terminal renderer — a pure view of resolved.json.

Runs in any terminal (tmux split, SSH session, RunPod pod): decodes the
cached sprite GIF with petgif, draws it via the best available backend
(kitty graphics / iTerm2 inline images / ANSI half-blocks), and shows the
same battle-log captions and EXP bar as the macOS overlay. All game state
comes from resolved.json (written by pet-core.sh); when its date stamp is
stale this only *asks* the core to re-resolve — no game logic here.

Usage: pet-term.py [plugin-root]    (Ctrl-C to quit)
Env: PET_TERM_MODE=kitty|iterm|ansi forces a backend.
"""
import base64, json, math, os, signal, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import petgif

CACHE = os.path.expanduser("~/.cache/claude-pokemon-pet")
ESC = "\x1b"
MAX_COLS = 36        # sprite width budget in cells
TICK = 0.2           # animation tick (matches sprite frame delays)


# ── backend selection ──────────────────────────────────────────────
def pick_backend(env):
    mode = env.get("PET_TERM_MODE", "")
    if mode in ("kitty", "iterm", "ansi"):
        return mode
    if "TMUX" in env:
        return "ansi"    # graphics need passthrough config; half-blocks always work
    if env.get("KITTY_WINDOW_ID") or env.get("TERM", "").startswith("xterm-kitty"):
        return "kitty"
    if env.get("TERM_PROGRAM", "").lower() in ("wezterm", "ghostty"):
        return "kitty"
    if env.get("TERM_PROGRAM") == "iTerm.app":
        return "iterm"
    return "ansi"


# ── ANSI half-block drawing ────────────────────────────────────────
def visible_len(line):
    n, i, vis = len(line), 0, 0
    while i < n:
        if line[i] == ESC:
            while i < n and line[i] != "m":
                i += 1
            i += 1
        else:
            vis += 1
            i += 1
    return vis


def _color(px, truecolor, fg):
    r, g, b, a = px
    if a == 0:
        return "49" if not fg else "39"
    if truecolor:
        return ("38" if fg else "48") + ";2;%d;%d;%d" % (r, g, b)
    c = 16 + 36 * (r * 5 // 255) + 6 * (g * 5 // 255) + (b * 5 // 255)
    return ("38" if fg else "48") + ";5;%d" % c


def halfblocks(rgba, w, h, max_cols, truecolor):
    step = max(1, math.ceil(w / max_cols))
    cw, ch = (w + step - 1) // step, (h + step - 1) // step
    if ch % 2:
        ch += 1

    def px(x, y):
        sx, sy = min(w - 1, x * step), min(h - 1, y * step)
        if y * step >= h:
            return (0, 0, 0, 0)
        o = (sy * w + sx) * 4
        return tuple(rgba[o:o + 4])

    lines = []
    for row in range(0, ch, 2):
        parts = []
        for col in range(cw):
            top, bot = px(col, row), px(col, row + 1)
            if top[3] == 0 and bot[3] == 0:
                parts.append(ESC + "[0m ")
                continue
            parts.append(ESC + "[%s;%sm▀" %
                         (_color(top, truecolor, True), _color(bot, truecolor, False)))
        lines.append("".join(parts) + ESC + "[0m")
    return lines


def exp_bar(pct, gold, width=10):
    filled = max(0, min(width, round(pct * width / 100)))
    color = "38;5;220" if gold else "38;5;81"
    return (ESC + "[" + color + "m" + "▰" * filled +
            ESC + "[38;5;240m" + "▱" * (width - filled) + ESC + "[0m")


# ── captions (presentation; name/moves arrive localized) ──────────
def josa(w, with_final, no_final):
    c = ord(w[-1])
    has = 0xAC00 <= c <= 0xD7A3 and (c - 0xAC00) % 28 > 0
    return w + (with_final if has else no_final)


def pick(arr, now):
    return arr[int(now / 7) % len(arr)]


def caption(r, now):
    age = now - r.get("state_ts", 0)
    st = r.get("state", "idle")
    if st in ("done", "hello") and age > 45:
        st = "idle"
    if st in ("thinking", "working", "waiting") and age > 600:
        st = "idle"
    n = r["name"]
    moves = r.get("moves") or ["TACKLE"]
    move = pick(moves, now)
    if r.get("lang") == "ko":
        lines = {
            "thinking": pick([josa(n, "은", "는") + " 기합을 넣고 있다!",
                              josa(n, "은", "는") + " 상황을 살피고 있다!"], now),
            "working": n + "의 " + move + "!",
            "done": pick(["효과는 굉장했다!", josa(n, "은", "는") + " 경험치를 얻었다!"], now),
            "waiting": josa(n, "은", "는") + " 지시를 기다리고 있다",
            "hello": "가라! " + n + "!",
            "idle": josa(n, "은", "는") + " 쿨쿨 잠들어 있다",
        }
    else:
        lines = {
            "thinking": pick([n + " is getting pumped!", n + " is sizing up the task!"], now),
            "working": n + " used " + move + "!",
            "done": pick(["It's super effective!", n + " gained EXP. Points!"], now),
            "waiting": n + " looks at you expectantly",
            "hello": "Go! " + n + "!",
            "idle": n + " is fast asleep",
        }
    return st, lines.get(st, lines["idle"])


# ── resolved.json ──────────────────────────────────────────────────
def load_resolved(cache):
    try:
        with open(os.path.join(cache, "resolved.json")) as fh:
            r = json.load(fh)
        return r if r.get("species") else None
    except (OSError, ValueError):
        return None


def KICK(root):
    subprocess.Popen(["/bin/bash", os.path.join(root, "scripts", "pet-core.sh"), "resolve"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def maybe_kick(root, r, last_kick, now):
    if r and r.get("date") and r["date"] != time.strftime("%Y-%m-%d") and now - last_kick > 60:
        KICK(root)
        return now
    return last_kick


# ── graphics backends (kitty / iTerm2) — Task 3 fills these in ────
def kitty_show(rgba, w, h, rows, img_id):
    raise NotImplementedError


def iterm_show(gif_bytes, rows):
    raise NotImplementedError


# ── UI loop ────────────────────────────────────────────────────────
class UI:
    def __init__(self, root, backend):
        self.root, self.backend = root, backend
        self.species = None
        self.anim = None
        self.frame_i = 0
        self.facing_left = True
        self.last_kick = 0.0
        self.gif_bytes = b""
        self.truecolor = os.environ.get("COLORTERM", "") in ("truecolor", "24bit")

    def load_species(self, species):
        path = os.path.join(CACHE, "sprites", species + ".gif")
        try:
            with open(path, "rb") as fh:
                self.gif_bytes = fh.read()
            self.anim = petgif.decode(self.gif_bytes)
        except (OSError, ValueError):
            self.anim = None
        self.species, self.frame_i = species, 0

    def sprite_lines(self, state, now):
        if not self.anim:
            return ["  (sprite missing — run: claude-pokemon-pet sprites)"]
        fr = self.anim.frames[self.frame_i % len(self.anim.frames)]
        rgba = fr.rgba
        if state == "working":
            self.facing_left = int(now / 3) % 2 == 0
            if not self.facing_left:
                rgba = petgif.mirror(rgba, self.anim.width, self.anim.height)
        pad = " " * (int(now * 2) % 5 if state == "working" else 0)
        return [pad + l for l in
                halfblocks(rgba, self.anim.width, self.anim.height, MAX_COLS, self.truecolor)]

    def draw(self):
        now = time.time()
        r = load_resolved(CACHE)
        self.last_kick = maybe_kick(self.root, r, self.last_kick, now)
        out = [ESC + "[H" + ESC + "[2J"]
        if not r:
            out.append("waiting for pet-core... (start a Claude Code session)")
            sys.stdout.write("".join(out))
            sys.stdout.flush()
            return
        if r["species"] != self.species:
            self.load_species(r["species"])
        st, mood = caption(r, now)
        dim = ESC + "[2m" if st == "idle" else ""
        out.append(dim)
        out.extend(l + "\r\n" for l in self.sprite_lines(st, now))
        out.append(ESC + "[0m\r\n")
        out.append(" %s  Lv.%d   \U0001f525%dd\r\n" % (r["name"], r["tasks"], r["streak"]))
        out.append(" " + exp_bar(r["exp_pct"], r["exp_gold"]) + "\r\n")
        out.append(" " + mood + ESC + "[K\r\n")
        sys.stdout.write("".join(out))
        sys.stdout.flush()
        self.frame_i += 1


def main(argv):
    root = argv[1] if len(argv) > 1 else os.path.expanduser(
        "~/.claude/plugins/marketplaces/claude-pokemon-pet")
    backend = pick_backend(os.environ)
    ui = UI(root, backend)

    def restore(*_):
        sys.stdout.write(ESC + "[?25h" + ESC + "[?1049l")
        sys.stdout.flush()
        sys.exit(0)

    signal.signal(signal.SIGINT, restore)
    signal.signal(signal.SIGTERM, restore)
    sys.stdout.write(ESC + "[?1049h" + ESC + "[?25l")   # alt screen, hide cursor
    try:
        while True:
            ui.draw()
            time.sleep(TICK)
    finally:
        restore()


if __name__ == "__main__":
    main(sys.argv)
```

Note: `UI.draw` uses only the ANSI path for now; Task 3 routes `kitty`/`iterm` backends through `kitty_show`/`iterm_show`.

- [ ] **Step 4: Run tests.** `bash tests/run.sh` → all pass (13 new Python tests).

- [ ] **Step 5: Manual smoke (any terminal):** `python3 scripts/pet-term.py "$PWD"` in a spare terminal — pet appears in half-blocks, captions rotate, Ctrl-C restores the screen. Verify over a `bash -c 'TERM=xterm-256color python3 scripts/pet-term.py "$PWD"'` run too.

- [ ] **Step 6: Commit.** `git add scripts/pet-term.py tests/test_term.py && git commit -m "feat: terminal renderer — ANSI half-block backend and UI loop"`

---

### Task 3: Kitty + iTerm2 graphics backends

**Files:**
- Modify: `scripts/pet-term.py` (replace the two `NotImplementedError` stubs; route `UI.draw`)
- Modify: `tests/test_term.py` (add sequence tests)

**Interfaces:**
- Produces: `kitty_seq(rgba, w, h, rows, img_id) -> bytes` (pure, tested) and `iterm_seq(gif_bytes, rows) -> bytes` (pure, tested); `kitty_show`/`iterm_show` write them to stdout. Kitty: RGBA `f=32`, base64 in ≤4096-char chunks (`m=1`/`m=0`), `a=T,i=<id>,r=<rows>,q=2`; delete previous with `a=d,d=I,i=<id>` on species change. iTerm2: OSC 1337 `File=inline=1;height=<rows>;preserveAspectRatio=1` with the whole GIF base64 (iTerm2 animates GIFs natively — send once per species/facing change only).

- [ ] **Step 1: Add failing tests to `tests/test_term.py`:**

```python
class TestGraphicsSeqs(unittest.TestCase):
    def test_kitty_seq_chunked_and_terminated(self):
        rgba = bytes(4) * (50 * 50)
        seq = pet_term.kitty_seq(rgba, 50, 50, rows=12, img_id=7)
        self.assertTrue(seq.startswith(b"\x1b_G"))
        self.assertIn(b"f=32", seq)
        self.assertIn(b"s=50,v=50", seq)
        self.assertIn(b"i=7", seq)
        self.assertIn(b"q=2", seq)
        self.assertTrue(seq.endswith(b"\x1b\\"))
        for chunk in seq.split(b"\x1b\\")[:-1]:
            payload = chunk.split(b";", 1)[1] if b";" in chunk else b""
            self.assertLessEqual(len(payload), 4096)

    def test_iterm_seq_embeds_gif(self):
        import base64 as b64
        gif = b"GIF89a-fake-bytes"
        seq = pet_term.iterm_seq(gif, rows=12)
        self.assertTrue(seq.startswith(b"\x1b]1337;File=inline=1"))
        self.assertIn(b"height=12", seq)
        self.assertIn(b64.b64encode(gif), seq)
        self.assertTrue(seq.endswith(b"\x07"))
```

- [ ] **Step 2: Run to verify failure** (`kitty_seq` not defined). `bash tests/run.sh` → FAIL.

- [ ] **Step 3: Implement.** Replace the stubs in `scripts/pet-term.py`:

```python
def kitty_seq(rgba, w, h, rows, img_id):
    payload = base64.b64encode(rgba)
    chunks = [payload[i:i + 4096] for i in range(0, len(payload), 4096)]
    out = bytearray()
    for i, chunk in enumerate(chunks):
        first, last = i == 0, i == len(chunks) - 1
        ctrl = b""
        if first:
            ctrl = b"a=T,f=32,s=%d,v=%d,r=%d,i=%d,q=2," % (w, h, rows, img_id)
        ctrl += b"m=0" if last else b"m=1"
        out += b"\x1b_G" + ctrl + b";" + chunk + b"\x1b\\"
    return bytes(out)


def kitty_delete(img_id):
    return b"\x1b_Ga=d,d=I,i=%d,q=2\x1b\\" % img_id


def kitty_show(rgba, w, h, rows, img_id):
    sys.stdout.buffer.write(kitty_seq(rgba, w, h, rows, img_id))
    sys.stdout.flush()


def iterm_seq(gif_bytes, rows):
    return (b"\x1b]1337;File=inline=1;height=%d;preserveAspectRatio=1:" % rows +
            base64.b64encode(gif_bytes) + b"\x07")


def iterm_show(gif_bytes, rows):
    sys.stdout.buffer.write(iterm_seq(gif_bytes, rows))
    sys.stdout.flush()
```

Route in `UI.draw` — replace the `out.extend(l + "\r\n" for l in self.sprite_lines(st, now))` line with:

```python
        rows = 12
        if self.backend == "kitty" and self.anim:
            fr = self.anim.frames[self.frame_i % len(self.anim.frames)]
            rgba = fr.rgba
            if st == "working" and int(now / 3) % 2:
                rgba = petgif.mirror(rgba, self.anim.width, self.anim.height)
            sys.stdout.write("".join(out))
            sys.stdout.flush()
            out = []
            kitty_show(rgba, self.anim.width, self.anim.height, rows, img_id=77)
            out.append(ESC + "[%dB\r" % rows)
        elif self.backend == "iterm" and self.gif_bytes:
            if r["species"] != getattr(self, "_iterm_sent", None):
                sys.stdout.write("".join(out))
                sys.stdout.flush()
                out = []
                iterm_show(self.gif_bytes, rows)
                self._iterm_sent = r["species"]
                out.append("\r\n")
            else:
                out.append(ESC + "[%dB\r" % (rows + 1))   # skip over the live GIF
        else:
            out.extend(l + "\r\n" for l in self.sprite_lines(st, now))
```

And in `load_species`, when the species changes under the kitty backend, emit `kitty_delete(77)` first; under iTerm2 reset `self._iterm_sent = None`. iTerm2 full-screen note: the `ESC[2J` clear would erase the inline GIF each tick — for the iterm backend, clear only below the image (`ESC[0J` after positioning) instead of the whole screen; concretely, in `draw()` use `ESC[H` + (`ESC[2J` for ansi/kitty, `ESC[0J` handled after the image skip for iterm).

- [ ] **Step 4: Run tests.** `bash tests/run.sh` → all pass.

- [ ] **Step 5: Manual smoke in real terminals** (whichever are installed; at minimum run the ansi + forced modes and confirm no crash): `PET_TERM_MODE=kitty python3 scripts/pet-term.py "$PWD"` inside kitty/WezTerm/Ghostty if available; `PET_TERM_MODE=iterm` inside iTerm2; confirm Ctrl-C restores.

- [ ] **Step 6: Commit.** `git add scripts/pet-term.py tests/test_term.py && git commit -m "feat: kitty and iTerm2 graphics backends for terminal pet"`

---

### Task 4: CLI integration (`term` subcommand) + Linux-friendly deps

**Files:**
- Modify: `scripts/claude-pokemon-pet` (add `term`; per-mode dep checks; portable `stat`)
- Modify: `scripts/get-sprites.sh` (gifsicle optional)

**Interfaces:**
- Consumes: `pet-term.py` (Task 2/3).
- Produces: `claude-pokemon-pet term` — checks `jq`+`python3`+sprites (fetching them needs `curl`), then `exec python3 "$ROOT/scripts/pet-term.py" "$ROOT"`. Overlay-only deps (`gifsicle`, `osascript`) are NOT required for `term`.

- [ ] **Step 1: Portable stat in `launch()`** — replace the `age=` line:

```bash
        local mtime
        mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)
        local age=$(( $(date +%s) - mtime ))
```

- [ ] **Step 2: Add the `term` case** (before `*)`):

```bash
    term)
        for dep in jq python3; do
            command -v "$dep" >/dev/null || { echo "claude-pokemon-pet term: missing dependency: $dep" >&2; exit 1; }
        done
        if [ ! -f "$CACHE/sprites/mew.gif" ]; then
            command -v curl >/dev/null || { echo "claude-pokemon-pet term: need curl to fetch sprites" >&2; exit 1; }
            "$ROOT/scripts/get-sprites.sh"
        fi
        "$CORE" roll-if-new-day >/dev/null
        exec python3 "$ROOT/scripts/pet-term.py" "$ROOT"
        ;;
```

Also add `term` to the usage line.

- [ ] **Step 3: gifsicle-optional sprites.** In `scripts/get-sprites.sh`, wrap the upscale loop:

```bash
if command -v gifsicle >/dev/null; then
    for g in "$CACHE/sprites"/*.gif; do
        ...existing loop body unchanged...
    done
    echo "big: $(ls "$CACHE/sprites-big" | wc -l | tr -d ' ')"
else
    echo "gifsicle not found — skipped overlay upscales (terminal mode doesn't need them)"
fi
```

- [ ] **Step 4: Verify.** `bash tests/run.sh` green; `scripts/claude-pokemon-pet term` in a spare terminal starts the renderer (Ctrl-C exits); `bash -n scripts/claude-pokemon-pet scripts/get-sprites.sh` parses.

- [ ] **Step 5: Commit.** `git add scripts/claude-pokemon-pet scripts/get-sprites.sh && git commit -m "feat: claude-pokemon-pet term subcommand, linux-friendly deps"`

---

### Task 5: Statusline pet

**Files:**
- Create: `scripts/pet-statusline.sh`
- Modify: `scripts/claude-pokemon-pet` (add `statusline` case printing setup instructions)
- Test: `tests/test-statusline.sh`

**Interfaces:**
- Consumes: `resolved.json` + `pet-core.sh resolve` (Phase 1).
- Produces: one line like `🔥 CHARMELEON Lv.7 ▰▱▱▱▱ ⚔️` on stdout; exit 0 always; re-resolves when the date stamp is stale; silent-safe without jq.

- [ ] **Step 1: Write the failing test.** `tests/test-statusline.sh`:

```bash
#!/bin/bash
. "$(dirname "$0")/lib.sh"
SL="$ROOT/scripts/pet-statusline.sh"

setup  # renders name, level, bar and state emoji (tasks 12 → exp 60% → 3 of 5 segments)
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0}' > "$CACHE/partner"
echo "2026-07-13 12" > "$CACHE/tasks"
"$CORE" event working </dev/null
out="$("$SL")"; rc=$?
assert_eq "statusline exits 0" "0" "$rc"
case "$out" in *"CHARMELEON Lv.12"*) ok=yes ;; *) ok=no ;; esac
assert_eq "statusline shows name+level" "yes" "$ok"
case "$out" in *"▰"*) ok=yes ;; *) ok=no ;; esac
assert_eq "statusline shows exp bar" "yes" "$ok"
teardown

setup  # stale resolved.json re-resolves on a new day
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"date":"2026-07-13","type":"fire","seed":0}' > "$CACHE/partner"
echo "2026-07-13 7" > "$CACHE/tasks"
"$CORE" resolve
out="$(PET_TODAY=2026-07-14 "$SL")"
case "$out" in *"Lv.0"*) ok=yes ;; *) ok=no ;; esac
assert_eq "statusline re-resolves on rollover" "yes" "$ok"
teardown

setup  # no resolved.json and no partner: still exits 0 with a friendly line
out="$("$SL")"; rc=$?
assert_eq "empty cache exits 0" "0" "$rc"
teardown

report
```

- [ ] **Step 2: Run to verify failure.** `bash tests/run.sh` → FAIL (no script).

- [ ] **Step 3: Implement `scripts/pet-statusline.sh`:**

```bash
#!/bin/bash
# One-line pet for the Claude Code statusline. Pure view of resolved.json;
# re-asks pet-core.sh to resolve when the date stamp is stale. Always exits 0.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
R="$CACHE/resolved.json"
TODAY="${PET_TODAY:-$(date +%F)}"

command -v jq >/dev/null 2>&1 || exit 0
[ "$(jq -r '.date // empty' "$R" 2>/dev/null)" = "$TODAY" ] || "$ROOT/scripts/pet-core.sh" resolve 2>/dev/null
[ -f "$R" ] || { echo "🥚 no pet yet"; exit 0; }

jq -r '
  def temoji: {fire:"🔥",water:"💧",grass:"🌿",electric:"⚡",psychic:"🔮",
    fighting:"🥊",rock:"🪨",ground:"⛰️",poison:"☠️",bug:"🐛",flying:"🕊️",
    ghost:"👻",ice:"❄️",dragon:"🐉",normal:"⭐"}[.type] // "⭐";
  def semoji: {working:"⚔️",thinking:"🤔",waiting:"⏳",done:"✨",hello:"👋"}[.state] // "💤";
  def bar: (.exp_pct * 5 / 100 | floor) as $f
    | (("▰" * $f) // "") + (("▱" * (5 - $f)) // "");
  "\(temoji) \(.name) Lv.\(.tasks) \(bar) \(semoji)"
' "$R" 2>/dev/null || echo "🥚 no pet yet"
exit 0
```

- [ ] **Step 4: Add the `statusline` CLI case** (prints setup instructions; we never edit the user's settings.json):

```bash
    statusline)
        echo "Add this to ~/.claude/settings.json to put the pet in your statusline:"
        echo ''
        echo '  "statusLine": {'
        echo '    "type": "command",'
        echo "    \"command\": \"$ROOT/scripts/pet-statusline.sh\""
        echo '  }'
        echo ''
        echo "Preview: $("$ROOT/scripts/pet-statusline.sh")"
        ;;
```

- [ ] **Step 5: Run tests.** `bash tests/run.sh` → all pass. Also `chmod +x scripts/pet-statusline.sh`.

- [ ] **Step 6: Commit.** `git add scripts/pet-statusline.sh scripts/claude-pokemon-pet tests/test-statusline.sh && git commit -m "feat: statusline pet — one-line renderer for any terminal"`

---

### Task 6: Docs, version, QA

**Files:**
- Modify: `README.md`, `.claude-plugin/plugin.json`, `commands/pet.md`, `CLAUDE.md`

- [ ] **Step 1: README.** Update the intro ("macOS" → "macOS overlay + terminal mode everywhere"); Requirements table becomes per-mode (overlay: macOS/jq/gifsicle; terminal: any OS incl. Linux/SSH, jq/python3/curl); add a **Terminal mode (Linux / SSH / RunPod)** section: `claude-pokemon-pet term` in a tmux split or second SSH session on the box where Claude Code runs, graphics tiers + `PET_TERM_MODE` override, tmux uses half-blocks by default; add a **Statusline** section around `claude-pokemon-pet statusline`; add both scripts to the "How it works" table.
- [ ] **Step 2: commands/pet.md** — add `term`/`statusline` to the subcommand list and the mapping ("terminal", "statusline" → those). `CLAUDE.md` phase status: mark Phase 2 ✅.
- [ ] **Step 3: Version** `.claude-plugin/plugin.json` → `0.5.0`; keywords add `"linux"`, `"terminal"`.
- [ ] **Step 4: Full verification.** `bash tests/run.sh`; manual: `claude-pokemon-pet term` (ANSI mode) while a Claude session runs — pet reacts to events within a second; statusline preview renders.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "docs: v0.5.0 — terminal mode and statusline"`

---

## Post-plan checks
1. `bash tests/run.sh` green end-to-end.
2. Code review loop (code-reviewer agent, sonnet) → fix all → PASS.
3. Milestone report in `docs/milestones/`; PR; user sign-off before Phase 3.
