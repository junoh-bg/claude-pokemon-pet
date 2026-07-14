# Milestone Review — Living Pets (v0.10.0)

**Branch:** `feat/living-pets` · driven by user feedback: the digimon "just
float around with the card", and skills deserved visuals in both franchises.

## What was built

- **Pose engine (overlay)**: the sprite itself now breathes (always-on
  scale loop, anchored at the feet), waddles while roaming, lunges with
  every attack, and recoils when a tool call fails. Pure CALayer transform
  sub-paths on the existing image view — rotation set per tick composes
  with the running breathe animation; zero new rendering machinery.
- **Elemental attack projectiles**: the core derives an `element` for
  every attack (pokémon → type; digimon → keyword inference on the English
  attack name, so 베이비 플레임 is fire in any display language). Each
  battle-caption rotation fires a lunge plus an element-colored projectile
  arcing out with a particle trail and an impact spark.
- **Terminal versions**: row-bob breathing in calm states, a lunge dart,
  a recoil invert-flash, and a traveling `●∙∙ → ✶` projectile line —
  height-stable layout on every tier (empirically counted per state).
- **q / Esc quit for `term`** (user request mid-phase): raw-byte reader
  with a 30 ms Esc peek-ahead so arrow keys don't quit and fragmented
  multi-byte input can't freeze the loop — both failure modes were found
  by review, reproduced on a real pty, and re-verified fixed the same way.

## Engineering notes

- **Probe before wiring, again**: all five new Core Animation bridge
  patterns (keyframe values via NSMutableArray, path-following animation,
  transform sub-path KVC, anchor repositioning, infinite autoreverse) were
  verified in an isolated osascript before touching the overlay — the
  guarded try/catch blocks would have eaten any bridge failure silently.
- **No timers were added**: projectile lifecycles ride the existing 20 fps
  move() tick; the attack clock is the same 7 s caption-slot the text uses,
  so the visual and the caption can never disagree.
- **The reviewer's pty work mattered**: "q to quit" looked done after the
  happy-path test; the arrow-key and split-UTF-8 regressions only surfaced
  under adversarial terminal input. Terminal stdin is hostile territory —
  treat it like the hook path.

## Review loop

Round 1: 2 Important (arrow keys quit via the bare-Esc check; a
fragmented multi-byte character blocked the text-decode layer and froze
rendering — both reproduced on a real pty) + 2 element keyword gaps
(Icicle Rod, Volcano Strike). All fixed: raw-byte reads, Esc peek-ahead
with CSI draining, keyword additions with tests. Round 2: PASS — every
scenario re-verified on a real pty (including 10× rapid arrow repeat and
the embedded-q paste, judged pre-existing less/htop-style semantics); the
one residual note (Esc peek window under degraded links) was taken anyway,
30 ms → 75 ms.
