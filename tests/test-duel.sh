#!/bin/bash
. "$(dirname "$0")/lib.sh"

R() { jq -r "$1" "$CACHE/resolved.json"; }
pin_pokemon() {
    printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0}' \
        > "$CACHE/partner"
}

setup  # hp defaults to 100 and heals +10 per task, capped
pin_pokemon
"$CORE" resolve
assert_eq "hp defaults to 100" "100" "$(R .hp_pct)"
echo "2026-07-13 40" > "$CACHE/hp"
"$CORE" event done
assert_eq "task heals +10" "50" "$(R .hp_pct)"
echo "2026-07-13 95" > "$CACHE/hp"
"$CORE" event done
assert_eq "heal caps at 100" "100" "$(R .hp_pct)"
teardown

setup  # stale hp file resets at day rollover
pin_pokemon
echo "2026-07-12 15" > "$CACHE/hp"
"$CORE" resolve
assert_eq "stale hp reads 100" "100" "$(R .hp_pct)"
teardown

setup  # mistakes no longer touch hp
pin_pokemon
echo "2026-07-13 80" > "$CACHE/hp"
"$CORE" event mistake < /dev/null
assert_eq "mistake leaves hp alone" "80" "$(R .hp_pct)"
assert_eq "mistake still counted" "1" "$(R .mistakes)"
teardown

setup  # fainted persists through non-done events, revives on done at 60
pin_pokemon
printf 'fainted 1000\n' > "$CACHE/state"
echo "2026-07-13 0" > "$CACHE/hp"
"$CORE" event working
assert_eq "working does not wake a fainted pet" "fainted" "$(R .state)"
"$CORE" event mistake < /dev/null
assert_eq "mistake does not wake a fainted pet" "fainted" "$(R .state)"
"$CORE" event done
assert_eq "done revives" "done" "$(R .state)"
assert_eq "revive sets hp 60 (not 60+10)" "60" "$(R .hp_pct)"
teardown

pin_digimon() {
    printf '{"franchise":"digimon","line":["botamon","koromon","agumon"],"type":"vpet","date":"2026-07-13","seed":0}' \
        > "$CACHE/partner"
}
D() { jq -r "$1" "$CACHE/duel.json"; }

setup  # manual duel: deterministic, schema-complete, foe from the same franchise
pin_digimon
echo "2026-07-13 5" > "$CACHE/tasks"
PET_SEED=1 PET_NOW=5000 "$CORE" duel >/dev/null
assert_eq "duel.json exists" "yes" "$([ -f "$CACHE/duel.json" ] && echo yes || echo no)"
assert_eq "duel not applied yet" "false" "$(D .applied)"
assert_eq "start now" "5000" "$(D .start_ts)"
assert_eq "kind manual" "manual" "$(D .kind)"
assert_eq "pet-first turns" "pet" "$(D '.turns[0].side')"
assert_eq "first turn at t=3" "3" "$(D '.turns[0].t')"
assert_eq "turns alternate" "foe" "$(D '.turns[1].side')"
assert_eq "cadence 4s" "7" "$(D '.turns[1].t')"
assert_eq "end = last turn + 4" "$(( $(D '.turns[-1].t') + 5000 + 4 ))" "$(D .end_ts)"
assert_eq "foe is same franchise" "digimon" "$(D .opponent.franchise)"
assert_eq "foe is not the pet" "no" \
    "$([ "$(D .opponent.species)" = "agumon" ] && echo yes || echo no)"
assert_eq "foe level >= 1" "true" "$(D '.opponent.level >= 1')"
assert_eq "result matches final hp" "true" \
    "$(D 'if .result == "win" then (.turns[-1].foe_hp == 0) else (.turns[-1].pet_hp == 0) end')"
assert_eq "hp never negative" "0" \
    "$(D '[.turns[] | select(.pet_hp < 0 or .foe_hp < 0)] | length')"
cp "$CACHE/duel.json" "$CACHE/first.json"
PET_SEED=1 PET_NOW=5000 "$CORE" duel >/dev/null 2>&1   # refused: duel active
rm -f "$CACHE/duel.json"
PET_SEED=1 PET_NOW=5000 "$CORE" duel >/dev/null
assert_eq "same seed → identical fight" "" \
    "$(diff <(jq -S . "$CACHE/first.json") <(jq -S . "$CACHE/duel.json"))"
teardown

setup  # wild encounter fires on the seeded roll, respects the daily cap
pin_digimon
PET_SEED=2 "$CORE" event done           # seed 2 % 4 == 2 → roll fires
assert_eq "wild duel generated" "yes" "$([ -f "$CACHE/duel.json" ] && echo yes || echo no)"
assert_eq "kind wild" "wild" "$(D .kind)"
read -r _ dcount < "$CACHE/duels_today"
assert_eq "duels_today = 1" "1" "$dcount"
rm -f "$CACHE/duel.json"
PET_SEED=1 "$CORE" event done           # seed 1 % 4 != 2 → silent
assert_eq "no duel on a losing roll" "no" "$([ -f "$CACHE/duel.json" ] && echo yes || echo no)"
echo "2026-07-13 3" > "$CACHE/duels_today"
PET_SEED=2 "$CORE" event done
assert_eq "cap 3/day blocks wild duels" "no" "$([ -f "$CACHE/duel.json" ] && echo yes || echo no)"
teardown

setup  # no encounters while fainted; manual duel refused too
pin_digimon
"$CORE" resolve
printf 'fainted 1000\n' > "$CACHE/state"
PET_SEED=2 "$CORE" event mistake < /dev/null
assert_eq "no duel while fainted" "no" "$([ -f "$CACHE/duel.json" ] && echo yes || echo no)"
out="$("$CORE" duel)"
case "$out" in *fainted*) ok=yes ;; *) ok="no($out)" ;; esac
assert_eq "manual duel refused while fainted" "yes" "$ok"
teardown

setup  # opponents are stage-matched, never an egg; short lines clamp
pin_digimon
echo "2026-07-13 10" > "$CACHE/tasks"   # champion crossing → pet stage 4
"$CORE" resolve
PET_SEED=1 "$CORE" duel >/dev/null
fsp="$(D .opponent.species)"
assert_eq "digimon foe is not an egg" "no" \
    "$(jq -r --arg s "$fsp" '[.lines[].mons[0]] | index($s) != null' \
       "$ROOT/data/digimon/pack.json" | sed 's/true/yes/; s/false/no/')"
pin_pokemon
echo "2026-07-13 10" > "$CACHE/tasks"
"$CORE" resolve
rm -f "$CACHE/duel.json"
PET_SEED=1 "$CORE" duel >/dev/null
assert_eq "pokemon foe is a pack species" "yes" \
    "$(jq -r --arg s "$(D .opponent.species)" \
        'any(.lines[]; .mons | index($s) != null)' "$ROOT/data/pokemon/pack.json" \
        | sed 's/true/yes/; s/false/no/')"
teardown

report
