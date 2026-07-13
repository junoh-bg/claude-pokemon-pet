#!/bin/bash
# Download gen-1 animated sprites (source configured in the franchise pack)
# into the cache and build upscaled (nearest-neighbor) + mirrored variants.
# Idempotent.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
PACK="$ROOT/data/pokemon/pack.json"
BASE="$(jq -r '.sprites.base_url' "$PACK")"
TARGET="$(jq -r '.sprites.target_px' "$PACK")"
mkdir -p "$CACHE/sprites" "$CACHE/sprites-big"

jq -r '.species | to_entries[] | "\(.value.id) \(.key)"' "$PACK" > "$CACHE/.sprite-ids"
rm -f "$CACHE/sprites"/.*.tmp 2>/dev/null
i=0
while read -r id name; do
    [ -f "$CACHE/sprites/$name.gif" ] && continue
    # download to a temp name and mv on success: an interrupted transfer must
    # never leave a truncated .gif at the final path (it would not be retried)
    ( curl -sfL "$BASE/$id.gif" -o "$CACHE/sprites/.$name.tmp" &&
      mv "$CACHE/sprites/.$name.tmp" "$CACHE/sprites/$name.gif" ) &
    i=$((i + 1)); [ $((i % 10)) -eq 0 ] && wait
done < "$CACHE/.sprite-ids"
wait
rm -f "$CACHE/.sprite-ids"
echo "sprites: $(ls "$CACHE/sprites" | wc -l | tr -d ' ')"

if command -v gifsicle >/dev/null; then
    for g in "$CACHE/sprites"/*.gif; do
        mon=$(basename "$g" .gif)
        [ -f "$CACHE/sprites-big/$mon.gif" ] && continue
        dims=$(gifsicle --info "$g" | grep -m1 'logical screen' | grep -oE '[0-9]+x[0-9]+')
        w=${dims%x*}; h=${dims#*x}
        max=$(( w > h ? w : h ))
        scale=$(( TARGET / max )); [ "$scale" -lt 2 ] && scale=2
        gifsicle --resize-method sample --scale "$scale" "$g" -o "$CACHE/sprites-big/$mon.gif"
        gifsicle --flip-horizontal "$CACHE/sprites-big/$mon.gif" -o "$CACHE/sprites-big/$mon-flip.gif"
    done
    echo "big: $(ls "$CACHE/sprites-big" | wc -l | tr -d ' ')"
else
    echo "gifsicle not found — skipped overlay upscales (terminal mode doesn't need them)"
fi
