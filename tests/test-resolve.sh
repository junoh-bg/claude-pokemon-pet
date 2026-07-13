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

setup  # resolved.json is stamped with its resolve date
charmander_partner
set_tasks 0; "$CORE" resolve
assert_eq "resolved date stamped" "2026-07-13" "$(R .date)"
teardown

setup  # day rollover: status re-resolves stale resolved.json
charmander_partner
echo "2026-07-13 7" > "$CACHE/tasks"
"$CORE" resolve
assert_eq "pre-rollover species" "charmeleon" "$(R .species)"
out="$(PET_TODAY=2026-07-14 "$CORE" status)"
assert_eq "post-rollover resolved date" "2026-07-14" "$(R .date)"
assert_eq "post-rollover tasks reset"   "0"          "$(R .tasks)"
assert_eq "post-rollover devolves"      "charmander" "$(R .species)"
teardown

setup  # corrupt partner file self-heals to the fallback line
echo 'not json' > "$CACHE/partner"
set_tasks 0; "$CORE" resolve
assert_eq "corrupt partner self-heals" "charmander" "$(R .species)"
teardown

report
