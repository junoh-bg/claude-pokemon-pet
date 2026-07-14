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
import base64, json, math, os, shutil, signal, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import petgif
import petpng

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
        return "39" if fg else "49"
    if truecolor:
        return ("38" if fg else "48") + ";2;%d;%d;%d" % (r, g, b)
    c = 16 + 36 * (r * 5 // 255) + 6 * (g * 5 // 255) + (b * 5 // 255)
    return ("38" if fg else "48") + ";5;%d" % c


def halfblocks(rgba, w, h, max_cols, truecolor, mirrored=False):
    """Render RGBA to ▀ half-block lines. Cells are AREA-AVERAGED
    (alpha-weighted): nearest-pixel sampling turns detailed art into noise
    at terminal resolution — averaging keeps shapes readable."""
    step = max(1, math.ceil(w / max_cols))
    cw, ch = (w + step - 1) // step, (h + step - 1) // step
    if ch % 2:
        ch += 1

    def cell(x, y):
        # mirroring happens during sampling — flipping the full-resolution
        # buffer first would do the work for pixels never rendered
        cx = (cw - 1 - x) if mirrored else x
        x0, y0 = cx * step, y * step
        if y0 >= h:
            return (0, 0, 0, 0)
        r = g = b = a = n = 0
        for sy in range(y0, min(y0 + step, h)):
            base = sy * w * 4
            for sx in range(x0, min(x0 + step, w)):
                o = base + sx * 4
                al = rgba[o + 3]
                if al:
                    r += rgba[o] * al
                    g += rgba[o + 1] * al
                    b += rgba[o + 2] * al
                    a += al
                n += 1
        if n == 0 or a == 0 or a < 64 * n:   # cell is mostly transparent
            return (0, 0, 0, 0)
        return (r // a, g // a, b // a, 255)

    lines = []
    for row in range(0, ch, 2):
        parts = []
        for col in range(cw):
            top, bot = cell(col, row), cell(col, row + 1)
            if top[3] == 0 and bot[3] == 0:
                parts.append(ESC + "[0m ")
                continue
            parts.append(ESC + "[%s;%sm▀" %
                         (_color(top, truecolor, True), _color(bot, truecolor, False)))
        lines.append("".join(parts) + ESC + "[0m")
    return lines


def sprite_cols(term_cols, term_lines, w, h):
    """Adaptive sprite width: use the pane we actually have (24..64 cols),
    height-aware for the near-square art we ship. NOTE: the 24-col
    readability floor wins over the height bound — an extreme portrait
    sprite in a tiny pane could still overflow (no such asset exists)."""
    by_width = max(24, min(64, term_cols - 6))
    rows_budget = max(8, term_lines - 8)
    by_height = max(24, int(rows_budget * 2 * w / max(1, h)))
    return min(by_width, by_height)


def exp_bar(pct, gold, width=10):
    filled = max(0, min(width, round(pct * width / 100)))
    color = "38;5;220" if gold else "38;5;81"
    return (ESC + "[" + color + "m" + "▰" * filled +
            ESC + "[38;5;240m" + "▱" * (width - filled) + ESC + "[0m")


def hp_bar(pct, width=10):
    filled = max(0, min(width, round(pct * width / 100)))
    color = "38;5;46" if pct > 60 else "38;5;226" if pct > 30 else "38;5;196"
    return (ESC + "[" + color + "m" + "▰" * filled +
            ESC + "[38;5;240m" + "▱" * (width - filled) + ESC + "[0m")


def sprite_file(species, shiny):
    return species + ("-shiny" if shiny else "") + ".gif"


def invert_line(line):
    """Wrap a half-block line in reverse-video. halfblocks() emits a full
    SGR reset (ESC[0m) for transparent runs, which would cancel the reverse
    for the rest of the row — re-arm it after every embedded reset."""
    return (ESC + "[7m" + line.replace(ESC + "[0m", ESC + "[0m" + ESC + "[7m")
            + ESC + "[27m")


def whitekey(rgba):
    """V-pet sprites ship on an opaque white background: key it out.
    Exact pure white only — matches gifsicle --transparent='#FFFFFF' in
    get-sprites.sh so both renderers produce the same mask."""
    out = bytearray(rgba)
    for o in range(0, len(out), 4):
        if out[o] == 255 and out[o + 1] == 255 and out[o + 2] == 255 and out[o + 3] == 255:
            out[o + 3] = 0
    return bytes(out)


def use_inline_gif(backend, franchise):
    """iTerm2's inline-image path sends the raw GIF bytes, which cannot be
    white-keyed — digimon sprites there fall back to half-blocks."""
    return backend == "iterm" and franchise != "digimon"


# ── captions (presentation; name/moves arrive localized) ──────────
def josa(w, with_final, no_final):
    c = ord(w[-1])
    has = 0xAC00 <= c <= 0xD7A3 and (c - 0xAC00) % 28 > 0
    return w + (with_final if has else no_final)


def ro_josa(w):
    """(으)로 by final consonant; ㄹ counts as none."""
    c = ord(w[-1])
    fin = (c - 0xAC00) % 28
    return w + ("으로" if 0xAC00 <= c <= 0xD7A3 and fin > 0 and fin != 8 else "로")


def evo_caption(old, new, lang, evo_age):
    """Evolution cinematic caption; mirrors the overlay's two phases."""
    if evo_age < 2.5:
        return ("어라…!? " + old + "의 모습이…!") if lang == "ko" \
            else ("What? " + old + " is evolving!")
    if lang == "ko":
        return "축하합니다! " + josa(old, "은", "는") + " " + ro_josa(new) + " 진화했다!"
    return "Congratulations! Your " + old + " evolved into " + new + "!"


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


# ── graphics backends (kitty / iTerm2) ────────────────────────────
def kitty_seq(rgba, w, h, rows, img_id):
    payload = base64.b64encode(rgba)
    chunks = [payload[i:i + 4096] for i in range(0, len(payload), 4096)]
    out = bytearray()
    for i, chunk in enumerate(chunks):
        first, last = i == 0, i == len(chunks) - 1
        ctrl = b""
        if first:
            # C=1: don't let the terminal auto-advance the cursor after
            # placement — draw() moves it below the image itself
            ctrl = b"a=T,f=32,s=%d,v=%d,r=%d,i=%d,C=1,q=2," % (w, h, rows, img_id)
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
        self._iterm_sent = None
        self._kitty_sent = None
        self._lines_cache = {}
        self.prev_stage, self.prev_name = 0, ""
        self.evolve_start, self.evolve_old, self.evolve_new = 0.0, "", ""
        self.truecolor = os.environ.get("COLORTERM", "") in ("truecolor", "24bit")

    def load_species(self, species, franchise=None, shiny=False):
        if self.backend == "kitty" and self.species is not None:
            sys.stdout.buffer.write(kitty_delete(77))
        self._iterm_sent = None
        self._kitty_sent = None
        path = os.path.join(CACHE, "sprites", sprite_file(species, shiny))
        if shiny and not os.path.exists(path):    # shiny variant not cached yet
            path = os.path.join(CACHE, "sprites", sprite_file(species, False))
        if not os.path.exists(path):              # png franchise packs (digimon art)
            png = os.path.join(CACHE, "sprites", species + ".png")
            if os.path.exists(png):
                path = png
        try:
            with open(path, "rb") as fh:
                self.gif_bytes = fh.read()
            if path.endswith(".png"):
                rgba, w, h = petpng.decode(self.gif_bytes)
                if franchise == "digimon":   # solid-white bg → border flood-fill key
                    rgba = petpng.floodfill_whitekey(rgba, w, h)
                self.anim = petgif.Anim(w, h, [petgif.Frame(rgba, 200)])
            else:
                self.anim = petgif.decode(self.gif_bytes)
                if franchise == "digimon":   # legacy gif cache: exact white key
                    self.anim = petgif.Anim(self.anim.width, self.anim.height,
                                            [petgif.Frame(whitekey(f.rgba), f.delay_ms)
                                             for f in self.anim.frames])
        except Exception:            # any decode failure degrades to placeholder text
            self.anim = None
        self.species, self.frame_i = species, 0
        self._lines_cache = {}

    def sprite_lines(self, state, now):
        if not self.anim:
            return ["  (sprite missing — run: claude-pokemon-pet sprites)"]
        fr_idx = self.frame_i % len(self.anim.frames)
        mirrored = False
        if state == "working":
            self.facing_left = int(now / 3) % 2 == 0
            mirrored = not self.facing_left
        size = shutil.get_terminal_size(fallback=(80, 24))
        cols = sprite_cols(size.columns, size.lines, self.anim.width, self.anim.height)
        key = (fr_idx, mirrored, cols)
        lines = self._lines_cache.get(key)
        if lines is None:
            lines = halfblocks(self.anim.frames[fr_idx].rgba,
                               self.anim.width, self.anim.height,
                               cols, self.truecolor, mirrored=mirrored)
            self._lines_cache[key] = lines
        pad = " " * (int(now * 2) % 5 if state == "working" else 0)
        return [pad + l for l in lines]

    def draw(self):
        now = time.time()
        r = load_resolved(CACHE)
        self.last_kick = maybe_kick(self.root, r, self.last_kick, now)
        inline = use_inline_gif(self.backend, (r or {}).get("franchise"))
        # iTerm2 animates its inline GIF itself: a full-screen clear every tick
        # would wipe it, so clear only below the image when one is in use.
        out = [ESC + "[H" + ("" if inline else ESC + "[2J")]
        if not r:
            out.append(ESC + "[2J" + "waiting for pet-core... (start a Claude Code session)")
            self._iterm_sent = None       # full clear wiped any inline GIF
            sys.stdout.write("".join(out))
            sys.stdout.flush()
            return
        if r["species"] != self.species:
            out.append(ESC + "[2J")           # species change: full clear on any backend
            if self.prev_stage and r.get("stage", 0) > self.prev_stage:
                self.evolve_start = now
                self.evolve_old, self.evolve_new = self.prev_name, r["name"]
            self.load_species(r["species"], r.get("franchise"), bool(r.get("shiny")))
        self.prev_stage, self.prev_name = r.get("stage", 0), r["name"]
        st, mood = caption(r, now)
        evo_age = now - self.evolve_start if self.evolve_start else 99
        if evo_age < 10:
            mood = evo_caption(self.evolve_old, self.evolve_new, r.get("lang", "en"), evo_age)
        dim = ESC + "[2m" if st == "idle" else ""
        out.append(dim)
        rows = 12
        if self.backend == "kitty" and self.anim:
            fr_idx = self.frame_i % len(self.anim.frames)
            mirrored = st == "working" and int(now / 3) % 2 == 1
            key = (self.species, fr_idx, mirrored)
            if key != self._kitty_sent:   # only retransmit when the frame changed
                rgba = self.anim.frames[fr_idx].rgba
                if mirrored:
                    rgba = petgif.mirror(rgba, self.anim.width, self.anim.height)
                sys.stdout.write("".join(out))
                sys.stdout.flush()
                out = []
                kitty_show(rgba, self.anim.width, self.anim.height, rows, img_id=77)
                self._kitty_sent = key
            out.append(ESC + "[%dB\r" % rows)
        elif inline and self.gif_bytes:
            if self._iterm_sent != self.species:
                sys.stdout.write("".join(out))
                sys.stdout.flush()
                out = []
                iterm_show(self.gif_bytes, rows)
                self._iterm_sent = self.species
                out.append("\r\n")
            else:
                out.append(ESC + "[%dB\r" % (rows + 1))   # skip over the live GIF
        else:
            invert = evo_age < 2 and int(now * 4) % 2 == 0   # evolution flash
            for l in self.sprite_lines(st, now):
                out.append((invert_line(l) if invert else l) + "\r\n")
        out.append(ESC + "[0m\r\n")
        out.append(" %s%s  Lv.%d   \U0001f525%dd\r\n" %
                   ("✨ " if r.get("shiny") else "", r["name"], r["tasks"], r["streak"]))
        out.append(" " + exp_bar(r["exp_pct"], r["exp_gold"]) +
                   "  " + hp_bar(r.get("hp_pct", 100), width=5) + "\r\n")
        out.append(" " + mood + ESC + "[K\r\n")
        if self.backend == "ansi" and os.environ.get("TERM_PROGRAM") == "Apple_Terminal":
            out.append(ESC + "[2m tip: iTerm2 / kitty / WezTerm render the pet pixel-perfect"
                       + ESC + "[0m\r\n")
        if inline:
            out.append(ESC + "[0J")           # clear leftovers below without touching the GIF
        sys.stdout.write("".join(out))
        sys.stdout.flush()
        self.frame_i += 1


def restore_terminal():
    sys.stdout.write(ESC + "[?25h" + ESC + "[?1049l")   # show cursor, leave alt screen
    sys.stdout.flush()


def main(argv):
    root = argv[1] if len(argv) > 1 else os.path.expanduser(
        "~/.claude/plugins/marketplaces/claude-pokemon-pet")
    backend = pick_backend(os.environ)
    ui = UI(root, backend)

    def on_signal(*_):
        restore_terminal()
        sys.exit(0)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    sys.stdout.write(ESC + "[?1049h" + ESC + "[?25l")   # alt screen, hide cursor
    try:
        while True:
            ui.draw()
            time.sleep(TICK)
    except SystemExit:
        raise
    except BaseException:
        # restore the terminal FIRST, then let the traceback reach stderr —
        # a crash must be loud and exit non-zero, never a silent clean exit
        restore_terminal()
        raise


if __name__ == "__main__":
    main(sys.argv)
