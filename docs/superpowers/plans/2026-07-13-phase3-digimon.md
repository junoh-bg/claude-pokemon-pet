# Phase 3: Digimon V-pet Pack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second franchise — the classic 1997 Digital Monster V-pet, all five versions — with authentic branching evolution driven by daily care mistakes, rendered by the existing overlay/terminal/statusline without renderer changes (one small white-key exception).

**Architecture:** The pack format grows an optional `edges` graph + `members` per line. The core gains one new mechanic: `extend_line` — when the daily task count unlocks a new stage, the partner's `line` is *extended at that moment* by choosing an edge (≥3 care mistakes → the canonical "reject" joke evolution; otherwise a seed-deterministic normal edge) and the choice is permanent for the day. Everything downstream (stage/EXP/gold/names/localized moves → `resolved.json`) is the unchanged Phase 1 engine.

**Tech Stack:** bash 3.2 + jq (core, generators), existing Python renderer (tiny white-key addition), curated data from `data/digimon/curation.json` (Wikimon, fetch-verified 70/70).

## Global Constraints

- All Phase 1/2 constraints hold (bash 3.2, hook-path silence, stdlib Python, state only in `~/.cache/claude-pokemon-pet/`).
- **Zero behavior change for Pokémon mode** — all existing tests must stay green; pokemon pack migration (adding `sprite_url`/`moves_by`) must not alter any resolved output.
- Digimon sprites: 36×36 single-frame GIF89a, **white background, no alpha** (verified). White→transparent conversion: gifsicle `--transparent` at install for the overlay path; pure-Python white-keying in the terminal renderer (franchise-gated). Sprites fetched at install, never committed.
- Digimon stage gates: `[0, 2, 5, 10, 18]` (baby1 → baby2 @2 tasks → rookie @5 → champion @10 → ultimate @18); gold cyclic EXP after ultimate. `mistake_threshold: 3`.
- Evolution choices are recorded in the partner file and never re-evaluated (V-pet semantics: your Numemon is yours for the day).
- Curated source data is committed at `data/digimon/curation.json`; `pack.json` is generated from it by a committed dev script.
- Conventional commits; version bumps to 0.6.0 in the final task.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `data/digimon/curation.json` | create (move from staging) | fetch-verified charts/sprites/ko-names (source of truth) |
| `scripts/dev/gen-digimon-pack.sh` | create | curation.json → `data/digimon/pack.json` |
| `data/digimon/pack.json` | create (generated) | the Digimon franchise pack |
| `data/pokemon/pack.json` | modify (migrated) | + `moves_by: "type"`, per-species `sprite_url`; `sprites.base_url` dropped |
| `scripts/dev/gen-pokemon-pack.sh` | modify | emit the new fields (provenance parity) |
| `scripts/get-sprites.sh` | rewrite | multi-pack, `sprite_url`-driven; digimon white-transparent + upscale |
| `scripts/pet-core.sh` | modify | `extend_line`, resolve `final`/`moves_by` rules, `franchise` subcommand, cross-franchise `pick` |
| `scripts/pet-term.py` | modify | `whitekey()` for digimon frames |
| `scripts/claude-pokemon-pet` | modify | `digimon` / `pokemon` subcommands |
| `commands/pet.md` | modify | map franchise words |
| `tests/test-digimon.sh` | create | pack validation + evolution engine cases |
| `tests/test-pack.sh` | modify | sprite_url asserts replace base_url assert |
| `tests/test_term.py` | modify | whitekey test |
| `README.md`, `CLAUDE.md`, `.claude-plugin/plugin.json` | modify | docs + 0.6.0 |

---

### Task 1: Digimon pack generation

**Files:**
- Create: `data/digimon/curation.json` (git mv from `data/digimon-curation-staged.json`)
- Create: `scripts/dev/gen-digimon-pack.sh`, `data/digimon/pack.json`
- Test: `tests/test-digimon.sh` (pack-validation half)

**Interfaces:**
- Produces `data/digimon/pack.json`:

```json
{
  "franchise": "digimon",
  "gates": [0, 2, 5, 10, 18],
  "moves_by": "stage",
  "mistake_threshold": 3,
  "sprites": { "target_px": 180, "whitekey": true },
  "lines": [ {"version": 1, "type": "vpet", "mons": ["botamon"], "members": ["botamon", "koromon", "..."]} ],
  "species": { "<slug>": {"names": {"en": "...", "ko": "...|null"}, "sprite_url": "https://wikimon.net/Special:FilePath/<file>"} },
  "edges": { "<slug>": [ {"to": "<slug>", "quality": "normal|reject"} ] },
  "moves": { "1": ["BUBBLE"], "2": ["ACID BUBBLE"], "3": ["SPIT SHOT", "SCRATCH", "HEADBUTT"], "4": ["HEAVY SHOT", "FIERCE BITE", "POWER SLAM"], "5": ["GIGA BLAST", "FINAL STRIKE", "FULL POWER SHOT"] },
  "moves_ko": { "BUBBLE": "거품 공격", "ACID BUBBLE": "산성 거품", "SPIT SHOT": "발사 공격", "SCRATCH": "할퀴기", "HEADBUTT": "박치기", "HEAVY SHOT": "강력 발사", "FIERCE BITE": "물어뜯기", "POWER SLAM": "몸통 부딪히기", "GIGA BLAST": "기가 블래스트", "FINAL STRIKE": "필살 일격", "FULL POWER SHOT": "전력 발사" }
}
```

English display names: uppercase slug with overrides `{"metalgreymon_virus": "METALGREYMON", "extyranomon": "EX-TYRANOMON", "darktyranomon": "DARK TYRANOMON"}`.

- [ ] **Step 1: Move the staged curation file** — `mkdir -p data/digimon && git mv data/digimon-curation-staged.json data/digimon/curation.json` (already staged in the worktree root).

- [ ] **Step 2: Write the failing pack tests** — `tests/test-digimon.sh` (first half; the engine half arrives in Task 3):

```bash
#!/bin/bash
. "$(dirname "$0")/lib.sh"
DPACK="$ROOT/data/digimon/pack.json"

assert_eq "digimon pack exists" "yes" "$([ -f "$DPACK" ] && echo yes || echo no)"
assert_json "franchise" "$DPACK" '.franchise' "digimon"
assert_json "gates" "$DPACK" '.gates | join(",")' "0,2,5,10,18"
assert_json "moves_by stage" "$DPACK" '.moves_by' "stage"
assert_json "5 lines" "$DPACK" '.lines | length' "5"
assert_json "70 species" "$DPACK" '.species | length' "70"
assert_json "line mons are single roots" "$DPACK" '[.lines[].mons | length] | unique | join(",")' "1"
assert_json "v1 root" "$DPACK" '.lines[0].mons[0]' "botamon"
assert_json "v1 members include agumon" "$DPACK" '.lines[0].members | index("agumon") != null' "true"
assert_json "every edge endpoint is a species" "$DPACK" \
    '. as $p | [.edges | to_entries[] | .key, .value[].to] | unique | map(select($p.species[.] == null)) | length' "0"
assert_json "every species has a sprite_url" "$DPACK" \
    '[.species[] | select(.sprite_url | startswith("https://wikimon.net/Special:FilePath/") | not)] | length' "0"
assert_json "reject edges exist" "$DPACK" '[.edges[][] | select(.quality == "reject")] | length >= 10' "true"
assert_json "en name override" "$DPACK" '.species.metalgreymon_virus.names.en' "METALGREYMON"
assert_json "ko name kept" "$DPACK" '.species.botamon.names.ko' "깜몬"
assert_json "missing ko is null" "$DPACK" '.species.greymon.names.ko' "null"
assert_json "5 move stages" "$DPACK" '.moves | length' "5"
report
```

- [ ] **Step 3: Run** `bash tests/run.sh` → digimon pack failures (red).

- [ ] **Step 4: Write the generator** `scripts/dev/gen-digimon-pack.sh`:

```bash
#!/bin/bash
# Dev-time only: regenerates data/digimon/pack.json from data/digimon/curation.json
# (fetch-verified Wikimon V-pet data, 2026-07-13).
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

jq '
  def disp: {"metalgreymon_virus": "METALGREYMON", "extyranomon": "EX-TYRANOMON",
             "darktyranomon": "DARK TYRANOMON"}[.] // ascii_upcase;
  . as $c |
  {
    franchise: "digimon",
    gates: [0, 2, 5, 10, 18],
    moves_by: "stage",
    mistake_threshold: 3,
    sprites: { target_px: 180, whitekey: true },
    lines: [ $c.versions[] | {
      version: .version, type: "vpet",
      mons: [ .stages[0].members[0] ],
      members: [ .stages[].members[] ]
    } ],
    species: ([ $c.versions[].stages[].members[] ] | unique | map({
      key: .,
      value: { names: { en: disp, ko: ($c.korean[.] // null) },
               sprite_url: ("https://wikimon.net/Special:FilePath/" + $c.sprites[.]) }
    }) | from_entries),
    edges: ([ $c.versions[].edges[] ]
      | map({from: .from, to: .to, quality: .quality})
      | group_by(.from)
      | map({ key: .[0].from, value: map({to: .to, quality: .quality}) })
      | from_entries),
    moves: { "1": ["BUBBLE"], "2": ["ACID BUBBLE"],
             "3": ["SPIT SHOT", "SCRATCH", "HEADBUTT"],
             "4": ["HEAVY SHOT", "FIERCE BITE", "POWER SLAM"],
             "5": ["GIGA BLAST", "FINAL STRIKE", "FULL POWER SHOT"] },
    moves_ko: { "BUBBLE": "거품 공격", "ACID BUBBLE": "산성 거품", "SPIT SHOT": "발사 공격",
                "SCRATCH": "할퀴기", "HEADBUTT": "박치기", "HEAVY SHOT": "강력 발사",
                "FIERCE BITE": "물어뜯기", "POWER SLAM": "몸통 부딪히기",
                "GIGA BLAST": "기가 블래스트", "FINAL STRIKE": "필살 일격",
                "FULL POWER SHOT": "전력 발사" }
  }' data/digimon/curation.json > data/digimon/pack.json
echo "wrote data/digimon/pack.json ($(jq '.species | length' data/digimon/pack.json) species)"
```

Note: edge `group_by(.from)` preserves within-group file order (jq group_by is stable) — the seeded pick indexes into this order, so it must stay deterministic across regens.

- [ ] **Step 5: Generate + green.** `chmod +x scripts/dev/gen-digimon-pack.sh && bash scripts/dev/gen-digimon-pack.sh && bash tests/run.sh` → ALL PASS (engine cases not yet present).

- [ ] **Step 6: Commit.** `git add -A && git commit -m "feat: digimon franchise pack from fetch-verified wikimon curation"`

---

### Task 2: Sprite pipeline — multi-pack, url-driven, white-key install

**Files:**
- Modify: `data/pokemon/pack.json` (one-off jq migration), `scripts/dev/gen-pokemon-pack.sh`, `scripts/get-sprites.sh`, `tests/test-pack.sh`

**Interfaces:**
- Produces: every pack species carries `sprite_url`; `get-sprites.sh` iterates `data/*/pack.json`, fetches each species' URL (atomic tmp+mv, batched), then builds `sprites-big` per pack — with `--transparent=#FFFFFF` first when the pack sets `sprites.whitekey`.

- [ ] **Step 1: Migrate the pokemon pack** (and mirror in the generator for provenance):

```bash
tmp=$(mktemp)
jq '.moves_by = "type"
  | del(.sprites.base_url)
  | .species |= with_entries(
      (.value.id | tostring) as $i
      | .value.sprite_url = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/\($i).gif")' \
  data/pokemon/pack.json > "$tmp" && mv "$tmp" data/pokemon/pack.json
```

In `scripts/dev/gen-pokemon-pack.sh`: add `moves_by: "type",` after `franchise:`; replace the `sprites:` block with `sprites: { target_px: 190 },`; in the species map add `sprite_url: ("https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/" + (.value|tostring) + ".gif"),` alongside `id`.

- [ ] **Step 2: Update `tests/test-pack.sh`** — replace the `sprite base` assert with:

```bash
assert_json "species sprite_url" "$PACK" '.species.charmander.sprite_url' \
    "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/4.gif"
assert_json "moves_by type" "$PACK" '.moves_by' "type"
```

(keep `sprite px` assert). Run `bash tests/run.sh` → green after Step 1.

- [ ] **Step 3: Rewrite `scripts/get-sprites.sh`:**

```bash
#!/bin/bash
# Download sprites for every installed franchise pack (per-species sprite_url)
# and build upscaled (nearest-neighbor) + mirrored variants for the overlay.
# Idempotent. gifsicle optional (terminal mode needs only the originals).
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
mkdir -p "$CACHE/sprites" "$CACHE/sprites-big"
rm -f "$CACHE/sprites"/.*.tmp 2>/dev/null

for PACK in "$ROOT"/data/*/pack.json; do
    jq -r '.species | to_entries[] | "\(.key) \(.value.sprite_url)"' "$PACK" > "$CACHE/.sprite-urls"
    i=0
    while read -r name url; do
        [ -f "$CACHE/sprites/$name.gif" ] && continue
        ( curl -sfL "$url" -o "$CACHE/sprites/.$name.tmp" &&
          mv "$CACHE/sprites/.$name.tmp" "$CACHE/sprites/$name.gif" ) &
        i=$((i + 1)); [ $((i % 10)) -eq 0 ] && wait
    done < "$CACHE/.sprite-urls"
    wait
done
rm -f "$CACHE/.sprite-urls"
echo "sprites: $(ls "$CACHE/sprites" | wc -l | tr -d ' ')"

if command -v gifsicle >/dev/null; then
    for PACK in "$ROOT"/data/*/pack.json; do
        TARGET=$(jq -r '.sprites.target_px // 190' "$PACK")
        WHITEKEY=$(jq -r '.sprites.whitekey // false' "$PACK")
        jq -r '.species | keys[]' "$PACK" | while read -r mon; do
            g="$CACHE/sprites/$mon.gif"
            [ -f "$g" ] || continue
            [ -f "$CACHE/sprites-big/$mon.gif" ] && continue
            src="$g"
            if [ "$WHITEKEY" = "true" ]; then
                gifsicle --transparent='#FFFFFF' "$g" -o "$CACHE/sprites-big/.$mon.key.gif"
                src="$CACHE/sprites-big/.$mon.key.gif"
            fi
            dims=$(gifsicle --info "$src" | grep -m1 'logical screen' | grep -oE '[0-9]+x[0-9]+')
            w=${dims%x*}; h=${dims#*x}
            max=$(( w > h ? w : h ))
            scale=$(( TARGET / max )); [ "$scale" -lt 2 ] && scale=2
            gifsicle --resize-method sample --scale "$scale" "$src" -o "$CACHE/sprites-big/$mon.gif"
            gifsicle --flip-horizontal "$CACHE/sprites-big/$mon.gif" -o "$CACHE/sprites-big/$mon-flip.gif"
            rm -f "$CACHE/sprites-big/.$mon.key.gif"
        done
    done
    echo "big: $(ls "$CACHE/sprites-big" | wc -l | tr -d ' ')"
else
    echo "gifsicle not found — skipped overlay upscales (terminal mode doesn't need them)"
fi
```

- [ ] **Step 4: Live verification** (network): run `scripts/get-sprites.sh`, confirm ≥3 digimon gifs appear in `$CACHE/sprites` (botamon/agumon/numemon), `gifsicle --info` on `sprites-big/agumon.gif` shows `transparent` and ~180px, and existing pokemon sprites were skipped idempotently. `bash tests/run.sh` green.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat: sprite pipeline handles multiple franchise packs with white-key"`

---

### Task 3: Core — V-pet evolution engine

**Files:**
- Modify: `scripts/pet-core.sh`
- Test: `tests/test-digimon.sh` (engine half)

**Interfaces:**
- Produces: `extend_line <pack>` (grows `partner.line` at gate crossings; reject edges when `mistakes >= mistake_threshold`; seed-deterministic; permanent); resolve rules — `final` = last stage AND no outgoing edges; move key by `moves_by`; new subcommand `franchise <name>`; `pick` searches all packs (`members`).

- [ ] **Step 1: Append engine tests to `tests/test-digimon.sh`** (before `report`):

```bash
digimon_partner() {  # seed 0 → deterministic branch picks
    printf '{"franchise":"digimon","line":["botamon"],"type":"vpet","date":"2026-07-13","seed":0}' > "$CACHE/partner"
}
set_tasks() { echo "2026-07-13 $1" > "$CACHE/tasks"; }
set_mistakes() { echo "2026-07-13 $1" > "$CACHE/mistakes"; }
R() { jq -r "$1" "$CACHE/resolved.json"; }

setup  # baby is NOT final/gold; gates drive extension
digimon_partner; set_tasks 0; "$CORE" resolve
assert_eq "d t0 species" "botamon" "$(R .species)"
assert_eq "d t0 final"   "false"   "$(R .final)"
assert_eq "d t0 gold"    "false"   "$(R .exp_gold)"
set_tasks 2; "$CORE" resolve
assert_eq "d t2 species" "koromon" "$(R .species)"
set_tasks 5; "$CORE" resolve
assert_eq "d t5 rookie (seeded)" "agumon" "$(R .species)"
set_tasks 10; "$CORE" resolve
assert_eq "d t10 champion (seeded, clean)" "meramon" "$(R .species)"
set_tasks 18; "$CORE" resolve
assert_eq "d t18 ultimate" "mamemon" "$(R .species)"
assert_eq "d t18 final" "true"  "$(R .final)"
assert_eq "d t18 gold"  "true"  "$(R .exp_gold)"
assert_json "line recorded" "$CACHE/partner" '.line | join(",")' "botamon,koromon,agumon,meramon,mamemon"
teardown

setup  # 3+ care mistakes at the champion crossing → joke evolution
digimon_partner; set_mistakes 3; set_tasks 10; "$CORE" resolve
assert_eq "sloppy day gets numemon" "numemon" "$(R .species)"
set_tasks 18; "$CORE" resolve
assert_eq "numemon continues to monzaemon" "monzaemon" "$(R .species)"
teardown

setup  # evolution is permanent: later mistakes don't rewrite the day
digimon_partner; set_tasks 10; "$CORE" resolve
assert_eq "clean champion first" "meramon" "$(R .species)"
set_mistakes 9; "$CORE" resolve
assert_eq "still meramon after mistakes" "meramon" "$(R .species)"
teardown

setup  # localized digimon: ko name + stage-keyed localized move
digimon_partner; echo ko > "$CACHE/lang"; set_tasks 0; "$CORE" resolve
assert_eq "d ko name" "깜몬" "$(R .name)"
assert_eq "d ko move" "거품 공격" "$(R '.moves[0]')"
teardown

setup  # franchise switching
PET_SEED=3 "$CORE" franchise digimon >/dev/null
assert_json "switched to digimon" "$CACHE/partner" '.franchise' "digimon"
assert_json "starts at an egg" "$CACHE/partner" '.line | length' "1"
PET_SEED=3 "$CORE" franchise pokemon >/dev/null
assert_json "switched back" "$CACHE/partner" '.franchise' "pokemon"
if "$CORE" franchise dragonball >/dev/null 2>&1; then rc=0; else rc=1; fi
assert_eq "unknown franchise exits 1" "1" "$rc"
teardown

setup  # cross-franchise pick: a digimon name starts that line's egg
"$CORE" pick gabumon >/dev/null
assert_json "pick gabumon → digimon" "$CACHE/partner" '.franchise' "digimon"
assert_json "pick gabumon → v2 egg"  "$CACHE/partner" '.line[0]' "punimon"
"$CORE" pick 파피몬 >/dev/null
assert_json "korean digimon pick" "$CACHE/partner" '.line[0]' "punimon"
"$CORE" pick pikachu >/dev/null
assert_json "pokemon pick still works" "$CACHE/partner" '.franchise' "pokemon"
teardown
```

Expected seeded picks with seed 0 (verify against pack edge order): rookie pool [agumon, betamon] idx (0+2)%2=0 → agumon; champion normal pool [greymon, tyranomon, devimon, meramon] idx (0+3)%4=3 → meramon; ultimate pool [mamemon] → mamemon. If the generated edge order differs, fix the GENERATOR (order must match curation file order), not the test.

- [ ] **Step 2: Run** → red (unknown subcommand / wrong species).

- [ ] **Step 3: Implement in `scripts/pet-core.sh`:**

(a) `extend_line` (insert after `update_dex`):

```bash
# ── digimon-style growth: extend the line when daily gates unlock stages.
# The branch is chosen AT the crossing (care mistakes then decide) and the
# choice is recorded in the partner file — permanent for the day.
extend_line() { # <pack-file>
    local pack="$1" tasks mistakes len reach next tmp
    tasks="$(read_daily tasks)"; mistakes="$(read_daily mistakes)"
    while :; do
        len="$(jq '.line | length' "$CACHE/partner")"
        reach="$(jq --argjson t "$tasks" '[.gates[] | select(. <= $t)] | length' "$pack")"
        [ "$reach" -gt "$len" ] || break
        next="$(jq -r --slurpfile pt "$CACHE/partner" --argjson m "$mistakes" '
            ($pt[0]) as $p | ($p.line[-1]) as $sp |
            ((.edges // {})[$sp] // []) as $e |
            if ($e | length) == 0 then empty else
              ([$e[] | select(.quality == "reject")]) as $rej |
              ([$e[] | select(.quality != "reject")]) as $norm |
              (if $m >= (.mistake_threshold // 3) and ($rej | length) > 0 then $rej
               elif ($norm | length) > 0 then $norm
               else $rej end) as $pool |
              $pool[(($p.seed + ($p.line | length)) % ($pool | length))].to
            end' "$pack")"
        [ -n "$next" ] || break
        tmp="$(mktemp)"
        jq --arg n "$next" '.line += [$n]' "$CACHE/partner" > "$tmp" && mv "$tmp" "$CACHE/partner"
    done
}
```

(b) call it in `cmd_resolve` right after the self-heal line:

```bash
    pack="$(pack_file "$(active_franchise)")"
    jq -e '.edges' "$pack" >/dev/null 2>&1 && extend_line "$pack"
```

(note: move the `pack=` assignment above the call; drop the later duplicate).

(c) RESOLVE_JQ changes — replace the `$final` and `$mv` bindings:

```jq
  ((($pack.edges // {})[$sp]) // []) as $out |
  (($stage == $len) and (($out | length) == 0)) as $final |
```

and

```jq
  (if ($pack.moves_by // "type") == "stage"
   then ($pack.moves[$stage | tostring] // [])
   else ($pack.moves[$p.type] // $pack.moves.normal) end) as $mv |
```

(d) `cmd_franchise` + dispatcher entry:

```bash
cmd_franchise() {
    local f="${1:-}" pack n
    pack="$(pack_file "$f")"
    [ -f "$pack" ] || { echo "unknown franchise: ${f:-?}" >&2; exit 1; }
    n="$(jq '.lines | length' "$pack")"
    write_partner "$pack" $(( RANDOM % n ))
}
```

`franchise) cmd_franchise "${2:-}" ;;` in the dispatcher.

(e) generalize `cmd_pick` (replaces the pokemon-only body):

```bash
cmd_pick() {
    local name="${1:-}" f pack eng
    for f in pokemon digimon; do
        pack="$(pack_file "$f")"
        [ -f "$pack" ] || continue
        eng="$(jq -r --arg k "$name" \
            '.species | to_entries[] | select(.value.names.ko == $k) | .key' "$pack" | head -1)"
        [ -z "$eng" ] && eng="$name"
        idxs=($(jq -r --arg m "$eng" \
            '.lines | to_entries[] | select((.value.members // .value.mons) | index($m)) | .key' "$pack"))
        if [ ${#idxs[@]} -gt 0 ]; then
            write_partner "$pack" "${idxs[RANDOM % ${#idxs[@]}]}"
            return
        fi
    done
    echo "unknown pokémon/digimon: ${1:-?}" >&2
    exit 1
}
```

- [ ] **Step 4: Run** `bash tests/run.sh` → ALL PASS (all Phase 1/2 suites must stay green — the pokemon path is untouched by `extend_line` because its pack has no `edges`).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat: v-pet evolution engine — care-mistake branching, franchise switching"`

---

### Task 4: Renderers + CLI surface

**Files:**
- Modify: `scripts/pet-term.py`, `tests/test_term.py`, `scripts/claude-pokemon-pet`, `commands/pet.md`

- [ ] **Step 1: Failing test** in `tests/test_term.py` (TestDrawing):

```python
    def test_whitekey(self):
        rgba = bytes([255, 255, 255, 255, 200, 10, 10, 255])
        out = pet_term.whitekey(rgba)
        self.assertEqual(out[3], 0)            # white pixel keyed out
        self.assertEqual(out[4:8], bytes([200, 10, 10, 255]))
```

- [ ] **Step 2: Implement** in `scripts/pet-term.py` — add after `exp_bar`:

```python
def whitekey(rgba):
    """V-pet sprites ship on an opaque white background: key it out."""
    out = bytearray(rgba)
    for o in range(0, len(out), 4):
        if out[o] >= 250 and out[o + 1] >= 250 and out[o + 2] >= 250 and out[o + 3] == 255:
            out[o + 3] = 0
    return bytes(out)
```

In `UI.load_species(self, species, franchise=None)`: after a successful decode, `if franchise == "digimon": self.anim = petgif.Anim(self.anim.width, self.anim.height, [petgif.Frame(whitekey(f.rgba), f.delay_ms) for f in self.anim.frames])`. Update the `draw()` call site: `self.load_species(r["species"], r.get("franchise"))`.

- [ ] **Step 3: CLI + command doc.** In `scripts/claude-pokemon-pet` add before `pet)`: `digimon|pokemon)  "$CORE" franchise "$1" ;;` and extend the usage line with `digimon|pokemon`. In `commands/pet.md` subcommands add `digimon` | `pokemon`; mapping: `- "digimon"/"디지몬" → \`digimon\`; "pokemon"/"포켓몬" → \`pokemon\``.

- [ ] **Step 4: Verify.** `bash tests/run.sh` green; headless term smoke with a digimon partner (`"$CORE" franchise digimon` in a sandbox HOME + 1s pet-term run shows half-blocks without a solid white box).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat: digimon rendering and franchise CLI"`

---

### Task 5: Docs, version, cross-platform QA

- [ ] **Step 1: README** — new **Digimon mode** section: `claude-pokemon-pet digimon` (or `/claude-pokemon-pet:pet digimon`); explains the five 1997 V-pet versions, 5 stages by daily tasks (0/2/5/10/18), and care mistakes: ≥3 failing tool calls on the day of an evolution steers it to the authentic joke forms (Numemon and friends); evolution choices are permanent for the day; `pet status` shows today's mistakes. Credits section: add Wikimon as the Digimon sprite source (fetched at install, © Bandai, fan-made disclaimer). "How it works" table: add `data/digimon/pack.json`.
- [ ] **Step 2: CLAUDE.md** phase 3 ✅; note the `extend_line` invariant (choices recorded, never re-evaluated) and edge-order determinism (generator must preserve curation order).
- [ ] **Step 3: Version** 0.6.0; keywords add `"digimon"`.
- [ ] **Step 4: QA** — full suite on macOS; Debian container run (suite + `franchise digimon` + resolve chain at tasks 0/2/5/10/18); overlay smoke on macOS with a digimon partner (white-keyed upscaled sprite visible, evolution caption on stage change); `pet status`/statusline render digimon names.
- [ ] **Step 5: Commit** `docs: v0.6.0 — digimon v-pet mode`.

## Post-plan checks
1. Review loop (code-reviewer, sonnet) → fix ALL → PASS.
2. Milestone report `docs/milestones/2026-07-13-phase3-review.md`.
3. PR → auto-merge (authorized) → sync main → Phase 4.
