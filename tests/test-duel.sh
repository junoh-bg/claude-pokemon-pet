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

report
