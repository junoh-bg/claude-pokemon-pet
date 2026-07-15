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

    def test_whitekey(self):
        rgba = bytes([255, 255, 255, 255, 200, 10, 10, 255, 250, 250, 250, 255])
        out = pet_term.whitekey(rgba)
        self.assertEqual(out[3], 0)            # pure white keyed out
        self.assertEqual(out[4:8], bytes([200, 10, 10, 255]))
        self.assertEqual(out[11], 255)         # near-white stays (gifsicle parity)

    def test_hp_bar_colors(self):
        self.assertIn("38;5;46", pet_term.hp_bar(80))
        self.assertIn("38;5;226", pet_term.hp_bar(50))
        self.assertIn("38;5;196", pet_term.hp_bar(20))

    def test_sprite_path_shiny(self):
        self.assertEqual(pet_term.sprite_file("pikachu", True), "pikachu-shiny.gif")
        self.assertEqual(pet_term.sprite_file("pikachu", False), "pikachu.gif")

    def test_evo_caption(self):
        st = pet_term.evo_caption("CHARMANDER", "CHARMELEON", "en", 1.0)
        self.assertIn("is evolving", st)
        st = pet_term.evo_caption("CHARMANDER", "CHARMELEON", "en", 4.0)
        self.assertIn("Congratulations", st)
        st = pet_term.evo_caption("파이리", "리자드", "ko", 4.0)
        self.assertIn("진화했다", st)
        self.assertIn("리자드로", st)   # no batchim → 로

    def test_ro_josa_branches(self):
        self.assertEqual(pet_term.ro_josa("리자드"), "리자드로")       # no batchim → 로
        self.assertEqual(pet_term.ro_josa("리자몽"), "리자몽으로")     # ㅇ batchim → 으로
        self.assertEqual(pet_term.ro_josa("이상해풀"), "이상해풀로")   # ㄹ batchim → 로 (the exception)

    def test_invert_line_survives_embedded_resets(self):
        # transparent-left, red-right: halfblocks emits ESC[0m before the pixel
        rgba = bytes([0, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255])
        line = pet_term.halfblocks(rgba, 2, 2, max_cols=10, truecolor=True)[0]
        self.assertIn("\x1b[0m", line)                      # the reset that broke it
        inv = pet_term.invert_line(line)
        self.assertTrue(inv.startswith("\x1b[7m"))
        self.assertIn("\x1b[0m\x1b[7m", inv)                # re-armed after every reset
        self.assertTrue(inv.endswith("\x1b[27m"))

    def test_use_inline_gif(self):
        self.assertTrue(pet_term.use_inline_gif("iterm", "pokemon"))
        self.assertFalse(pet_term.use_inline_gif("iterm", "digimon"))
        self.assertFalse(pet_term.use_inline_gif("kitty", "pokemon"))
        self.assertFalse(pet_term.use_inline_gif("ansi", "digimon"))

    def test_halfblocks_averages_cells(self):
        # 2x2 downsampled to 1 cell: half red / half transparent → red cell
        # (nearest sampling could land on the transparent pixel — the bug)
        rgba = bytes([255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 255])
        lines = pet_term.halfblocks(rgba, 2, 2, max_cols=1, truecolor=True)
        joined = "".join(lines)
        self.assertIn("255;0;0", joined)

    def test_halfblocks_mostly_transparent_cell_stays_clear(self):
        # 1 opaque pixel in a 4x4 cell block (6% coverage) → transparent cell
        rgba = bytearray(4 * 4 * 4)
        rgba[0:4] = bytes([255, 0, 0, 255])
        lines = pet_term.halfblocks(bytes(rgba), 4, 4, max_cols=1, truecolor=True)
        self.assertNotIn("▀", "".join(lines))

    def test_sprite_cols_adaptive(self):
        self.assertEqual(pet_term.sprite_cols(80, 24, 320, 320), 32)   # height-bound
        self.assertEqual(pet_term.sprite_cols(200, 60, 320, 320), 64)  # cap
        self.assertEqual(pet_term.sprite_cols(28, 40, 320, 320), 24)   # floor
        # documented limitation: the 24-col readability floor wins over the
        # height bound for extreme portrait ratios (no shipped asset hits it)
        self.assertEqual(pet_term.sprite_cols(80, 24, 40, 320), 24)

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


class TestGraphicsSeqs(unittest.TestCase):
    def test_kitty_seq_chunked_and_terminated(self):
        rgba = bytes(4) * (50 * 50)
        seq = pet_term.kitty_seq(rgba, 50, 50, rows=12, img_id=7)
        self.assertTrue(seq.startswith(b"\x1b_G"))
        self.assertIn(b"f=32", seq)
        self.assertIn(b"s=50,v=50", seq)
        self.assertIn(b"i=7", seq)
        self.assertIn(b"C=1", seq)   # no cursor auto-advance; draw() moves it
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


class TestPngSpritePath(unittest.TestCase):
    def setUp(self):
        import tempfile
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
        import petpng
        self.petpng = petpng
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, "sprites"))
        self.old_cache = pet_term.CACHE
        pet_term.CACHE = self.tmp

    def tearDown(self):
        import shutil
        pet_term.CACHE = self.old_cache
        shutil.rmtree(self.tmp)

    def test_load_species_png_floodfills(self):
        # 2x2: three white pixels + one red — digimon load keys border whites
        rgba = bytes([255, 255, 255, 255] * 3 + [200, 10, 10, 255])
        with open(os.path.join(self.tmp, "sprites", "agumon.png"), "wb") as fh:
            fh.write(self.petpng.encode(rgba, 2, 2))
        ui = pet_term.UI("/root", "ansi")
        ui.load_species("agumon", "digimon")
        self.assertIsNotNone(ui.anim)
        self.assertEqual((ui.anim.width, ui.anim.height), (2, 2))
        self.assertEqual(ui.anim.frames[0].rgba[3], 0)        # white keyed
        self.assertEqual(ui.anim.frames[0].rgba[15], 255)     # red kept

    def test_load_species_malformed_png_degrades(self):
        with open(os.path.join(self.tmp, "sprites", "bad.png"), "wb") as fh:
            fh.write(b"definitely not a png")
        ui = pet_term.UI("/root", "ansi")
        ui.load_species("bad", "digimon")
        self.assertIsNone(ui.anim)

    def test_kitty_dedup_resets_on_species_change(self):
        ui = pet_term.UI("/root", "ansi")   # ansi backend: no escape writes
        self.assertIsNone(ui._kitty_sent)
        ui._kitty_sent = ("agumon", 0, False)
        ui.load_species("missing-species", "digimon")
        self.assertIsNone(ui._kitty_sent)   # forces retransmit after change


class TestLiving(unittest.TestCase):
    def test_element_color(self):
        self.assertEqual(pet_term.element_color("fire"), "38;5;203")
        self.assertEqual(pet_term.element_color("holy"), "38;5;222")
        self.assertEqual(pet_term.element_color("nonsense"), "38;5;150")

    def test_spark_line(self):
        right = pet_term.spark_line(1, "fire", 40)
        left = pet_term.spark_line(-1, "fire", 40)
        self.assertIn("✦✧✦", right)
        self.assertIn("38;5;203", right)
        self.assertGreater(right.index("✦"), left.index("✦"))  # strike side

    def test_no_flying_projectiles_ever(self):
        # user demand: no traveling balls of any color — the projectile
        # renderer must not exist, only the impact spark
        self.assertFalse(hasattr(pet_term, "projectile_line"))
        self.assertFalse(hasattr(pet_term, "show_projectile"))
        for elem in ("fire", "dark", "poison", "vpet"):
            self.assertNotIn("●", pet_term.spark_line(1, elem, 40))

    def test_breathe_offset(self):
        self.assertIn(pet_term.breathe_offset(0.0), (0, 1))
        self.assertNotEqual(pet_term.breathe_offset(0.0), pet_term.breathe_offset(2.0))


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
