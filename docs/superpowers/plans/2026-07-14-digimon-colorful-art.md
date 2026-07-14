# Digimon Colorful Art + Full EN/KO Localization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the LCD V-pet sprites with colorful official art (digi-api, 70/70 fetch-verified), fix background keying with border flood-fill (the global chroma key punched holes through white body pixels — user-reported), complete Korean localization (all 70 official names + real per-species signature attacks in both languages, no mixed-language output), and ship the dual-franchise `displayName`.

**Architecture:** Digimon sprites become 320×320 RGB PNGs on solid white. A new pure-stdlib `petpng.py` (decoder for color types 2/6 + border flood-fill keying + nearest resize + mirror + encoder) serves both renderers: `get-sprites.sh` calls a thin `process-sprite.py` at install time to produce keyed/scaled `sprites-big/<mon>.png` (+`-flip`) for the overlay (NSImage reads PNG natively — the overlay only needs a one-line `.png` fallback in `setSprite`), and `pet-term.py` decodes + flood-fills originals in-process. The evolution engine is untouched; `moves_by: "species"` makes captions use each species' real attack.

**Tech Stack:** existing bash+jq core; Python ≥3.8 stdlib; curated data from `$CLAUDE_JOB_DIR` staging (verified by sprite-scout, spot-re-verified).

## Global Constraints

- All prior invariants. **Never global chroma key** (CLAUDE.md addendum): keying is flood-fill from the image border, threshold ≥250/channel, interior whites preserved.
- Digimon overlay sprites now require `python3` at sprite-install time (already required for terminal mode; if absent, `get-sprites.sh` says so and digimon overlay sprites are skipped — pokemon unaffected).
- Language purity: ko mode shows 필살기 as the attack when no verified Korean attack exists (greymon, extyranomon) — never an English string inside a Korean sentence; en mode always uses the English attack.
- `metalgreymon_virus` display stays "METALGREYMON" (en) / "메탈그레이몬" (ko — trim the "(바이러스종)" qualifier for display).
- Version 0.9.0; `displayName": "Claude Pet — Pokémon & Digimon"`.

## File Structure

| File | Change |
|---|---|
| `data/digimon/curation.json` | + `art` (urls), `attacks`, merged complete `korean` |
| `scripts/dev/gen-digimon-pack.sh` + `data/digimon/pack.json` | sprites config `{format: png, keying: floodfill, target_px: 180}`; per-species `sprite_url` (digi-api) + `attack {en, ko}`; complete ko names; `moves_by: "species"` |
| `scripts/petpng.py` | new: PNG decode (types 2/6, 8-bit, non-interlaced), `floodfill_whitekey`, `resize_nearest`, `mirror`, PNG encode |
| `scripts/process-sprite.py` | new: CLI — in.png → keyed+scaled out.png + flip |
| `scripts/get-sprites.sh` | format-aware fetch (`.png` ext) + python3 big-build for png packs |
| `scripts/pet-term.py` | extension-aware decode; digimon uses petpng + flood-fill (replaces exact whitekey for png) |
| `scripts/pet-overlay.js` | `setSprite` falls back to `.png` when the `.gif` is missing |
| `scripts/pet-core.sh` | RESOLVE_JQ `moves_by == "species"` branch |
| `.claude-plugin/plugin.json` | displayName + 0.9.0 |
| tests | `test_png.py` (+wrapper entry), digimon pack/resolve asserts, term sprite-path asserts |
| `README.md`, `CLAUDE.md` | art/credits/deps notes |

---

### Task 1: Curation v2 + pack regen (TDD)

- [ ] **Step 1: Merge the staged data** — `$CLAUDE_JOB_DIR/tmp/digimon-recolor.json` (`sprite_urls`, `korean_new`, `attacks`) into `data/digimon/curation.json` via jq:

```bash
tmp=$(mktemp)
jq --slurpfile v2 "$CLAUDE_JOB_DIR/tmp/digimon-recolor.json" '
  .art = $v2[0].sprite_urls
  | .korean = (.korean + $v2[0].korean_new)
  | .attacks = $v2[0].attacks
  | ._meta.notes += ["2026-07-14: colorful art (digi-api, fetch-verified), complete ko names (digimon.net official), per-species attacks — see sprite-scout curation"]' \
  data/digimon/curation.json > "$tmp" && mv "$tmp" data/digimon/curation.json
```

- [ ] **Step 2: Failing pack tests** — update `tests/test-digimon.sh` pack half:
  - `sprite_url` assert becomes digi-api: `'[.species[] | select(.sprite_url | startswith("https://digi-api.com/images/digimon/") | not)] | length' → "0"`.
  - `assert_json "sprites are png" "$DPACK" '.sprites.format' "png"`; `'.sprites.keying' "floodfill"`; `'.moves_by' "species"`.
  - `assert_json "all 70 ko names present" "$DPACK" '[.species[] | select(.names.ko == null)] | length' "0"`.
  - `assert_json "all 70 attacks en" "$DPACK" '[.species[] | select(.attack.en == null)] | length' "0"`.
  - `assert_json "numemon official ko" "$DPACK" '.species.numemon.names.ko' "워매몬"`.
  - `assert_json "mgv display trimmed" "$DPACK" '.species.metalgreymon_virus.names.ko' "메탈그레이몬"`.
  - Replace the old wikimon sprite_url assert.
- [ ] **Step 3: Generator update** (`gen-digimon-pack.sh`): sprites block → `{ format: "png", keying: "floodfill", target_px: 180 }`; species value gains `sprite_url: $c.art[.]` and `attack: ($c.attacks[.] // {en: "Attack", ko: null})`; ko for `metalgreymon_virus` mapped through `def kdisp: if . == "메탈그레이몬(바이러스종)" then "메탈그레이몬" else . end`; `moves_by: "species"`; keep `moves`/`moves_ko` as legacy fallback. Regenerate; green; commit `feat: digimon pack v2 — colorful art urls, complete ko, real attacks`.

---

### Task 2: petpng.py + process-sprite.py (TDD)

**Interfaces:** `petpng.decode(data) -> (rgba: bytes, w, h)` (raises ValueError on malformed/unsupported); `floodfill_whitekey(rgba, w, h, thresh=250) -> bytes` (border-connected near-white → alpha 0; interior white untouched); `resize_nearest(rgba, w, h, tw, th) -> bytes`; `mirror(rgba, w, h) -> bytes`; `encode(rgba, w, h) -> bytes` (RGBA PNG). `process-sprite.py IN.png OUT.png OUT_FLIP.png TARGET_PX` exits nonzero on failure.

- [ ] **Step 1: Failing tests** `tests/test_png.py` (add `test_png` to the wrapper loop in `tests/test-python.sh`):

```python
import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import petpng


def checker(w, h, px):
    """Build RGBA bytes from a list-of-rows of (r,g,b,a)."""
    return bytes(v for row in px for p in row for v in p)


class TestPng(unittest.TestCase):
    def test_roundtrip_rgba(self):
        rgba = checker(2, 2, [[(255, 0, 0, 255), (0, 255, 0, 128)],
                              [(0, 0, 255, 255), (255, 255, 255, 255)]])
        data = petpng.encode(rgba, 2, 2)
        out, w, h = petpng.decode(data)
        self.assertEqual((w, h), (2, 2))
        self.assertEqual(out, rgba)

    def test_decode_rgb_no_alpha(self):
        # encode can only write RGBA; craft an RGB (type 2) PNG by hand
        import struct, zlib
        raw = b"".join(b"\x00" + bytes([255, 255, 255, 200, 10, 10]) for _ in range(2))
        def chunk(tag, d):
            c = tag + d
            return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
        data = (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
        out, w, h = petpng.decode(data)
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
        out = petpng.floodfill_whitekey(checker(5, 5, rows), 5, 5)
        self.assertEqual(out[3], 0)                      # border white keyed
        center = (2 * 5 + 2) * 4
        self.assertEqual(out[center + 3], 255)           # interior white KEPT
        self.assertEqual(out[(1 * 5 + 1) * 4 + 3], 255)  # red untouched

    def test_resize_and_mirror(self):
        rgba = checker(2, 1, [[(255, 0, 0, 255), (0, 255, 0, 255)]])
        big = petpng.resize_nearest(rgba, 2, 1, 4, 2)
        self.assertEqual(big[0:4], bytes([255, 0, 0, 255]))
        self.assertEqual(len(big), 4 * 2 * 4)
        m = petpng.mirror(rgba, 2, 1)
        self.assertEqual(m[0:4], bytes([0, 255, 0, 255]))

    def test_truncated_raises(self):
        with self.assertRaises(ValueError):
            petpng.decode(b"\x89PNG\r\n\x1a\nnope")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Implement `scripts/petpng.py`** — decoder: parse IHDR (accept bit depth 8, color types 2/6, interlace 0; else ValueError), concatenate IDAT, zlib-decompress, unfilter per scanline (filters 0–4: None/Sub/Up/Average/Paeth), synthesize alpha=255 for type 2; wrap parse errors as ValueError (contract mirrors petgif). Flood-fill: BFS from all border pixels whose channels ≥ thresh and alpha 255, using a bytearray visited mask. Encoder: filter-0 scanlines + zlib, IHDR type 6. `resize_nearest`, `mirror` as in petgif style. `scripts/process-sprite.py`: argv wrapper — decode → floodfill → resize (target, preserving aspect via max dimension) → write out + mirrored flip; exit 1 with a message on any failure.
- [ ] **Step 3: green; live probe** — run process-sprite.py against the two staged real PNGs (`numemon-test.png`, `mgv-test.png` in `$CLAUDE_JOB_DIR/tmp`), Read the outputs visually (transparency correct, no interior holes — Numemon's white eyes must survive). Commit `feat: pure-stdlib png pipeline with border flood-fill keying`.

---

### Task 3: Pipeline + renderers

- [ ] **get-sprites.sh**: per-pack `FORMAT=$(jq -r '.sprites.format // "gif"')`; fetch list writes `<name>.$FORMAT`; existence checks use the extension. Big-build: gif packs → existing gifsicle path; png packs → require python3 (`command -v python3 || { echo "python3 required for digimon sprites — skipped" ; continue; }`) then per species `python3 scripts/process-sprite.py sprites/<mon>.png sprites-big/<mon>.png sprites-big/<mon>-flip.png $TARGET`. Also: digimon's old `.gif` cache files are superseded — remove `sprites/<mon>.gif`/`sprites-big/<mon>{,-flip}.gif` for png-pack species so the overlay's gif-first lookup can't pick up stale LCD art.
- [ ] **pet-overlay.js `setSprite`**: after the GIF `initWithContentsOfFile` returns nil, retry with `.png` (same shiny/flip naming). ~4 lines.
- [ ] **pet-term.py**: `sprite_file(species, shiny, ext="gif")`; `load_species` tries `<species>.gif` then `<species>.png`; png path: `petpng.decode` → `floodfill_whitekey` (when pack keying says so — pass `r.get("franchise") == "digimon"` as before) → wrap as a one-frame anim (`petgif.Anim/Frame` shapes, delay 200). Remove the old exact-white `whitekey` call for png files (flood-fill replaces it; keep `whitekey()` for any legacy gif cache).
- [ ] Tests: `test_term.py` — `sprite_file` ext variants; a small synthetic png placed in a temp sprites dir exercising the png load path via `UI.load_species` (construct UI with backend "ansi").
- [ ] Suite green + headless digimon term smoke (colorful sprite renders as multicolor half-blocks, not black-only). Commit `feat: png sprite pipeline across install, overlay, terminal`.

---

### Task 4: Captions — real attacks (TDD)

- [ ] Tests (`tests/test-digimon.sh`): ko agumon caption move `베이비 플레임`; ko greymon (null ko attack) → `필살기`; en mode agumon → `Baby Flame`; en greymon → `Mega Flame`.
- [ ] RESOLVE_JQ: extend the `$mv` binding:

```jq
  (if ($pack.moves_by // "type") == "species"
   then [ (if $lang == "ko" then ($spec.attack.ko // "필살기")
           else ($spec.attack.en // "ATTACK") end) ]
   elif ($pack.moves_by // "type") == "stage"
   then ($pack.moves[$stage | tostring] // [])
   else ($pack.moves[$p.type] // $pack.moves.normal) end) as $mv |
```

(note: `moves` ko-translation mapping must NOT re-map species attacks — the species branch already emits final strings, so the downstream `map($pack.moves_ko[.] // .)` must be skipped for `moves_by == "species"`; restructure so localization happens inside each branch.)
- [ ] Green (all suites — pokemon caption tests unchanged). Commit `feat: real signature attacks in captions, both languages`.

---

### Task 5: Branding, docs, QA

- [ ] `plugin.json`: `"displayName": "Claude Pet — Pokémon & Digimon"`, version 0.9.0.
- [ ] README: digimon section — art source note (digi-api official renders, © Bandai, fetched at install), python3 requirement for digimon sprites; credits updated (digi-api replaces/joins Wikimon).
- [ ] CLAUDE.md: sprite pipeline notes (png + floodfill; never global chroma key — already in the lessons, confirm), phase status.
- [ ] QA: full suite macOS + Debian (term png path exercised in container); live overlay smoke with a digimon partner — **colorful sprite, no interior holes** (backup/restore user state); fresh-cache install simulation (`rm -r` sandbox cache → `get-sprites.sh` → counts: 372 gif + 70 png originals + 140 png big).
- [ ] Commit `docs: v0.9.0 — colorful digimon, complete korean localization`.

## Post-plan checks
Review loop → PASS → milestone (`docs/milestones/2026-07-14-digimon-colorful-art.md`) → PR → auto-merge → tell the user to update → rebuild + publish the demo artifact.
