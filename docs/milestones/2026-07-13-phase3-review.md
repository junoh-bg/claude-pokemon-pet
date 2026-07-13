# Milestone Review — Phase 3: Digimon V-pet Mode (v0.6.0)

**Branch/PR:** `feat/phase3-digimon` · **Tests:** 6 bash suites + 27 Python tests (test-digimon.sh: 40 assertions) · verified on macOS + Debian Linux

## What was built

`claude-pokemon-pet digimon` — the five original 1997 Digital Monster V-pet
versions as a second franchise: 70 species, authentic LCD sprites, and the
V-pet's defining mechanic — **branching evolution that judges how you raised
it**.

- **Stages by daily tasks**: Baby → In-Training (2) → Rookie (5) → Champion
  (10) → Ultimate (18), then the gold cyclic EXP bar.
- **Care mistakes**: every failing tool call today (via `PostToolUseFailure`,
  user-interrupts excluded) counts. **≥3 mistakes at the moment an evolution
  fires** → the canonical joke path (Numemon, Vegimon, Scumon, Nanimon,
  Raremon — and their Ultimate continuations: yes, Numemon still becomes
  Monzaemon). Otherwise a seed-deterministic pick among the authentic normal
  branches.
- **Permanence**: each choice is recorded in the partner file at the crossing
  and never re-evaluated — your Numemon is yours until midnight, exactly like
  the 1997 device.

## How it works (for learning)

- **Data before code**: a subagent curated the evolution charts for Ver.1–5
  from Wikimon's raw wikitext (not prose summaries — the summarizer dropped
  dual-parent edges on the first pass), verified all 70 sprite URLs with real
  fetches, and collected 44 official Korean names. That file
  (`data/digimon/curation.json`) is committed as the source of truth;
  `pack.json` is generated from it.
- **One new mechanic, not a new engine**: the only core addition is
  `extend_line` — grow the partner's line by one edge per unlocked gate.
  Everything else (stage, EXP, gold bar, localized names/moves,
  `resolved.json`) is the untouched Phase 1 engine; Pokémon mode's resolved
  output is bit-identical to before.
- **Renderer purity held again**: the overlay needed *zero* changes for
  Digimon; the terminal renderer needed one 8-line function (white-keying the
  LCD sprites' opaque white background — gifsicle does the same for the
  overlay at install time).
- **Determinism as a contract**: the seeded branch pick indexes into pack
  edge order, so the generator must preserve curation-file order (jq's
  stable `group_by`) — documented in CLAUDE.md as an invariant.

## Verification

- 40 new assertions: pack integrity (70 species, edge-endpoint joins, reject
  edges), the full seeded evolution chain, the ≥3-mistakes Numemon path and
  its Monzaemon continuation, permanence under late mistakes, ko
  localization, franchise switching, cross-franchise pick (en + ko names).
- Debian container: full suite + a live Ver.3 chain
  (poyomon→tokomon→kunemon→shellmon→andromon) + statusline.
- macOS overlay smoke with a real digimon partner (white-keyed 180px sprite,
  Korean name, stage-5 instant evolution against the day's real task count).

## Review loop

(filled in after the loop completes)

## Next: Phase 4

Shinies + `pet dex`, richer HUD (speech bubble, streak flame, HP bar wired to
the same mistakes counter), Battle FX (CAEmitterLayer), evolution cinematics.
