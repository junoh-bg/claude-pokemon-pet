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
assert_json "species sprite_url" "$PACK" '.species.charmander.sprite_url' \
    "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/4.gif"
assert_json "moves_by type"  "$PACK" '.moves_by' "type"
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
