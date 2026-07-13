#!/bin/bash
. "$(dirname "$0")/lib.sh"
set_tasks() { echo "2026-07-13 $1" > "$CACHE/tasks"; }

setup  # dex counts per franchise, upgrades to shiny, lists entries
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0,"shiny":false}' > "$CACHE/partner"
set_tasks 0; "$CORE" resolve
set_tasks 6; "$CORE" resolve
out="$("$CORE" dex)"
case "$out" in *"pokemon: caught 2/151"*) ok=yes ;; *) ok=no ;; esac
assert_eq "dex counts pokemon" "yes" "$ok"
case "$out" in *"digimon: caught 0/70"*) ok=yes ;; *) ok=no ;; esac
assert_eq "dex counts digimon" "yes" "$ok"
case "$out" in *"shiny: 0"*) ok=yes ;; *) ok=no ;; esac
assert_eq "no shinies yet" "yes" "$ok"
tmp=$(mktemp); jq '.shiny = true' "$CACHE/partner" > "$tmp" && mv "$tmp" "$CACHE/partner"
"$CORE" resolve
out="$("$CORE" dex)"
case "$out" in *"shiny: 1"*) ok=yes ;; *) ok=no ;; esac
assert_eq "existing entry upgraded to shiny" "yes" "$ok"
teardown
report
