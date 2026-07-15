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

mkduel() { # <result> <end_ts> [date] — minimal hand-crafted finished duel
    jq -n --arg res "$1" --argjson end "$2" --arg d "${3:-2026-07-13}" '
      {date: $d, start_ts: ($end - 23), end_ts: $end, kind: "wild",
       opponent: {species: "gabumon", name: "GABUMON", level: 3,
                  element: "fire", move: "Petit Fire", franchise: "digimon"},
       turns: [{t: 3, side: "pet", move: "Baby Flame", dmg: 30, pet_hp: 100, foe_hp: 70},
               {t: 7, side: "foe", move: "Petit Fire", dmg: 25, pet_hp: 75, foe_hp: 70},
               {t: 11, side: "pet", move: "Baby Flame", dmg: 35,
                pet_hp: (if $res == "win" then 75 else 0 end),
                foe_hp: (if $res == "win" then 0 else 70 end)}],
       result: $res, applied: false}' > "$CACHE/duel.json"
}

setup  # win: +1 task, wild dex entry, W bump, hp persists, applied once
pin_digimon
echo "2026-07-13 4" > "$CACHE/tasks"
mkduel win 2000
PET_NOW=2001 "$CORE" resolve
assert_eq "win applies exactly once" "true" "$(D .applied)"
assert_eq "win awards +1 Lv" "5" "$(R .tasks)"
assert_json "wild foe in dex" "$CACHE/dex.json" \
    '[.[] | select(.species == "gabumon" and .wild == true)] | length' "1"
read -r w l < "$CACHE/duels"
assert_eq "record 1-0" "1 0" "$w $l"
assert_eq "pet hp persists after the win" "75" "$(R .hp_pct)"
PET_NOW=2002 "$CORE" resolve
assert_eq "no double apply" "5" "$(R .tasks)"
teardown

setup  # lose: faint, L bump, hp 0; done revives at 60
pin_digimon
mkduel lose 2000
PET_NOW=2001 "$CORE" resolve
assert_eq "lose faints the pet" "fainted" "$(R .state)"
assert_eq "lose zeroes hp" "0" "$(R .hp_pct)"
read -r w l < "$CACHE/duels"
assert_eq "record 0-1" "0 1" "$w $l"
PET_NOW=2010 "$CORE" event done
assert_eq "task revives" "done" "$(R .state)"
assert_eq "revive hp 60" "60" "$(R .hp_pct)"
teardown

setup  # apply is race-safe: 20 concurrent resolves award exactly one level
pin_digimon
echo "2026-07-13 4" > "$CACHE/tasks"
mkduel win 2000
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    PET_NOW=2001 "$CORE" resolve &
done
wait
assert_eq "concurrent apply bumps once" "5" "$(R .tasks)"
read -r w l < "$CACHE/duels"
assert_eq "record counted once" "1 0" "$w $l"
teardown

setup  # a duel from yesterday is discarded unapplied at rollover
pin_digimon
mkduel win 2000 2026-07-12
"$CORE" resolve
assert_eq "stale duel discarded" "no" "$([ -f "$CACHE/duel.json" ] && echo yes || echo no)"
assert_eq "stale duel awards nothing" "0" "$(R .tasks)"
teardown

setup  # resolved.json embeds the duel while live, drops it after the linger
pin_digimon
"$CORE" resolve
PET_SEED=1 PET_NOW=5000 "$CORE" duel >/dev/null
PET_NOW=5001 "$CORE" resolve
assert_eq "live duel embedded" "5000" "$(R .duel.start_ts)"
assert_eq "record embedded" "0" "$(R '.record.w + .record.l')"
endts="$(D .end_ts)"
PET_NOW="$(( endts + 7 ))" "$CORE" resolve
assert_eq "duel dropped after linger" "null" "$(R .duel)"
teardown

setup  # dex: owning a species later clears the wild flag and the ⚔ marker
printf '[{"species":"gabumon","franchise":"digimon","date":"2026-07-13","shiny":false,"wild":true}]' \
    > "$CACHE/dex.json"
printf '{"franchise":"digimon","line":["punimon","tunomon","gabumon"],"type":"vpet","date":"2026-07-13","seed":0}' \
    > "$CACHE/partner"
echo "2026-07-13 5" > "$CACHE/tasks"
"$CORE" resolve
assert_json "owning clears wild" "$CACHE/dex.json" \
    '[.[] | select(.species == "gabumon")][0].wild' "false"
out="$("$CORE" dex | grep gabumon)"
case "$out" in *"⚔"*) ok=yes ;; *) ok=no ;; esac
assert_eq "owned gabumon loses its ⚔ marker" "no" "$ok"
teardown

report
