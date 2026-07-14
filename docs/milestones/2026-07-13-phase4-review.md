# Milestone Review — Phase 4: UI Upgrades (v0.7.0)

**Branch/PR:** `feat/phase4-ui` · **Tests:** 7 bash suites + 33 Python tests, green on macOS + Debian

## What was built

- **Shinies + dex** — the daily gacha rolls shiny at 1/64 (pokemon only,
  pack-configured; real PokeAPI shiny sprites, +151 fetched at install).
  `pet dex` shows collection progress per franchise, shiny count, and the
  dated capture list. Dex entries upgrade to shiny but never downgrade.
- **Richer HUD** — the caption pill grew a speech-bubble tail; the name line
  shows a streak flame (🔥N at 2+ consecutive days); a color-coded HP bar
  (green/yellow/red) sits under the EXP bar —
  `hp = clamp(100 − 15·mistakes + 10·tasks, 10, 100)`, computed in the core.
- **Battle FX** — type-colored particle bursts (16 type colors incl. the
  V-pet LCD green) while Claude works, a bigger burst plus window shake on
  task completion. All FX are guarded: any failure degrades to no-FX, never
  a broken pet.
- **Evolution cinematic** — sprite blink at 20 fps for 2.5 s with
  `What? X is evolving!`, then the reveal with a particle burst and
  `Congratulations! Your X evolved into Y!` (Korean with proper 은/는 and
  으로/로 josa, ㄹ-final handled). Terminal gets an invert-flash version.

## Two findings worth remembering

- **JXA bridging is not Cocoa.** The emitter code was written correctly per
  Apple docs and *silently did nothing*: a raw `CGImageRef` doesn't survive
  the JXA bridge (arrives as `NSNull` and throws inside the guarded block).
  Only an isolated probe script exposed it. `NSImage` assigned directly to
  layer contents works. Lesson: probe guarded native-bridge code in
  isolation — a try/catch that protects the app also hides the failure.
- **`stat -f` is a cross-platform trap.** BSD `stat -f %m` = format-string
  mtime; GNU `stat -f` is the boolean `--file-system` switch, so `%m` parses
  as a file operand — the command exits 1 yet still prints a filesystem
  block for the real path, and the `||` fallback concatenated both outputs,
  poisoning the staleness arithmetic on Linux (stale locks were never
  reclaimed there at all). Probing GNU `-c %Y` first with numeric
  validation fixed it; Debian 30-way stress is exactly 30/30. The BSD-first
  ordering had masked this on macOS — container QA caught what unit tests
  couldn't.

## Verification

- Full suite both platforms; live overlay gauntlet (shiny sprite, FX
  trigger paths, forced evolution cinematic) with the user's real state
  backed up and restored; QA artifacts scrubbed from the live dex.
- Emitter construction probed in isolation (the try/catch would otherwise
  mask failure).

## Review loop

(filled in after the loop completes)

## Next: Phase 5 — trainer card (`pet card`), the final phase.
