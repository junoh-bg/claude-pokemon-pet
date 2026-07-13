# Phase 1: Shared Core Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract all game logic (leveling, evolution, gacha, i18n, captions data) out of the JXA overlay into a bash+jq core that reduces hook events to `~/.cache/claude-pokemon-pet/resolved.json`, so renderers become pure views — with zero user-visible behavior change (plus new invisible state: mistakes counter, dex, streak).

**Architecture:** hooks call `pet-core.sh event <state>` → core updates counters and rewrites `resolved.json` → the overlay (and future renderers) read `resolved.json` once per second and only draw. Franchise data moves from `chains.json`+`gen1.txt`+`lang-ko.json` into a single `data/pokemon/pack.json`.

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), jq, gifsicle, JXA (existing overlay). No new runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-07-13-v2-roadmap-design.md`. One refinement vs the spec's wording: the Pokémon pack expresses evolution as `lines` (full paths) + franchise-level `gates` `[0,6,16]` rather than per-edge conditions — the degenerate form of the graph. Conditional edges arrive with the Digimon pack (Phase 3), which is the franchise that needs them. Behavior parity with v1 is the acceptance bar for this phase.

## Global Constraints

- **bash 3.2 compatible** (macOS `/bin/bash`): no `mapfile`, no `${var,,}`, no associative arrays. Arrays via `arr=($(cmd))` only.
- **Core = bash + jq only.** No Python, no Node in this phase.
- **BSD/GNU portability** for date math: `date -v-1d +%F 2>/dev/null || date -d yesterday +%F`.
- **All runtime state under `~/.cache/claude-pokemon-pet/`**; the plugin directory is never written at runtime (`scripts/dev/` is dev-time only).
- **Testability injection:** core honors `PET_TODAY` (YYYY-MM-DD), `PET_NOW` (epoch), `PET_YESTERDAY`, `PET_SEED` env overrides.
- **Behavior parity:** evolution at 6/16 tasks, daily gacha over 81 lines, eevee branch random at pick time, gold cyclic EXP bar every 10 levels after final stage, en/ko captions identical to v1.
- **Commits:** conventional commits, colon separator (`feat: …`, `fix: …`), imperative, ≤72 chars.
- All test runs use `bash tests/run.sh`; it must exit 0 before every commit.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tests/lib.sh` | create | test helpers: temp-HOME sandbox, asserts |
| `tests/run.sh` | create | runs every `tests/test-*.sh`, aggregates |
| `tests/test-pack.sh` | create | pack schema/content validation |
| `tests/test-events.sh` | create | state writes, tasks/mistakes/streak counters |
| `tests/test-partner.sh` | create | roll / roll-if-new-day / pick / lang |
| `tests/test-resolve.sh` | create | golden resolved.json cases, dex accumulation |
| `tests/fixtures/posttooluse-ok.json` | create | real captured hook payload (success) |
| `tests/fixtures/posttooluse-error.json` | create | real captured hook payload (tool error) |
| `scripts/dev/gen-pokemon-pack.sh` | create | one-off, committed: regenerates pack from v1 data |
| `data/pokemon/pack.json` | create | the Pokémon franchise pack (generated, committed) |
| `scripts/pet-core.sh` | create | THE game core (events, counters, gacha, resolve) |
| `scripts/pet-state.sh` | delete | absorbed into pet-core.sh |
| `hooks/hooks.json` | modify | hooks call pet-core.sh |
| `scripts/claude-pokemon-pet` | modify | CLI delegates game ops to core; keeps process mgmt |
| `scripts/get-sprites.sh` | modify | reads id/name + base URL from pack |
| `scripts/pet-overlay.js` | modify | reads resolved.json; deletes game logic |
| `data/chains.json`, `data/gen1.txt`, `data/lang-ko.json` | delete | folded into pack (last task, after all consumers migrated) |
| `docs/notes/2026-07-13-posttooluse-payload.md` | create | verified hook payload findings |
| `README.md`, `.claude-plugin/plugin.json` | modify | docs + version 0.4.0 |

### Cache files after Phase 1

| File | Format | Writer |
|---|---|---|
| `state` | `<state> <epoch>` (unchanged) | core |
| `tasks` | `<YYYY-MM-DD> <n>` (unchanged) | core |
| `mistakes` | `<YYYY-MM-DD> <n>` (new) | core |
| `streak` | `<YYYY-MM-DD> <count>` (new) | core |
| `partner` | JSON `{franchise, line[], type, date, seed}` (replaces `pet` + `pet-date`) | core |
| `dex.json` | JSON array `[{species, franchise, date, shiny}]` (new) | core |
| `resolved.json` | see Task 5 (new) | core |
| `lang`, `pos`, `off` | unchanged | core / overlay / CLI |

Old `pet`/`pet-date` files become harmless orphans; no migration (worst case: one fresh gacha roll after upgrade).

---

### Task 1: Test harness + Pokémon franchise pack

**Files:**
- Create: `tests/lib.sh`, `tests/run.sh`, `tests/test-pack.sh`
- Create: `scripts/dev/gen-pokemon-pack.sh`
- Create: `data/pokemon/pack.json` (generated output, committed)

**Interfaces:**
- Produces: `data/pokemon/pack.json` with shape:
  `{franchise: "pokemon", gates: [0,6,16], sprites: {base_url, target_px}, lines: [{type, mons[]}×81], species: {<slug>: {id, names: {en, ko}}}×151, moves: {<type>: [3 moves]}×15, moves_ko: {<EN MOVE>: <ko>}}`
- Produces: test helpers `setup`, `teardown`, `assert_eq <label> <expected> <actual>`, `assert_json <label> <file> <jq-filter> <expected>`, `report` — every later test file uses these.

- [ ] **Step 1: Write the test helpers**

`tests/lib.sh`:

```bash
#!/bin/bash
# Test helpers. Each test runs against a throwaway HOME so the real
# cache is never touched. Source this, then: setup … asserts … teardown; report
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/scripts/pet-core.sh"
PASSES=0 FAILS=0

setup() {
    export HOME="$(mktemp -d)"
    export CACHE="$HOME/.cache/claude-pokemon-pet"
    mkdir -p "$CACHE"
    export PET_TODAY="2026-07-13" PET_YESTERDAY="2026-07-12" PET_NOW="1789300000"
    unset PET_SEED 2>/dev/null || true
}
teardown() { rm -rf "$HOME"; }

assert_eq() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then PASSES=$((PASSES + 1)); else
        FAILS=$((FAILS + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
assert_json() { # <label> <file> <jq-filter> <expected>
    assert_eq "$1" "$4" "$(jq -r "$3" "$2" 2>&1)"
}
report() { printf -- '-- %s: pass %s fail %s\n' "$(basename "$0")" "$PASSES" "$FAILS"; [ "$FAILS" -eq 0 ]; }
```

`tests/run.sh`:

```bash
#!/bin/bash
# Runs every tests/test-*.sh; exits non-zero if any fail.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test-*.sh; do bash "$t" || rc=1; done
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$rc"
```

- [ ] **Step 2: Write the failing pack test**

`tests/test-pack.sh`:

```bash
#!/bin/bash
. "$(dirname "$0")/lib.sh"
PACK="$ROOT/data/pokemon/pack.json"

assert_eq "pack exists" "yes" "$([ -f "$PACK" ] && echo yes || echo no)"
assert_json "franchise"      "$PACK" '.franchise' "pokemon"
assert_json "gates"          "$PACK" '.gates | join(",")' "0,6,16"
assert_json "81 lines"       "$PACK" '.lines | length' "81"
assert_json "151 species"    "$PACK" '.species | length' "151"
assert_json "charmander line" "$PACK" '.lines[1].mons | join(",")' "charmander,charmeleon,charizard"
assert_json "charmander type" "$PACK" '.lines[1].type' "fire"
assert_json "sprite base"    "$PACK" '.sprites.base_url | startswith("https://raw.githubusercontent.com/PokeAPI/sprites")' "true"
assert_json "sprite px"      "$PACK" '.sprites.target_px' "190"
assert_json "min id"         "$PACK" '[.species[].id] | min' "1"
assert_json "max id"         "$PACK" '[.species[].id] | max' "151"
assert_json "en names upper" "$PACK" '.species.charmander.names.en' "CHARMANDER"
assert_json "ko names kept"  "$PACK" '.species.charmander.names.ko' "파이리"
assert_json "line species all in species map" "$PACK" \
    '. as $p | [.lines[].mons[]] | unique | map(select($p.species[.] == null)) | length' "0"
assert_json "15 move types"  "$PACK" '.moves | length' "15"
assert_json "3 moves per type" "$PACK" '[.moves[] | length] | unique | join(",")' "3"
assert_json "ko move translation" "$PACK" '.moves_ko["TACKLE"]' "몸통박치기"
report
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run.sh`
Expected: `FAIL: pack exists` (and cascade), exit 1.

- [ ] **Step 4: Write the generator**

`scripts/dev/gen-pokemon-pack.sh`:

```bash
#!/bin/bash
# Dev-time only: regenerates data/pokemon/pack.json from the v1 data files
# (data/chains.json, data/gen1.txt, data/lang-ko.json). Kept for provenance.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p data/pokemon

ids=$(awk '{printf "{\"key\":\"%s\",\"value\":%s}\n", $2, $1}' data/gen1.txt | jq -s 'from_entries')

jq -n --argjson ids "$ids" \
      --slurpfile chains data/chains.json \
      --slurpfile ko data/lang-ko.json '
  ($chains[0]) as $c | ($ko[0]) as $k |
  {
    franchise: "pokemon",
    gates: [0, 6, 16],
    sprites: {
      base_url: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated",
      target_px: 190
    },
    lines: $c,
    species: ($ids | to_entries | map({
        key: .key,
        value: { id: .value,
                 names: { en: (.key | ascii_upcase),
                          ko: ($k.names[.key] // null) } }
      }) | from_entries),
    moves: {
      normal:   ["TACKLE", "BODY SLAM", "HYPER BEAM"],
      fire:     ["EMBER", "FLAMETHROWER", "FIRE BLAST"],
      water:    ["WATER GUN", "SURF", "HYDRO PUMP"],
      grass:    ["VINE WHIP", "RAZOR LEAF", "SOLAR BEAM"],
      electric: ["THUNDER SHOCK", "THUNDERBOLT", "THUNDER"],
      psychic:  ["CONFUSION", "PSYBEAM", "PSYCHIC"],
      fighting: ["KARATE CHOP", "SEISMIC TOSS", "SUBMISSION"],
      rock:     ["ROCK THROW", "ROCK SLIDE", "EARTHQUAKE"],
      ground:   ["DIG", "BONE CLUB", "EARTHQUAKE"],
      poison:   ["POISON STING", "ACID", "SLUDGE"],
      bug:      ["LEECH LIFE", "PIN MISSILE", "TWINEEDLE"],
      flying:   ["GUST", "WING ATTACK", "DRILL PECK"],
      ghost:    ["LICK", "NIGHT SHADE", "DREAM EATER"],
      ice:      ["AURORA BEAM", "ICE BEAM", "BLIZZARD"],
      dragon:   ["DRAGON RAGE", "SLAM", "HYPER BEAM"]
    },
    moves_ko: $k.moves
  }' > data/pokemon/pack.json
echo "wrote data/pokemon/pack.json ($(jq '.species | length' data/pokemon/pack.json) species)"
```

The `moves` table is copied verbatim from `TYPE_MOVES` in `scripts/pet-overlay.js:22-38` — it must stay character-identical (captions parity).

- [ ] **Step 5: Generate and verify tests pass**

Run: `chmod +x scripts/dev/gen-pokemon-pack.sh tests/run.sh && bash scripts/dev/gen-pokemon-pack.sh && bash tests/run.sh`
Expected: `wrote data/pokemon/pack.json (151 species)`, then `ALL PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/ scripts/dev/gen-pokemon-pack.sh data/pokemon/pack.json
git commit -m "feat: pokémon franchise pack + test harness"
```

---

### Task 2: Verify the PostToolUse hook payload (spec-mandated first gate)

**Files:**
- Create: `tests/fixtures/posttooluse-ok.json`, `tests/fixtures/posttooluse-error.json`
- Create: `docs/notes/2026-07-13-posttooluse-payload.md`

**Interfaces:**
- Produces: two REAL captured payload fixtures used by Task 3's mistake-detection tests, and a written verdict: does PostToolUse fire on failing tool calls, and which field(s) mark failure? Task 3's `MISTAKE_FILTER` is finalized from this.

- [ ] **Step 1: Ask the claude-code-guide agent** (model: sonnet) whether PostToolUse fires for failing tool calls and what `tool_response` contains for a failed Bash command (non-zero exit), per current docs/changelog.

- [ ] **Step 2: Capture real payloads empirically.** Create a probe project:

```bash
mkdir -p "$CLAUDE_JOB_DIR/tmp/hookprobe/.claude"
cat > "$CLAUDE_JOB_DIR/tmp/hookprobe/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "cat >> \"$CLAUDE_PROJECT_DIR/dump.jsonl\"" }
      ] }
    ]
  }
}
EOF
cd "$CLAUDE_JOB_DIR/tmp/hookprobe"
claude -p "Run exactly this bash command: bash -c 'exit 7'. After it finishes (even if it fails), run exactly: echo probe-ok" --allowedTools Bash --max-turns 6
cat dump.jsonl | jq -c '{tool_name, tool_response}'
```

Expected: one line for `echo probe-ok` (success shape) and — if PostToolUse fires on errors — one for the `exit 7` call (error shape).

- [ ] **Step 3: Save fixtures.** Copy the success payload to `tests/fixtures/posttooluse-ok.json` and the failing payload to `tests/fixtures/posttooluse-error.json` (full single-event JSON objects, pretty-printed with `jq .`). If NO error event was captured, synthesize `posttooluse-error.json` from the documented shape found in Step 1 and mark it `"_synthetic": true`.

- [ ] **Step 4: Write the findings note** `docs/notes/2026-07-13-posttooluse-payload.md`: does the event fire on failure (yes/no), the exact failure-marking fields, the final jq filter expression, and — if failure is NOT observable — the recorded decision from the spec: Digimon branching degrades to per-day seeded random and the HP bar is dropped in Phase 4.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures docs/notes/2026-07-13-posttooluse-payload.md
git commit -m "docs: verify PostToolUse payload shape for care-mistake detection"
```

---

### Task 3: pet-core.sh — events and counters

**Files:**
- Create: `scripts/pet-core.sh` (events/counters part; resolve arrives in Task 5 — until then a stub `cmd_resolve() { :; }` keeps it runnable)
- Test: `tests/test-events.sh`

**Interfaces:**
- Consumes: `tests/fixtures/posttooluse-*.json` (Task 2), test helpers (Task 1).
- Produces: `pet-core.sh event <hello|thinking|working|done|waiting|idle>` — writes `state`, bumps `tasks`+`streak` on `done`, bumps `mistakes` on `working` when stdin payload marks a tool failure. Helper functions `read_daily <file>`, `bump_daily <file>`, `read_streak`, `update_streak` reused by Task 5.

- [ ] **Step 1: Write the failing tests**

`tests/test-events.sh`:

```bash
#!/bin/bash
. "$(dirname "$0")/lib.sh"

setup
"$CORE" event thinking </dev/null >/dev/null
assert_eq "state written" "thinking 1789300000" "$(cat "$CACHE/state")"

"$CORE" event done </dev/null >/dev/null
assert_eq "task counted" "2026-07-13 1" "$(cat "$CACHE/tasks")"
"$CORE" event done </dev/null >/dev/null
assert_eq "task counted twice" "2026-07-13 2" "$(cat "$CACHE/tasks")"
assert_eq "streak starts at 1" "2026-07-13 1" "$(cat "$CACHE/streak")"
teardown

setup  # streak continues from yesterday
echo "2026-07-12 3" > "$CACHE/streak"
"$CORE" event done </dev/null >/dev/null
assert_eq "streak continues" "2026-07-13 4" "$(cat "$CACHE/streak")"
teardown

setup  # streak resets after a gap
echo "2026-07-10 9" > "$CACHE/streak"
"$CORE" event done </dev/null >/dev/null
assert_eq "streak resets" "2026-07-13 1" "$(cat "$CACHE/streak")"
teardown

setup  # stale tasks file from another day resets
echo "2026-07-12 7" > "$CACHE/tasks"
"$CORE" event done </dev/null >/dev/null
assert_eq "stale tasks reset" "2026-07-13 1" "$(cat "$CACHE/tasks")"
teardown

setup  # mistakes: error payload bumps, ok payload doesn't
"$CORE" event working < "$ROOT/tests/fixtures/posttooluse-error.json" >/dev/null
assert_eq "mistake counted" "2026-07-13 1" "$(cat "$CACHE/mistakes")"
"$CORE" event working < "$ROOT/tests/fixtures/posttooluse-ok.json" >/dev/null
assert_eq "ok payload not counted" "2026-07-13 1" "$(cat "$CACHE/mistakes")"
"$CORE" event working </dev/null >/dev/null
assert_eq "empty stdin not counted" "2026-07-13 1" "$(cat "$CACHE/mistakes")"
"$CORE" event working <<< 'not json at all' >/dev/null
assert_eq "garbage stdin not counted" "2026-07-13 1" "$(cat "$CACHE/mistakes")"
teardown

report
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh`
Expected: test-events failures (`pet-core.sh: No such file`), exit 1.

- [ ] **Step 3: Write pet-core.sh (events part)**

`scripts/pet-core.sh`:

```bash
#!/bin/bash
# pet-core.sh — the game core. Hooks and the CLI write events through here;
# after every mutation it re-resolves the pet into resolved.json, which every
# renderer (overlay, terminal, statusline) reads as a pure view.
# Usage: pet-core.sh <event <state>|roll|roll-if-new-day|pick <name>|lang <ko|en|auto>|resolve|status>
# Test overrides: PET_TODAY, PET_YESTERDAY, PET_NOW, PET_SEED.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
mkdir -p "$CACHE"

TODAY="${PET_TODAY:-$(date +%F)}"
NOW="${PET_NOW:-$(date +%s)}"
[ -n "${PET_SEED:-}" ] && RANDOM="$PET_SEED"

# ── daily counters: files hold "<date> <n>"; other days read as 0 ──
read_daily() {
    local d c
    if [ -f "$CACHE/$1" ]; then
        read -r d c < "$CACHE/$1"
        [ "$d" = "$TODAY" ] && { echo "${c:-0}"; return; }
    fi
    echo 0
}
bump_daily() { printf '%s %s\n' "$TODAY" "$(( $(read_daily "$1") + 1 ))" > "$CACHE/$1"; }

# ── streak: consecutive days with ≥1 completed task ──
yesterday() { echo "${PET_YESTERDAY:-$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)}"; }
update_streak() {
    local d c
    d=""; c=0
    [ -f "$CACHE/streak" ] && read -r d c < "$CACHE/streak"
    if [ "$d" = "$TODAY" ]; then return 0
    elif [ "$d" = "$(yesterday)" ]; then printf '%s %s\n' "$TODAY" "$(( ${c:-0} + 1 ))" > "$CACHE/streak"
    else printf '%s 1\n' "$TODAY" > "$CACHE/streak"; fi
}
read_streak() {
    local d c
    [ -f "$CACHE/streak" ] || { echo 0; return; }
    read -r d c < "$CACHE/streak"
    if [ "$d" = "$TODAY" ] || [ "$d" = "$(yesterday)" ]; then echo "${c:-0}"; else echo 0; fi
}

# ── care mistakes: a failing tool call in the PostToolUse payload ──
# Filter finalized in docs/notes/2026-07-13-posttooluse-payload.md (Task 2).
MISTAKE_FILTER='.tool_response as $r
  | ($r.is_error? == true)
    or ((($r | type) == "object") and ($r | has("success")) and ($r.success == false))'
check_stdin_mistake() {
    [ -t 0 ] && return 0
    local payload
    payload="$(cat 2>/dev/null)" || return 0
    [ -n "$payload" ] || return 0
    printf '%s' "$payload" | jq -e "$MISTAKE_FILTER" >/dev/null 2>&1 && bump_daily mistakes
    return 0
}

cmd_event() {
    local ev="${1:-idle}"
    printf '%s %s\n' "$ev" "$NOW" > "$CACHE/state"
    case "$ev" in
        done)    update_streak; bump_daily tasks ;;
        working) check_stdin_mistake ;;
    esac
    cmd_resolve
}

cmd_resolve() { :; }   # stub — implemented in a later task

case "${1:-}" in
    event) cmd_event "${2:-idle}" ;;
    resolve) cmd_resolve ;;
    *) echo "usage: pet-core.sh <event <state>|resolve>" >&2; exit 1 ;;
esac
```

**Adjust `MISTAKE_FILTER` to whatever Task 2 verified** — the expression above is the default hypothesis; the fixtures are the source of truth. `chmod +x scripts/pet-core.sh`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/pet-core.sh tests/test-events.sh
git commit -m "feat: pet-core event recording with tasks, streak, care-mistake counters"
```

---

### Task 4: pet-core.sh — partner ops (roll, pick, lang)

**Files:**
- Modify: `scripts/pet-core.sh`
- Test: `tests/test-partner.sh`

**Interfaces:**
- Consumes: `data/pokemon/pack.json` (Task 1), counters (Task 3).
- Produces: subcommands `roll`, `roll-if-new-day`, `pick <name>`, `lang <ko|en|auto>`; the `partner` cache file `{franchise, line[], type, date, seed}`; helpers `pack_file <franchise>`, `active_franchise`, `cur_lang`, `default_partner` reused by Task 5.

- [ ] **Step 1: Write the failing tests**

`tests/test-partner.sh`:

```bash
#!/bin/bash
. "$(dirname "$0")/lib.sh"

setup  # roll writes a valid partner deterministically
PET_SEED=7 "$CORE" roll >/dev/null
assert_json "partner franchise" "$CACHE/partner" '.franchise' "pokemon"
assert_json "partner date"      "$CACHE/partner" '.date' "2026-07-13"
assert_json "line non-empty"    "$CACHE/partner" '.line | length >= 1' "true"
first="$(jq -r '.line[0]' "$CACHE/partner")"
PET_SEED=7 "$CORE" roll >/dev/null
assert_eq "roll deterministic under PET_SEED" "$first" "$(jq -r '.line[0]' "$CACHE/partner")"
teardown

setup  # roll-if-new-day: same day keeps, new day rerolls
PET_SEED=7 "$CORE" roll >/dev/null
sig="$(jq -c . "$CACHE/partner")"
"$CORE" roll-if-new-day >/dev/null
assert_eq "same day keeps partner" "$sig" "$(jq -c . "$CACHE/partner")"
PET_TODAY="2026-07-14" "$CORE" roll-if-new-day >/dev/null
assert_json "new day rerolls" "$CACHE/partner" '.date' "2026-07-14"
teardown

setup  # pick by english name
"$CORE" pick pikachu >/dev/null
assert_json "pikachu line found" "$CACHE/partner" '.line | index("pikachu") != null' "true"
teardown

setup  # pick by korean name
"$CORE" pick 파이리 >/dev/null
assert_json "korean pick resolves" "$CACHE/partner" '.line[0]' "charmander"
teardown

setup  # eevee always yields a 2-stage branch containing eevee
"$CORE" pick eevee >/dev/null
assert_json "eevee branch rolled" "$CACHE/partner" '.line[0]' "eevee"
assert_json "eevee branch has 2 stages" "$CACHE/partner" '.line | length' "2"
teardown

setup  # unknown name errors
if "$CORE" pick notapokemon >/dev/null 2>&1; then rc=0; else rc=1; fi
assert_eq "unknown pick exits 1" "1" "$rc"
teardown

setup  # lang override + auto
"$CORE" lang ko >/dev/null
assert_eq "lang file written" "ko" "$(cat "$CACHE/lang")"
"$CORE" lang auto >/dev/null
assert_eq "lang file removed" "no" "$([ -f "$CACHE/lang" ] && echo yes || echo no)"
if "$CORE" lang xx >/dev/null 2>&1; then rc=0; else rc=1; fi
assert_eq "bad lang exits 1" "1" "$rc"
teardown

report
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh`
Expected: test-partner failures (`usage: pet-core.sh …`), exit 1.

- [ ] **Step 3: Implement partner ops.** Add to `scripts/pet-core.sh` (above the `case` dispatcher; extend the dispatcher too):

```bash
# ── partner (the rolled line) ──
pack_file() { echo "$ROOT/data/${1:-pokemon}/pack.json"; }
active_franchise() { jq -r '.franchise // "pokemon"' "$CACHE/partner" 2>/dev/null || echo pokemon; }

default_partner() {   # safe fallback, mirrors v1's chains[1] = charmander
    jq -n --arg d "$TODAY" \
      '{franchise: "pokemon", line: ["charmander","charmeleon","charizard"], type: "fire", date: $d, seed: 0}' \
      > "$CACHE/partner"
}

write_partner() { # <pack-file> <line-index>
    local tmp; tmp="$(mktemp)"
    jq --argjson i "$2" --arg d "$TODAY" --argjson s "$RANDOM" \
       '{franchise: .franchise, line: .lines[$i].mons, type: .lines[$i].type, date: $d, seed: $s}' \
       "$1" > "$tmp" && mv "$tmp" "$CACHE/partner"
    cmd_resolve
    echo "pet: $(jq -r '.line | join(" → ")' "$CACHE/partner")"
}

cmd_roll() {
    local pack n
    pack="$(pack_file "$(active_franchise)")"
    n="$(jq '.lines | length' "$pack")"
    write_partner "$pack" $(( RANDOM % n ))
}

cmd_roll_if_new_day() {
    [ "$(jq -r '.date // empty' "$CACHE/partner" 2>/dev/null)" = "$TODAY" ] || cmd_roll
}

cmd_pick() {
    local name="${1:-}" pack eng
    pack="$(pack_file pokemon)"
    # korean names resolve to their english slug first
    eng="$(jq -r --arg k "$name" \
        '.species | to_entries[] | select(.value.names.ko == $k) | .key' "$pack" | head -1)"
    [ -n "$eng" ] && name="$eng"
    # any line containing the name; random among matches (eevee branches)
    idxs=($(jq -r --arg m "$name" \
        '.lines | to_entries[] | select(.value.mons | index($m)) | .key' "$pack"))
    if [ ${#idxs[@]} -eq 0 ]; then
        echo "unknown gen-1 pokémon: ${1:-?}" >&2
        exit 1
    fi
    write_partner "$pack" "${idxs[RANDOM % ${#idxs[@]}]}"
}

# ── language: override file wins, else system ──
cur_lang() {
    local o
    o="$(cat "$CACHE/lang" 2>/dev/null)"
    case "$o" in ko|en) echo "$o"; return ;; esac
    case "${LC_ALL:-${LANG:-}}" in ko*) echo ko; return ;; esac
    if defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q ko; then
        echo ko
    else
        echo en
    fi
}

cmd_lang() {
    case "${1:-}" in
        ko|en) echo "$1" > "$CACHE/lang"; echo "language: $1" ;;
        auto)  rm -f "$CACHE/lang"; echo "language: auto (system)" ;;
        *)     echo "usage: pet-core.sh lang <ko|en|auto>" >&2; exit 1 ;;
    esac
    cmd_resolve
}
```

Dispatcher becomes:

```bash
case "${1:-}" in
    event)           cmd_event "${2:-idle}" ;;
    roll)            cmd_roll ;;
    roll-if-new-day) cmd_roll_if_new_day ;;
    pick)            cmd_pick "${2:-}" ;;
    lang)            cmd_lang "${2:-}" ;;
    resolve)         cmd_resolve ;;
    *) echo "usage: pet-core.sh <event <state>|roll|roll-if-new-day|pick <name>|lang <ko|en|auto>|resolve>" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/pet-core.sh tests/test-partner.sh
git commit -m "feat: pet-core partner ops — gacha roll, pick by name, language"
```

---

### Task 5: pet-core.sh — resolve + dex

**Files:**
- Modify: `scripts/pet-core.sh` (replace the `cmd_resolve` stub; add `status` subcommand)
- Test: `tests/test-resolve.sh`

**Interfaces:**
- Consumes: pack (Task 1), counters (Task 3), partner helpers (Task 4).
- Produces: `resolved.json` — THE renderer contract:

```json
{
  "franchise": "pokemon", "species": "charmeleon", "name": "CHARMELEON",
  "type": "fire", "stage": 2, "stages": 3, "final": false,
  "tasks": 7, "mistakes": 1, "streak": 3, "shiny": false,
  "exp_pct": 10, "exp_gold": false,
  "line": ["charmander", "charmeleon", "charizard"],
  "line_names": ["CHARMANDER", "CHARMELEON", "CHARIZARD"],
  "moves": ["EMBER", "FLAMETHROWER", "FIRE BLAST"],
  "lang": "en", "state": "working", "state_ts": 1789300000
}
```

`shiny` is always `false` in Phase 1 (field reserved; the roll arrives in Phase 4). `exp_pct` is 0–100; `exp_gold: true` means the final-stage cyclic gold bar. Also produces `dex.json` accumulation and `pet-core.sh status`.

- [ ] **Step 1: Write the failing tests**

`tests/test-resolve.sh`:

```bash
#!/bin/bash
. "$(dirname "$0")/lib.sh"
R() { jq -r "$1" "$CACHE/resolved.json"; }
set_tasks() { echo "2026-07-13 $1" > "$CACHE/tasks"; }
charmander_partner() {
    printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0}' > "$CACHE/partner"
}

setup  # stage/exp progression across the charmander line
charmander_partner
set_tasks 0; "$CORE" resolve
assert_eq "t0 species"  "charmander" "$(R .species)"
assert_eq "t0 stage"    "1"          "$(R .stage)"
assert_eq "t0 exp"      "0"          "$(R .exp_pct)"
assert_eq "t0 gold"     "false"      "$(R .exp_gold)"
set_tasks 5; "$CORE" resolve
assert_eq "t5 species"  "charmander" "$(R .species)"
assert_eq "t5 exp"      "83"         "$(R .exp_pct)"
set_tasks 6; "$CORE" resolve
assert_eq "t6 species"  "charmeleon" "$(R .species)"
assert_eq "t6 stage"    "2"          "$(R .stage)"
assert_eq "t6 exp"      "0"          "$(R .exp_pct)"
set_tasks 15; "$CORE" resolve
assert_eq "t15 exp"     "90"         "$(R .exp_pct)"
set_tasks 16; "$CORE" resolve
assert_eq "t16 species" "charizard"  "$(R .species)"
assert_eq "t16 final"   "true"       "$(R .final)"
assert_eq "t16 gold"    "true"       "$(R .exp_gold)"
assert_eq "t16 exp"     "0"          "$(R .exp_pct)"
set_tasks 23; "$CORE" resolve
assert_eq "t23 gold cycles" "70"     "$(R .exp_pct)"
teardown

setup  # 2-stage line goes final at 6 with gold base 6
printf '{"franchise":"pokemon","line":["zubat","golbat"],"type":"poison","date":"2026-07-13","seed":0}' > "$CACHE/partner"
set_tasks 6; "$CORE" resolve
assert_eq "2-stage final at 6" "golbat" "$(R .species)"
assert_eq "2-stage gold"       "true"   "$(R .exp_gold)"
set_tasks 9; "$CORE" resolve
assert_eq "2-stage gold pct"   "30"     "$(R .exp_pct)"
teardown

setup  # 1-stage line is final from task 0
printf '{"franchise":"pokemon","line":["tauros"],"type":"normal","date":"2026-07-13","seed":0}' > "$CACHE/partner"
set_tasks 3; "$CORE" resolve
assert_eq "1-stage species" "tauros" "$(R .species)"
assert_eq "1-stage gold pct" "30"    "$(R .exp_pct)"
teardown

setup  # korean localization of names and moves
charmander_partner
echo ko > "$CACHE/lang"
set_tasks 0; "$CORE" resolve
assert_eq "ko name"       "파이리"    "$(R .name)"
assert_eq "ko lang field" "ko"        "$(R .lang)"
assert_eq "ko move"       "불꽃세례"  "$(R '.moves[0]')"
teardown

setup  # english defaults
charmander_partner
set_tasks 0; "$CORE" resolve
assert_eq "en name"  "CHARMANDER" "$(R .name)"
assert_eq "en move"  "EMBER"      "$(R '.moves[0]')"
assert_eq "line names" "CHARMANDER,CHARMELEON,CHARIZARD" "$(R '.line_names | join(",")')"
teardown

setup  # state passthrough + counters land in resolved.json
charmander_partner
"$CORE" event working </dev/null
assert_eq "state in resolved"    "working"    "$(R .state)"
assert_eq "state_ts in resolved" "1789300000" "$(R .state_ts)"
"$CORE" event done </dev/null
assert_eq "tasks in resolved"   "1" "$(R .tasks)"
assert_eq "streak in resolved"  "1" "$(R .streak)"
assert_eq "shiny reserved"      "false" "$(R .shiny)"
teardown

setup  # missing partner falls back to charmander line
set_tasks 0; "$CORE" resolve
assert_eq "fallback species" "charmander" "$(R .species)"
teardown

setup  # dex accumulates unique species across evolutions
charmander_partner
set_tasks 0; "$CORE" resolve
set_tasks 6; "$CORE" resolve
set_tasks 6; "$CORE" resolve
assert_eq "dex has both, deduped" "charmander,charmeleon" \
    "$(jq -r 'map(.species) | join(",")' "$CACHE/dex.json")"
assert_eq "dex records franchise" "pokemon" "$(jq -r '.[0].franchise' "$CACHE/dex.json")"
teardown

setup  # status prints a summary
charmander_partner
set_tasks 7; "$CORE" resolve
out="$("$CORE" status)"
case "$out" in *CHARMELEON*) ok=yes ;; *) ok=no ;; esac
assert_eq "status mentions current form" "yes" "$ok"
teardown

report
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh`
Expected: test-resolve failures (resolved.json missing — stub does nothing), exit 1.

- [ ] **Step 3: Implement resolve.** Replace the stub in `scripts/pet-core.sh`:

```bash
# ── resolve: reduce pack + partner + counters to resolved.json ──
RESOLVE_JQ='
  ($pk[0]) as $pack | ($pt[0]) as $p |
  ($pack.gates) as $g |
  ($p.line) as $line | ($line | length) as $len |
  ([$g[] | select(. <= $tasks)] | length) as $reach |
  ([([$reach, 1] | max), $len] | min) as $stage |
  $line[$stage - 1] as $sp |
  ($stage == $len) as $final |
  ($g[$stage - 1] // 0) as $base |
  (if $final then ((($tasks - $base) % 10) * 10)
   else ((($tasks - $base) * 100 / ($g[$stage] - $base)) | floor)
   end) as $pct |
  ($pack.species[$sp]) as $spec |
  (if $lang == "ko" then ($spec.names.ko // $spec.names.en) else $spec.names.en end) as $name |
  ($pack.moves[$p.type] // $pack.moves.normal) as $mv |
  {
    franchise: $p.franchise, species: $sp, name: $name, type: $p.type,
    stage: $stage, stages: $len, final: $final,
    tasks: $tasks, mistakes: $mistakes, streak: $streak, shiny: false,
    exp_pct: $pct, exp_gold: $final,
    line: $line,
    line_names: ($line | map($pack.species[.] as $s |
        if $lang == "ko" then ($s.names.ko // $s.names.en) else $s.names.en end)),
    moves: (if $lang == "ko" then ($mv | map($pack.moves_ko[.] // .)) else $mv end),
    lang: $lang, state: $state, state_ts: $ts
  }'

update_dex() {
    [ -f "$CACHE/dex.json" ] || echo '[]' > "$CACHE/dex.json"
    local sp fr tmp
    sp="$(jq -r '.species' "$CACHE/resolved.json")"
    fr="$(jq -r '.franchise' "$CACHE/resolved.json")"
    tmp="$(mktemp)"
    jq --arg s "$sp" --arg f "$fr" --arg d "$TODAY" \
       'if any(.[]; .species == $s and .franchise == $f) then .
        else . + [{species: $s, franchise: $f, date: $d, shiny: false}] end' \
       "$CACHE/dex.json" > "$tmp" && mv "$tmp" "$CACHE/dex.json"
}

cmd_resolve() {
    [ -f "$CACHE/partner" ] || default_partner
    local pack tasks mistakes streak lang state ts tmp
    pack="$(pack_file "$(active_franchise)")"
    tasks="$(read_daily tasks)"
    mistakes="$(read_daily mistakes)"
    streak="$(read_streak)"
    lang="$(cur_lang)"
    state=idle; ts="$NOW"
    [ -f "$CACHE/state" ] && read -r state ts < "$CACHE/state"
    tmp="$(mktemp)"
    jq -n --slurpfile pk "$pack" --slurpfile pt "$CACHE/partner" \
       --argjson tasks "$tasks" --argjson mistakes "$mistakes" --argjson streak "$streak" \
       --arg lang "$lang" --arg state "$state" --argjson ts "${ts:-0}" \
       "$RESOLVE_JQ" > "$tmp" && mv "$tmp" "$CACHE/resolved.json"
    update_dex
}

cmd_status() {
    [ -f "$CACHE/resolved.json" ] || cmd_resolve
    jq -r '"partner: \(.line | join(" → "))",
           "now:     \(.name) (stage \(.stage)/\(.stages))",
           "state:   \(.state)",
           "tasks:   \(.tasks) today · mistakes: \(.mistakes) · streak: \(.streak)d",
           "lang:    \(.lang)"' "$CACHE/resolved.json"
}
```

Note the ordering constraint: `default_partner`/`pack_file`/`active_franchise`/`cur_lang` (Task 4) must be defined before these in the file; `cmd_resolve` here **replaces** the Task 3 stub entirely. Add `status) cmd_status ;;` to the dispatcher.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: `ALL PASS` (all four test files), exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/pet-core.sh tests/test-resolve.sh
git commit -m "feat: pet-core resolve — renderer contract resolved.json + dex"
```

---

### Task 6: Rewire hooks, CLI, and sprite fetcher to the core

**Files:**
- Modify: `hooks/hooks.json`
- Modify: `scripts/claude-pokemon-pet`
- Modify: `scripts/get-sprites.sh`
- Delete: `scripts/pet-state.sh`

**Interfaces:**
- Consumes: every `pet-core.sh` subcommand (Tasks 3–5).
- Produces: unchanged user-facing CLI surface (`toggle|on|off|random|pet <name>|lang|sprites|status|autostart`) now backed by the core; hooks feed the core (PostToolUse payload flows into stdin untouched).

- [ ] **Step 1: Rewrite hooks.json** — full new content:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/pet-core.sh event hello", "timeout": 5, "async": true },
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/claude-pokemon-pet autostart", "timeout": 120, "async": true }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/pet-core.sh event thinking", "timeout": 5, "async": true }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/pet-core.sh event working", "timeout": 5, "async": true }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/pet-core.sh event done", "timeout": 5, "async": true }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/pet-core.sh event waiting", "timeout": 5, "async": true }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Rewrite the CLI.** In `scripts/claude-pokemon-pet`: keep the header, `pid`/`stop`/`launch` exactly as they are; replace `CHAINS=`, `set_chain`, and the game-op cases. New content for the changed parts:

```bash
CORE="$ROOT/scripts/pet-core.sh"

start() {
    for dep in jq gifsicle osascript; do
        command -v "$dep" >/dev/null || { echo "claude-pokemon-pet: missing dependency: $dep (brew install jq gifsicle)" >&2; exit 1; }
    done
    [ -f "$CACHE/sprites-big/mew.gif" ] || "$ROOT/scripts/get-sprites.sh"
    # Daily gacha: roll a new partner on the first start of the day.
    "$CORE" roll-if-new-day
    launch
    echo "overlay: on"
}

case "${1:-toggle}" in
    toggle)    if [ -n "$(pid)" ]; then touch "$CACHE/off"; stop; else rm -f "$CACHE/off"; start; fi ;;
    on)        rm -f "$CACHE/off"; [ -n "$(pid)" ] || start ;;
    off)       touch "$CACHE/off"; stop ;;
    autostart) [ -f "$CACHE/off" ] || [ -n "$(pid)" ] || start ;;
    random)    "$CORE" roll ;;
    pet)       "$CORE" pick "${2:-}" ;;
    lang)      "$CORE" lang "${2:-}" ;;
    sprites)   exec "$ROOT/scripts/get-sprites.sh" ;;
    status)
        echo "overlay: $([ -n "$(pid)" ] && echo "on (pid $(pid))" || echo off)"
        "$CORE" status
        ;;
    *)
        echo "usage: claude-pokemon-pet [toggle|on|off|random|pet <name>|lang <ko|en|auto>|sprites|status]" >&2
        exit 1
        ;;
esac
```

Delete `scripts/pet-state.sh` (`git rm scripts/pet-state.sh`).

- [ ] **Step 3: Rewire get-sprites.sh to the pack.** Full new content:

```bash
#!/bin/bash
# Download gen-1 animated sprites (source configured in the franchise pack)
# into the cache and build upscaled (nearest-neighbor) + mirrored variants.
# Idempotent.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
PACK="$ROOT/data/pokemon/pack.json"
BASE="$(jq -r '.sprites.base_url' "$PACK")"
TARGET="$(jq -r '.sprites.target_px' "$PACK")"
mkdir -p "$CACHE/sprites" "$CACHE/sprites-big"

jq -r '.species | to_entries[] | "\(.value.id) \(.key)"' "$PACK" > "$CACHE/.sprite-ids"
i=0
while read -r id name; do
    [ -f "$CACHE/sprites/$name.gif" ] && continue
    curl -sfL "$BASE/$id.gif" -o "$CACHE/sprites/$name.gif" &
    i=$((i + 1)); [ $((i % 10)) -eq 0 ] && wait
done < "$CACHE/.sprite-ids"
wait
rm -f "$CACHE/.sprite-ids"
echo "sprites: $(ls "$CACHE/sprites" | wc -l | tr -d ' ')"

for g in "$CACHE/sprites"/*.gif; do
    mon=$(basename "$g" .gif)
    [ -f "$CACHE/sprites-big/$mon.gif" ] && continue
    dims=$(gifsicle --info "$g" | grep -m1 'logical screen' | grep -oE '[0-9]+x[0-9]+')
    w=${dims%x*}; h=${dims#*x}
    max=$(( w > h ? w : h ))
    scale=$(( TARGET / max )); [ "$scale" -lt 2 ] && scale=2
    gifsicle --resize-method sample --scale "$scale" "$g" -o "$CACHE/sprites-big/$mon.gif"
    gifsicle --flip-horizontal "$CACHE/sprites-big/$mon.gif" -o "$CACHE/sprites-big/$mon-flip.gif"
done
echo "big: $(ls "$CACHE/sprites-big" | wc -l | tr -d ' ')"
```

- [ ] **Step 4: Verify end-to-end from a clean sandbox**

```bash
bash tests/run.sh
# CLI smoke test in a sandbox HOME (no overlay launch — osascript not touched):
H="$(mktemp -d)"; HOME="$H" scripts/pet-core.sh roll; HOME="$H" scripts/pet-core.sh event done </dev/null
HOME="$H" scripts/claude-pokemon-pet status
rm -rf "$H"
```

Expected: `ALL PASS`; status prints `overlay: off`, a `partner:` line, `tasks: 1 today · mistakes: 0 · streak: 1d`.

- [ ] **Step 5: Commit**

```bash
git add hooks/hooks.json scripts/claude-pokemon-pet scripts/get-sprites.sh
git rm scripts/pet-state.sh
git commit -m "refactor: hooks, CLI, and sprite fetcher run through pet-core"
```

---

### Task 7: Overlay becomes a pure view of resolved.json

**Files:**
- Modify: `scripts/pet-overlay.js`

**Interfaces:**
- Consumes: `resolved.json` (Task 5 shape) — the ONLY game input. The overlay keeps exactly two pieces of session logic, both presentation: mood decay by age (45 s for done/hello, 600 s for active states) and evolution-cutscene detection (observed `stage` increase vs the previous poll).

- [ ] **Step 1: Delete game logic from pet-overlay.js.** Remove: the `TYPE_MOVES` table (lines 22–38), `EVO2`/`EVO3` constants, the `chains` + `KO` loading (lines 53–55), `lang()`, `dispName()`, `currentChain()`, and the body of `petState()`. Keep: `readFile`/`writeFile`/`today()` helpers, `josa()` (Korean grammar is presentation), the entire window/motion/drag code.

- [ ] **Step 2: New petState() reading resolved.json:**

```javascript
  function petState() {
    var r;
    try { r = JSON.parse(readFile(CACHE + '/resolved.json')); } catch (e) { return null; }
    if (!r || !r.species) return null;
    var age = Math.floor(Date.now() / 1000) - (r.state_ts || 0);
    var state = r.state || 'idle';
    if ((state === 'done' || state === 'hello') && age > 45) state = 'idle';
    if ((state === 'thinking' || state === 'working' || state === 'waiting') && age > 600) state = 'idle';
    r.state = state;
    r.age = age;
    return r;
  }
```

- [ ] **Step 3: New moodText() using resolved fields** (templates stay in the overlay — they are presentation; `p.name` and `p.moves` arrive already localized):

```javascript
  function pick(arr) { return arr[Math.floor(Date.now() / 7000) % arr.length]; }
  function moodText(p) {
    var move = pick(p.moves && p.moves.length ? p.moves : ['TACKLE']);
    var N = p.name;
    if (p.lang === 'ko') {
      switch (p.state) {
        case 'thinking': return pick([josa(N, '은', '는') + ' 기합을 넣고 있다!', josa(N, '은', '는') + ' 상황을 살피고 있다!']);
        case 'working':  return N + '의 ' + move + '!';
        case 'done':     return pick(['효과는 굉장했다!', josa(N, '은', '는') + ' 경험치를 얻었다!']);
        case 'waiting':  return josa(N, '은', '는') + ' 지시를 기다리고 있다';
        case 'hello':    return '가라! ' + N + '!';
        default:         return josa(N, '은', '는') + ' 쿨쿨 잠들어 있다';
      }
    }
    switch (p.state) {
      case 'thinking': return pick([N + ' is getting pumped!', N + ' is sizing up the task!']);
      case 'working':  return N + ' used ' + move + '!';
      case 'done':     return pick(["It's super effective!", N + ' gained EXP. Points!']);
      case 'waiting':  return N + ' looks at you expectantly';
      case 'hello':    return 'Go! ' + N + '!';
      default:         return N + ' is fast asleep';
    }
  }
```

- [ ] **Step 4: New setExp() and refresh()** — `setExp` just draws `exp_pct`/`exp_gold`; `refresh` tracks the previous name for the evolution cutscene and guards a null state:

```javascript
  function setExp(p) {
    var frac = Math.max(0.02, Math.min(1, (p.exp_pct || 0) / 100));
    expFill.setFillColor(p.exp_gold ? cg(1.0, 0.82, 0.25, 0.95) : cg(0.49, 0.81, 1.0, 0.95));
    expFill.setPath($.CGPathCreateWithRoundedRect(
      $.CGRectMake(expX, expY, EXPW * frac, EXPH), 2, 2, null));
  }

  var evolveUntil = 0, evolveName = '', prevStage = 0, prevName = '';
  function refresh() {
    var p = petState();
    if (!p) return;                        // core hasn't resolved yet
    current.state = p.state;
    current.age = p.age;
    current.mon = p.species;
    if (prevStage && p.stage > prevStage) {
      evolveUntil = Date.now() + 10000;
      evolveName = prevName;
    }
    prevStage = p.stage;
    prevName = p.name;
    setSprite(p.species, p.state === 'working' ? facing : 'l');
    nameLabel.setStringValue($(p.name + '  Lv.' + p.tasks));
    var evolveMsg = p.lang === 'ko'
      ? '어라…!? ' + evolveName + '의 모습이…!'
      : 'What? ' + evolveName + ' is evolving!';
    moodLabel.setStringValue($(Date.now() < evolveUntil ? evolveMsg : moodText(p)));
    centerLabel(nameLabel);
    centerLabel(moodLabel);
    setExp(p);
    win.setAlphaValue(p.state === 'idle' ? 0.55 : 1.0);
  }
```

Note `setSprite(p.species, …)` — sprite files are keyed by the English slug; display uses `p.name`. `EVO2`/`EVO3` are gone, so also delete the old `setExp` body that referenced them (`pet-overlay.js:225-238`) and the `mons`-based math. The header comment and README config table change accordingly (Task 8).

- [ ] **Step 5: Smoke-test the real overlay.** With the installed plugin's overlay OFF (`claude-pokemon-pet off` if installed), run the dev overlay against real cache state:

```bash
scripts/pet-core.sh roll && scripts/pet-core.sh event hello </dev/null
nohup osascript -l JavaScript scripts/pet-overlay.js "$PWD" >/tmp/pet-dev.log 2>&1 &
sleep 6; pgrep -f pet-overlay.js >/dev/null && echo "overlay alive" || { echo "CRASHED"; cat /tmp/pet-dev.log; }
scripts/pet-core.sh event done </dev/null   # should trigger hop + Lv bump on screen
sleep 3; pkill -f pet-overlay.js
```

Expected: `overlay alive`, empty `/tmp/pet-dev.log`, pet visibly reacts. Also run `bash tests/run.sh` → `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/pet-overlay.js
git commit -m "refactor: overlay renders resolved.json — game logic fully in core"
```

---

### Task 8: Docs, data cleanup, version bump, final verification

**Files:**
- Delete: `data/chains.json`, `data/gen1.txt`, `data/lang-ko.json`
- Modify: `README.md`, `.claude-plugin/plugin.json`, `commands/pet.md` (verify only)

- [ ] **Step 1: Confirm nothing references the old data files**, then delete:

```bash
grep -rn 'chains.json\|gen1.txt\|lang-ko.json\|pet-state.sh' scripts hooks commands README.md || echo CLEAN
git rm data/chains.json data/gen1.txt data/lang-ko.json
```

Expected: `CLEAN` (only docs/ may mention them historically). If any hit appears in scripts/hooks — fix it before deleting.

- [ ] **Step 2: Update README.md**:
  - "How it works" table: replace `pet-state.sh` row with `scripts/pet-core.sh` ("game core: reduces hook events to resolved.json — the single file every renderer reads"); replace `data/chains.json` row with `data/pokemon/pack.json` ("franchise pack: 81 evolution lines, 151 species with en/ko names, move pools, sprite source"); drop `lang-ko.json`/`gen1.txt` rows.
  - Configuration table: `EVO2`/`EVO3` become "gates `[0,6,16]` in `data/pokemon/pack.json`"; `BOTTOM_OFFSET`/`ROAM` stay in `pet-overlay.js`.
  - Hook events paragraph: mention `PostToolUse` also counts failing tool calls into a daily `mistakes` counter (drives upcoming features), and that `dex.json`/`streak` now accumulate in the cache.
  - Troubleshooting "Full reset" already covers the new files (whole-dir `rm -r`) — no change needed.

- [ ] **Step 3: Bump version** in `.claude-plugin/plugin.json`: `"version": "0.4.0"`. Read `commands/pet.md` and confirm no change needed (subcommand surface identical).

- [ ] **Step 4: Full verification**

```bash
bash tests/run.sh
grep -c 'pet-core.sh' hooks/hooks.json    # expect 5
```

Expected: `ALL PASS`, `5`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs: v0.4.0 — shared core architecture, pack-driven data"
```

---

## Post-plan checks (before calling Phase 1 done)

1. `bash tests/run.sh` green.
2. Manual overlay QA from Task 7 Step 5 re-run once after Task 8.
3. Code review per repo/global rules (review → fix → re-review until clean).
4. Milestone review report per the user's global CLAUDE.md.
