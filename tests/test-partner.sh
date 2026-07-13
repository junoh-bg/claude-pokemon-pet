#!/bin/bash
. "$(dirname "$0")/lib.sh"

setup  # roll writes a valid partner deterministically
PET_SEED=7 "$CORE" roll >/dev/null
assert_json "partner franchise" "$CACHE/partner" '.franchise' "pokemon"
assert_json "partner date"      "$CACHE/partner" '.date' "2026-07-13"
assert_json "line non-empty"    "$CACHE/partner" '.line | length >= 1' "true"
first="$(jq -r '.line[0]' "$CACHE/partner")"
PET_SEED=7 "$CORE" roll >/dev/null
assert_eq "roll deterministic under PET_SEED" "$first" "$(jq -r '.line[0]' "$CACHE/partner")"
teardown

setup  # roll-if-new-day: same day keeps, new day rerolls
PET_SEED=7 "$CORE" roll >/dev/null
sig="$(jq -c . "$CACHE/partner")"
"$CORE" roll-if-new-day >/dev/null
assert_eq "same day keeps partner" "$sig" "$(jq -c . "$CACHE/partner")"
PET_TODAY="2026-07-14" "$CORE" roll-if-new-day >/dev/null
assert_json "new day rerolls" "$CACHE/partner" '.date' "2026-07-14"
teardown

setup  # pick by english name
"$CORE" pick pikachu >/dev/null
assert_json "pikachu line found" "$CACHE/partner" '.line | index("pikachu") != null' "true"
teardown

setup  # pick by korean name
"$CORE" pick 파이리 >/dev/null
assert_json "korean pick resolves" "$CACHE/partner" '.line[0]' "charmander"
teardown

setup  # eevee always yields a 2-stage branch containing eevee
"$CORE" pick eevee >/dev/null
assert_json "eevee branch rolled" "$CACHE/partner" '.line[0]' "eevee"
assert_json "eevee branch has 2 stages" "$CACHE/partner" '.line | length' "2"
teardown

setup  # unknown name errors
if "$CORE" pick notapokemon >/dev/null 2>&1; then rc=0; else rc=1; fi
assert_eq "unknown pick exits 1" "1" "$rc"
teardown

setup  # lang override + auto
"$CORE" lang ko >/dev/null
assert_eq "lang file written" "ko" "$(cat "$CACHE/lang")"
assert_json "lang ko resolves ko" "$CACHE/resolved.json" '.lang' "ko"
"$CORE" lang auto >/dev/null
assert_eq "lang file removed" "no" "$([ -f "$CACHE/lang" ] && echo yes || echo no)"
assert_json "lang auto hermetic via PET_LANG" "$CACHE/resolved.json" '.lang' "en"
if "$CORE" lang xx >/dev/null 2>&1; then rc=0; else rc=1; fi
assert_eq "bad lang exits 1" "1" "$rc"
teardown

report
