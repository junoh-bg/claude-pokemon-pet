#!/bin/bash
# Download gen-1 animated sprites (PokeAPI, gen-5 B/W set) into the cache and
# build upscaled (nearest-neighbor, ~190px) + mirrored variants. Idempotent.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
BASE="https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated"
mkdir -p "$CACHE/sprites" "$CACHE/sprites-big"

i=0
while read -r id name; do
    [ -f "$CACHE/sprites/$name.gif" ] && continue
    curl -sfL "$BASE/$id.gif" -o "$CACHE/sprites/$name.gif" &
    i=$((i + 1)); [ $((i % 10)) -eq 0 ] && wait
done < "$ROOT/data/gen1.txt"
wait
echo "sprites: $(ls "$CACHE/sprites" | wc -l | tr -d ' ')"

for g in "$CACHE/sprites"/*.gif; do
    mon=$(basename "$g" .gif)
    [ -f "$CACHE/sprites-big/$mon.gif" ] && continue
    dims=$(gifsicle --info "$g" | grep -m1 'logical screen' | grep -oE '[0-9]+x[0-9]+')
    w=${dims%x*}; h=${dims#*x}
    max=$(( w > h ? w : h ))
    scale=$(( 190 / max )); [ "$scale" -lt 2 ] && scale=2
    gifsicle --resize-method sample --scale "$scale" "$g" -o "$CACHE/sprites-big/$mon.gif"
    gifsicle --flip-horizontal "$CACHE/sprites-big/$mon.gif" -o "$CACHE/sprites-big/$mon-flip.gif"
done
echo "big: $(ls "$CACHE/sprites-big" | wc -l | tr -d ' ')"
