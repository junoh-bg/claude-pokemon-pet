#!/bin/bash
. "$(dirname "$0")/lib.sh"
set_tasks() { echo "2026-07-13 $1" > "$CACHE/tasks"; }
stub_sprite() { # <name> — minimal valid 1x1 GIF so the card embeds real bytes
    mkdir -p "$CACHE/sprites-big"
    printf '\107\111\106\70\71\141\001\000\001\000\200\000\000\000\000\000\377\377\377\041\371\004\001\000\000\000\000\054\000\000\000\000\001\000\001\000\000\002\002\104\001\000\073' \
        > "$CACHE/sprites-big/$1.gif"
}

setup  # card generates SVG with the partner's real data
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0,"shiny":true}' > "$CACHE/partner"
stub_sprite charmeleon-shiny
set_tasks 7; "$CORE" resolve
out="$("$CORE" card)"
assert_eq "card exits 0" "0" "$?"
assert_eq "svg written" "yes" "$([ -f "$CACHE/card.svg" ] && echo yes || echo no)"
case "$(cat "$CACHE/card.svg")" in *CHARMELEON*) ok=yes ;; *) ok=no ;; esac
assert_eq "svg has name" "yes" "$ok"
case "$(cat "$CACHE/card.svg")" in *"Lv.7"*) ok=yes ;; *) ok=no ;; esac
assert_eq "svg has level" "yes" "$ok"
# "R0lGOD" is base64 for "GIF89a" — proves real image bytes, not an empty URI
case "$(cat "$CACHE/card.svg")" in *"data:image/gif;base64,R0lGOD"*) ok=yes ;; *) ok=no ;; esac
assert_eq "svg embeds real sprite bytes" "yes" "$ok"
case "$out" in *"card:"*) ok=yes ;; *) ok=no ;; esac
assert_eq "prints svg path" "yes" "$ok"
case "$out" in *CHARMELEON*) ok=yes ;; *) ok=no ;; esac
assert_eq "ansi card printed" "yes" "$ok"
if python3 -c 'import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])' "$CACHE/card.svg" 2>/dev/null; then ok=yes; else ok=no; fi
assert_eq "svg is well-formed xml" "yes" "$ok"
teardown

setup  # korean card is fully korean
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0,"shiny":false}' > "$CACHE/partner"
echo ko > "$CACHE/lang"; set_tasks 3; "$CORE" resolve; "$CORE" card >/dev/null
case "$(cat "$CACHE/card.svg")" in *파이리*) ok=yes ;; *) ok=no ;; esac
assert_eq "ko card has ko name" "yes" "$ok"
case "$(cat "$CACHE/card.svg")" in *트레이너*) ok=yes ;; *) ok=no ;; esac
assert_eq "ko card has ko labels" "yes" "$ok"
teardown
report
