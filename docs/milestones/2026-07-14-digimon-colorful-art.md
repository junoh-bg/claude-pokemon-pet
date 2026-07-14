# Milestone Review — Digimon Colorful Art + Full Localization (v0.9.0)

**Branch:** `feat/digimon-colorful-art` · driven directly by user feedback
("digimon must look like the actual anime characters"; "english and korean
should be separated and translated well").

## What was built

- **Colorful official art** for all 70 species (digi-api renders, every URL
  fetch-verified before a line of code) replacing the 1997 LCD sprites.
- **Border flood-fill keying** (`petpng.py`, pure stdlib): only background
  white connected to the image edge goes transparent. The user's screenshot
  had exposed the old global chroma key hollowing out white body pixels —
  the new art (Angemon's wings, Yukidarumon's snow body) would have been
  destroyed by the same bug. Verified on real sprites: no interior holes.
- **Complete Korean localization**: all 70 official names from Bandai's own
  Korean reference (cross-verified — Numemon is officially 워매몬, Monzaemon
  퍼펫몬, Nanomon 데이터몬), plus per-species signature attacks in both
  languages (`아구몬의 베이비 플레임!` / `AGUMON used Baby Flame!`). The two
  unverifiable Korean attacks fall back to `필살기` — never mixed English.
- **Dual-franchise identity**: `displayName: "Claude Pet — Pokémon &
  Digimon"`; the stable plugin ID stays (user decision, informed by rename
  mechanics research: renames cost every user a manual reinstall and the
  marketplace name has no migration path).

## Engineering notes (for learning)

- **A pure-stdlib PNG codec is ~150 lines** (zlib does the heavy lifting;
  the real work is scanline unfiltering — Sub/Up/Average/Paeth). Scoped
  deliberately: 8-bit RGB/RGBA non-interlaced, ValueError contract matching
  petgif.
- **Old renderers, new format, almost no renderer changes**: the overlay
  needed a 3-line `.png` fallback (NSImage decodes PNG natively); the
  terminal needed one branch in `load_species`. The Phase 1 "renderers are
  pure views" bet keeps paying.
- **The review loop caught a real SSH regression**: 320×320 RGBA frames
  made kitty mode stream ~2.7 MB/s of *identical* payloads while idle.
  Frame-key de-duplication (species, frame, facing) cut a static sprite to
  a single 547 KB transmission — measured, not assumed.
- **Fixture discipline**: the seeded evolution branch bit my own QA twice
  (picked agumon, got betamon) — when a mechanic is deliberately random,
  pin the state file, don't fight the gacha.

## Review loop

Two rounds. Round 1 (3 Important, 4 Minor): non-atomic sprite processing
(the exact truncated-file class the download loop already guards);
kitty mode streaming ~2.7 MB/s of identical 547 KB frames while idle —
fixed with (species, frame, facing) de-dup, measured down to a single
transmission, animation preserved for multi-frame pokemon; missing
plan-mandated terminal tests; the card able to embed a raw white-background
PNG (now flood-fill-keyed on the fly, or no art at all — never a white
box); full-buffer mirroring per tick replaced by mirrored sampling (~40×
less work); shiny-variant purge gap; serial→parallel install processing.
Round 2 verified everything adversarially (including algebraic equivalence
of mirrored sampling and the multi-frame retransmit property) — PASS, with
two optional notes (card-keying test case, sprites-big tmp cleanup) also
implemented before merge.
