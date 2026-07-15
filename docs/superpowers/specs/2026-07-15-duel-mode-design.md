# Duel mode — design spec (2026-07-15)

**Approved by user:** ambient auto-battle · occasional encounters (+ on-demand
command) · win → +1 Lv + ⚔ dex entry · lose → faint until next task · HP
becomes battle-driven · streak flame → W–L record · **no projectiles, ever**
(attack FX hard rules in CLAUDE.md apply to every duel visual).

## Why

The HP bar was a dead gauge (`100 − 15·mistakes + 10·tasks` clamped — it
never meaningfully dropped) and the streak flame was furniture. Duels give
HP a reason to exist and replace the streak slot with something people care
about, while delivering the spectacle the v2 milestone originally promised.

## Architecture: pre-computed battle script

Invariant preserved: **hooks write events → core reduces state → renderers
are pure views.** A duel is not a live simulation; it is a script.

When an encounter triggers, `pet-core.sh` generates the entire fight up
front and writes it to `$CACHE/duel.json` (atomic tmp+mv):

```json
{
  "date": "2026-07-15",
  "start_ts": 1789500000,
  "end_ts":   1789500027,
  "kind": "wild",                     // or "manual"
  "opponent": { "species": "gabumon", "name": "가부몬", "level": 4,
                "element": "fire", "move": "쁘띠 파이어",
                "franchise": "digimon" },
  "turns": [
    { "t": 3,  "side": "pet", "move": "산성 거품", "dmg": 24,
      "pet_hp": 100, "foe_hp": 76 },
    { "t": 7,  "side": "foe", "move": "쁘띠 파이어", "dmg": 21,
      "pet_hp": 79,  "foe_hp": 76 }
  ],
  "result": "win",                    // derived: whoever hits 0 first
  "applied": false
}
```

- `turns[].t` = seconds after `start_ts`; first turn at t=3 (entrance
  animation), one turn every 4s, pet attacks first.
- `pet_hp`/`foe_hp` = values **after** that turn resolves.
- Renderers replay the script by wall clock. Overlay (1s poll) and terminal
  (0.2s tick) show the same fight; a renderer restarted mid-duel resumes at
  the right moment for free because timestamps are absolute.
- No timers, no daemons, no new processes.

### Determinism

All rolls come from a jq LCG (`x → (x*1103515245 + 12345) % 2^31`) seeded
with `partner.seed + tasks·7 + duels_today·13`, overridable via `PET_SEED`.
Same seed → identical fight. Every test pins the seed.

## Encounters

**Wild (ambient):** rolled inside `cmd_event done` (already under
`counter_lock`), after the task bump:

- conditions: no active duel · `duels_today < 3` · pet not fainted ·
  pack has been resolved at least once today
- roll: `LCG(seed) % 4 == 0` → ≈1 encounter per 4 completed tasks
- on trigger: generate `duel.json`, bump `$CACHE/duels_today`
  (date-stamped counter, same format as `tasks`)

**Manual:** `claude-pokemon-pet duel` (+ `/pet duel`, `/pet 대결`) generates
one immediately. Doesn't count against the 3/day cap. Refused politely if a
duel is already running, or if the pet is fainted ("complete a task to
revive"). Exit 0 with a message either way.

**Opponent selection** (same franchise as the pet, stage-matched):

- pick a random line from the pack (seeded); reroll once if it lands on the
  pet's own species
- **pokemon:** the species at index `min(pet_stage−1, line length−1)`
- **digimon:** walk `pet_stage−1` canonical steps (first edge each time)
  from the chosen line's egg — reuses the canon-first edge ordering
- level = pet's level ±2 (LCG, clamped ≥1); element/move resolved from the
  pack exactly like the pet's own (localized; unverified ko → 필살기)
- opponent sprites are already local (get-sprites.sh fetches whole packs)

**Fight generation:** both sides roll damage `18 + LCG%18` (18–35), pet gets
+4 bias (≈60% win rate at equal HP). Pet enters with its **current battle
HP**; foe enters at 100. Turns alternate until one side ≤ 0. A pet that
enters wounded can genuinely lose — that's the point.

## HP, faint, revive (replaces the dead formula)

`$CACHE/hp` = `YYYY-MM-DD <pct>` (date-stamped). Missing/stale → 100.

- duel damage **persists** after the fight (floor 5 on a win)
- task completion heals +10 (cap 100); a task that *revives* a fainted pet
  sets HP to 60 instead (no additional +10)
- lose → HP 0 + `fainted <ts>` written to the state file
- next `done` event revives: state → `done`, HP set to 60
- day rollover → fresh pet, HP 100, not fainted
- care mistakes **no longer touch HP** — they keep driving digimon care
  tiers and the recoil animation only

`RESOLVE_JQ` drops the old formula; `hp_pct` now reads the hp file.

## Outcome application (exactly once)

On any `resolve`, if `duel.json` exists with `now ≥ end_ts` and
`applied == false`:

1. take `$CACHE/.duel-apply.lock` (mkdir; **skip-on-busy is safe** because
   the holder rewrites `duel.json` with `applied: true` atomically before
   releasing — latecomers see it applied)
2. **win:** `bump_daily tasks` (+1 Lv — real EXP that feeds evolution and
   gates), add opponent to dex with `"wild": true`, `W += 1`
3. **lose:** `L += 1`, write `fainted`, HP 0
4. either way: persist final pet HP, flip `applied`, release

W–L lives in `$CACHE/duels` (`<w> <l>`, all-time). Stale-date `duel.json`
(day rollover mid-fight) is discarded unapplied.

## resolved.json additions

- `hp_pct` — battle HP (semantics above)
- `record` — `{w, l}`
- `state` — may now be `"fainted"`
- `duel` — the full script object while `now < end_ts + 6` (linger so
  renderers can play the result beat), else `null`

## Rendering

All attack visuals obey the FX hard rules: **lunge + element-tinted 4-point
star glints at the strike point; element-less (vpet) attacks lunge only; no
traveling anything.**

**Overlay (`pet-overlay.js`):**
- challenger slides in from the right (1s), gets its own name tag
  (`가부몬 Lv.4`) and HP bar; pet shifts left so both fit (widen the window
  for the duel's duration if needed, restore after)
- per turn (wall clock): attacker lunges toward the defender, star burst at
  the defender with the **attacker's** element tint, defender recoil-rocks,
  HP bars animate to the turn's values
- result beat: winner does the victory hop; on a win the foe falls + fades,
  on a loss the pet dims into the fainted pose and the foe slides out
- captions own the slot during a duel: entrance
  `야생의 가부몬이 나타났다!` / `A wild GABUMON appeared!` (needs a new
  이/가 josa helper alongside the existing 은/는 and (으)로 ones),
  per-turn `가부몬의 쁘띠 파이어!` / `GABUMON used Petit Fire!`, result
  `이겼다! +1 Lv` / `쓰러졌다… 작업을 완료하면 회복!` (and EN equivalents)
- fainted (outside duels): dimmed lying pose, caption
  `기절했다… 작업을 완료하면 회복!` / `Fainted… complete a task to revive!`
- HUD: name line shows `⚔W-L` instead of `🔥streak`

**Terminal (`pet-term.py`):**
- during a duel every backend uses the halfblock renderer (kitty/iTerm
  protocol art resumes after — dynamic two-sprite placement isn't worth
  protocol-specific paths for a 25s scene)
- pane ≥ 60 cols: pet (left, mirrored to face right) vs foe (right, facing
  left) side by side; narrower: pet sprite + text battle only
- battle log line (latest event) + two labeled HP bars
  (`깜몬 ▰▰▰▰▱  vs  가부몬 ▰▰▱▱▱`) + spark line on hit frames
- fainted: dimmed sprite + the revive caption

**Statusline:** `⚔ 깜몬 vs 가부몬` while a duel is live; normal line
otherwise (streak segment → `⚔3-1` record).

**Card/dex:** dex entries with `wild: true` render a ⚔ marker; the card
gains a record line (`⚔ 3승 1패` / `⚔ 3W–1L`).

## Concurrency & failure

- encounter roll + duel generation: inside the existing `counter_lock`
- outcome application: `.duel-apply.lock` + atomic applied-flag rewrite
- corrupt/unparseable `duel.json` → delete and continue (self-heal, same
  policy as partner)
- everything exits 0 on the hook path, as always

## Testing

- `tests/test-duel.sh`: generation determinism (PET_SEED), opponent
  stage-matching both franchises, cap 3/day, no-encounter-while-fainted,
  win path (tasks+1, dex wild flag, W bump, HP persist), lose path (faint,
  revive-on-done, HP 60), apply-exactly-once under 20-way concurrent
  resolve, stale-date discard, manual command guards
- `tests/test_term.py`: duel layout height stability, side-by-side width
  gate, HP-bar pair rendering, fainted rendering
- statusline/card/dex asserts extended
- Debian container run for the bash suites

## Out of scope (noted for later)

- cross-franchise dream matches (possible easter egg)
- move-specific choreography beyond element tint
- multi-round tournaments / trainer battles
