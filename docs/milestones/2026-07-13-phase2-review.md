# Milestone Review — Phase 2: Terminal Renderer + Statusline (v0.5.0)

**Branch/PR:** `feat/phase2-terminal-renderer` · **Tests:** 5 bash suites + 26 Python tests, all green, verified on macOS *and* Debian Linux · **Review:** PASS after two fix rounds

## What was built

Linux / SSH / RunPod support — the roadmap's #1 user ask. The pet now renders
*inside* a terminal, which means it works anywhere terminal bytes flow,
including over SSH to a headless GPU pod:

```
claude-pokemon-pet term        # in a tmux split or second SSH session
```

| Piece | What it does |
|---|---|
| `scripts/petgif.py` (~170 lines) | pure-stdlib GIF89a decoder: LZW, sub-rectangle compositing, disposal 0–3, interlace, transparency → RGBA frames |
| `scripts/pet-term.py` (~330 lines) | the renderer: backend auto-detection, alt-screen UI loop, moods/captions/EXP bar, stale-date kick of the core |
| `scripts/pet-statusline.sh` | one-line pet (`🔥 CHARMELEON Lv.12 ▰▰▰▱▱ ⚔️`) for Claude Code's statusline |
| CLI `term` / `statusline` | per-mode dependency checks — Linux needs only jq + python3 + curl |

### Graphics tiers (auto-detected, `PET_TERM_MODE` overrides)

1. **Kitty graphics protocol** (kitty, WezTerm, Ghostty) — RGBA frames streamed as base64 APC chunks, pixel-perfect animation.
2. **iTerm2 inline images** — the whole GIF is sent once; iTerm2 animates it natively.
3. **ANSI half-blocks** — `▀` glyphs with truecolor/256-color pairs; works in any terminal including inside tmux (the default there, since graphics passthrough needs opt-in tmux config).

## Key concepts (for learning)

- **Why a hand-written GIF decoder?** The hard constraint is *stdlib-only
  Python* (RunPods can't be asked to pip-install). Python's stdlib has no
  image decoding, but GIF's 1989 LZW format is small enough to implement
  correctly (~170 lines) and our sprites are tiny (41×42). Decoding the real
  55-frame charmander takes 17 ms once per species.
- **Terminal graphics are just escape sequences.** Kitty's protocol wraps
  base64 image data in APC escapes; iTerm2 uses OSC 1337. Both stream over
  SSH like ordinary output — that's the entire reason the RunPod use case
  works with zero remote-display machinery.
- **Renderer purity paid off.** The terminal renderer consumed Phase 1's
  `resolved.json` contract unchanged — zero game logic was written or
  duplicated in this phase (mood decay + caption templates are presentation,
  same as the overlay).

## Review loop findings worth remembering

Round 1 found one **Critical**: an interrupted sprite download (SSH drop —
exactly our new audience) left a truncated GIF that crashed the renderer
*silently* — the decoder threw `IndexError` (uncaught), and the cleanup
handler's `sys.exit(0)` made the re-raise dead code, so the process vanished
with exit 0. Three separate bugs conspiring: non-atomic download, wrong
exception contract, broken crash path. Fixed at all three layers (tmp+`mv`
downloads, `ValueError` normalization + placeholder degradation, loud
non-zero crash path). Plus: kitty `C=1` cursor fix, statusline no-jq
fallback, iTerm2 resend-after-clear, and decoder tests for interlace /
disposal-3 / LCT paths that Phase 3's Digimon sprites might hit.

## Verification

- Full suite green on macOS (bash 3.2 + 5.x) and in a Debian bookworm
  container (`docker run … bash tests/run.sh` → ALL PASS; core + statusline
  exercised end-to-end on Linux).
- Headless renderer smoke tests for all three backends against the live
  cache; corrupt-sprite degradation reproduced and verified fixed.

## Next: Phase 3 (Digimon)

The sprite feasibility gate is resolved: Wikimon `Special:FilePath` V-pet
GIFs (36×36, decode verified with our own petgif) as primary source; roster
+ evolution charts + Korean names are being curated with per-URL fetch
verification. V-pet branching maps daily care mistakes (from
`PostToolUseFailure`) onto authentic good/bad-care evolution paths.
