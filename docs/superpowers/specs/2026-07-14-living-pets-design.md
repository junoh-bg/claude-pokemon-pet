# Living Pets: Character Motion + Attack FX — Design

**Date:** 2026-07-14 · **Status:** Approved (brainstorming complete)
**Driver:** user feedback — the colorful digimon are detailed but static
("they just float around with the card"), and skills deserve visuals in
both franchises.

## Goals

1. **Character life**: the sprite itself moves — for static digimon art
   especially, but pokémon benefit too.
2. **Attack visuals**: a projectile animation matched to the attack being
   named in the caption, firing on every caption rotation (~7 s) while
   Claude works. User-chosen cadence: visual and text always match; quiet
   when idle/thinking.
3. Overlay first-class; terminal adaptations; statusline unchanged.

Non-goals: pre-baked frame synthesis (rejected approach — costs disk and
install time, and NSImageView can't play PNG sequences); a wild-opponent
"battle theater" (considered, declined as screen noise).

## Approach (approved): live procedural transforms

No new assets. The overlay animates the existing sprite layer with Core
Animation transforms; the terminal fakes the same poses with row/column
offsets at its 5 fps tick.

## 1. Pose engine (overlay, `pet-overlay.js`)

| Pose | Trigger | Motion |
|---|---|---|
| breathe | always | scaleY 1.00→1.03, 3 s autoreverse loop, anchor at the sprite's feet |
| waddle | while roaming (`working`) | ±4° rotation synced to the existing 20 fps `move()` clock |
| lunge | each attack (caption slot change while working) | 250 ms dart toward facing direction + slight tilt, then back |
| recoil | daily `mistakes` count increased since last poll | 300 ms tilt-back jiggle |

Evolution keeps its existing blink. All transforms are CALayer operations
on the existing `imageView` — GPU-side, no new rendering machinery — and
every call sits in try/catch like the current FX: failure degrades to a
motionless (but alive) pet, never a broken one.

## 2. Attack FX + elements

**The core computes the element** (renderers stay dumb): `resolved.json`
gains `element`.

- pokémon: `element = type` (existing 15 types).
- digimon: keyword inference on the **English** attack name (works in ko
  mode too — inference reads the pack, not the localized caption):
  Flame/Fire/Burning/Heat→fire · Ice/Snow/Zero→ice ·
  Thunder/Electric/Shock/Spark→electric · Water/Hydro/Tidal/Wave→water ·
  Poison/Sludge/Acid/Poop→poison · Heaven/Holy→holy (gold) ·
  Death/Devil/Hell/Dark/Oblivion→dark (purple) · anything else→vpet green.

Overlay: on the caption-slot trigger (same clock as today's small burst),
fire *lunge* + a projectile — a small glowing element-colored dot
(CAShapeLayer) with an attached emitter trail, animated ~400 ms along an
arc from the sprite outward in the facing direction, ending in an impact
spark (the existing burst emitter repositioned to the endpoint). Task
completion keeps the existing big burst + window shake.

## 3. Terminal adaptations (`pet-term.py`)

- breathe: sprite block shifts down one row every ~2 s (blank-line bob).
- lunge: the pad jumps 2 columns toward facing on the attack tick.
- projectile: an element-colored `●∙∙` traveling across a dedicated line
  above the caption over 3–4 ticks, ending in `✶`.
- recoil: one invert-flash tick when mistakes rise.

## 4. Data, testing, safety

- Pack format unchanged; `element` derived in `RESOLVE_JQ` (jq `test()`
  keyword table). Unit tests per keyword class, both franchises, plus
  ko-mode (inference must not read the localized string).
- Terminal pure functions unit-tested (projectile frame rendering, element
  color mapping, bob offsets). Overlay verified by smoke + review loop, as
  established. Debian container run included.
- Performance: transforms are GPU-side; terminal adds O(1) per tick.
  All overlay FX guarded; a reduced-FX escape hatch is YAGNI for now.

## Decisions log

| Decision | Choice | Alternatives |
|---|---|---|
| Scope | Character life + attack FX | FX-only; life-only; full battle theater |
| Cadence | Every caption rotation (~7 s while working) | sparse 20–30 s; completion-only |
| Engine | Live procedural transforms (A) | pre-baked frames at install (B) |
| Element source | Core-computed from EN attack keywords | pack data field (more curation); renderer-side inference (breaks purity) |
