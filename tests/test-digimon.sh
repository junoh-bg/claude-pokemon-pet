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
