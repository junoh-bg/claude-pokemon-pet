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
