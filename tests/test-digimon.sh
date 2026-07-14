#!/bin/bash
. "$(dirname "$0")/lib.sh"
DPACK="$ROOT/data/digimon/pack.json"

assert_eq "digimon pack exists" "yes" "$([ -f "$DPACK" ] && echo yes || echo no)"
assert_json "franchise" "$DPACK" '.franchise' "digimon"
assert_json "gates" "$DPACK" '.gates | join(",")' "0,2,5,10,18"
assert_json "moves_by species" "$DPACK" '.moves_by' "species"
assert_json "5 lines" "$DPACK" '.lines | length' "5"
assert_json "70 species" "$DPACK" '.species | length' "70"
assert_json "line mons are single roots" "$DPACK" '[.lines[].mons | length] | unique | join(",")' "1"
assert_json "v1 root" "$DPACK" '.lines[0].mons[0]' "botamon"
assert_json "v1 members include agumon" "$DPACK" '.lines[0].members | index("agumon") != null' "true"
assert_json "every edge endpoint is a species" "$DPACK" \
    '. as $p | [.edges | to_entries[] | .key, .value[].to] | unique | map(select($p.species[.] == null)) | length' "0"
assert_json "every species has a digi-api sprite_url" "$DPACK" \
    '[.species[] | select(.sprite_url | startswith("https://digi-api.com/images/digimon/") | not)] | length' "0"
assert_json "sprites are png" "$DPACK" '.sprites.format' "png"
assert_json "keying is floodfill" "$DPACK" '.sprites.keying' "floodfill"
assert_json "moves by species" "$DPACK" '.moves_by' "species"
assert_json "all 70 ko names present" "$DPACK" '[.species[] | select(.names.ko == null)] | length' "0"
assert_json "all 70 attacks en" "$DPACK" '[.species[] | select(.attack.en == null)] | length' "0"
assert_json "numemon official ko" "$DPACK" '.species.numemon.names.ko' "워매몬"
assert_json "agumon attack ko" "$DPACK" '.species.agumon.attack.ko' "베이비 플레임"
assert_json "mgv ko display trimmed" "$DPACK" '.species.metalgreymon_virus.names.ko' "메탈그레이몬"
assert_json "reject edges exist" "$DPACK" '[.edges[][] | select(.quality == "reject")] | length >= 10' "true"
assert_json "en name override" "$DPACK" '.species.metalgreymon_virus.names.en' "METALGREYMON"
assert_json "ko name kept" "$DPACK" '.species.botamon.names.ko' "깜몬"
assert_json "greymon ko now official" "$DPACK" '.species.greymon.names.ko' "그레이몬"
assert_json "5 move stages" "$DPACK" '.moves | length' "5"
# guard against future curation regressions: a non-ultimate species with no
# outgoing edges would silently stop that day's evolution forever
assert_json "every non-ultimate species has outgoing edges" "$DPACK" \
    '. as $p | [.lines[].members[:-3][]] | unique | map(select(($p.edges[.] // []) | length == 0)) | length' "0"

# ── evolution engine ──
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
assert_eq "d stages show potential (1/5, not 1/1)" "5" "$(R .stages)"
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

setup  # localized digimon: ko name + real signature attack
digimon_partner; echo ko > "$CACHE/lang"; set_tasks 0; "$CORE" resolve
assert_eq "d ko name" "깜몬" "$(R .name)"
assert_eq "d ko attack" "산성 거품" "$(R '.moves[0]')"
set_tasks 5; "$CORE" resolve
assert_eq "agumon ko attack" "베이비 플레임" "$(R '.moves[0]')"
teardown

setup  # language purity: unverified ko attack falls back to 필살기, never english
printf '{"franchise":"digimon","line":["botamon","koromon","agumon","greymon"],"type":"vpet","date":"2026-07-13","seed":0}' > "$CACHE/partner"
echo ko > "$CACHE/lang"; set_tasks 10; "$CORE" resolve
assert_eq "greymon ko fallback" "필살기" "$(R '.moves[0]')"
echo en > "$CACHE/lang"; "$CORE" resolve
assert_eq "greymon en attack" "Mega Flame" "$(R '.moves[0]')"
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

setup  # element inference from the EN attack name, per keyword class
pin() { printf '{"franchise":"digimon","line":%s,"type":"vpet","date":"2026-07-13","seed":0}' "$1" > "$CACHE/partner"; }
pin '["botamon","koromon","agumon"]'; set_tasks 5; "$CORE" resolve
assert_eq "baby flame → fire" "fire" "$(R .element)"
pin '["botamon","koromon","betamon","seadramon"]'; set_tasks 10; "$CORE" resolve
assert_eq "ice arrow → ice" "ice" "$(R .element)"
pin '["botamon","koromon","betamon"]'; set_tasks 5; "$CORE" resolve
assert_eq "electric shock → electric" "electric" "$(R .element)"
pin '["punimon","tunomon","gabumon","angemon"]'; set_tasks 10; "$CORE" resolve
assert_eq "heavens knuckle → holy" "holy" "$(R .element)"
pin '["botamon","koromon","agumon","devimon"]'; set_tasks 10; "$CORE" resolve
assert_eq "death claw → dark" "dark" "$(R .element)"
pin '["botamon","koromon","agumon","numemon"]'; set_tasks 10; "$CORE" resolve
assert_eq "poop throw → poison" "poison" "$(R .element)"
pin '["botamon","koromon"]'; set_tasks 2; "$CORE" resolve
assert_eq "bubbles → vpet default" "vpet" "$(R .element)"
echo ko > "$CACHE/lang"
pin '["botamon","koromon","agumon"]'; set_tasks 5; "$CORE" resolve
assert_eq "element ignores display language" "fire" "$(R .element)"
teardown

setup  # concurrent hooks must not corrupt the evolution line (reviewed race)
digimon_partner; set_tasks 2
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do "$CORE" resolve & done
wait
assert_json "concurrent resolves keep line consistent" "$CACHE/partner" '.line | join(",")' "botamon,koromon"
teardown

setup  # day rollover: stage recomputes from the new day's zero tasks
digimon_partner; set_tasks 18; "$CORE" resolve
assert_eq "grown to ultimate" "mamemon" "$(R .species)"
PET_TODAY=2026-07-14 "$CORE" status >/dev/null
assert_eq "midnight devolves to the egg" "botamon" "$(R .species)"
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

report
