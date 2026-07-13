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
        return "39" if fg else "49"
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
        sx, sy = min(w - 1, x * step), y * step
        if sy >= h:
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


# ── graphics backends (kitty / iTerm2) — filled in by the graphics task ──
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
    except SystemExit:
        raise
    except BaseException:
        restore()
        raise


if __name__ == "__main__":
    main(sys.argv)
