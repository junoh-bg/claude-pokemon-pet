#!/bin/bash
. "$(dirname "$0")/lib.sh"
SL="$ROOT/scripts/pet-statusline.sh"

setup  # renders name, level, bar and state emoji (tasks 12 → exp 60% → 3 of 5 segments)
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0}' > "$CACHE/partner"
echo "2026-07-13 12" > "$CACHE/tasks"
"$CORE" event working </dev/null
out="$("$SL")"; rc=$?
assert_eq "statusline exits 0" "0" "$rc"
case "$out" in *"CHARMELEON Lv.12"*) ok=yes ;; *) ok=no ;; esac
assert_eq "statusline shows name+level" "yes" "$ok"
case "$out" in *"▰"*) ok=yes ;; *) ok=no ;; esac
assert_eq "statusline shows exp bar" "yes" "$ok"
teardown

setup  # stale resolved.json re-resolves on a new day
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"date":"2026-07-13","type":"fire","seed":0}' > "$CACHE/partner"
echo "2026-07-13 7" > "$CACHE/tasks"
"$CORE" resolve
out="$(PET_TODAY=2026-07-14 "$SL")"
case "$out" in *"Lv.0"*) ok=yes ;; *) ok=no ;; esac
assert_eq "statusline re-resolves on rollover" "yes" "$ok"
teardown

setup  # shiny partner gets the sparkle
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0,"shiny":true}' > "$CACHE/partner"
echo "2026-07-13 3" > "$CACHE/tasks"
"$CORE" resolve
out="$("$SL")"
case "$out" in *"✨CHARMANDER"*) ok=yes ;; *) ok=no ;; esac
assert_eq "statusline shows shiny sparkle" "yes" "$ok"
teardown

setup  # no resolved.json and no partner: still exits 0 with a friendly line
out="$("$SL")"; rc=$?
assert_eq "empty cache exits 0" "0" "$rc"
teardown

report
