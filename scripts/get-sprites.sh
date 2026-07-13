#!/bin/bash
# Download sprites for every installed franchise pack (per-species sprite_url)
# and build upscaled (nearest-neighbor) + mirrored variants for the overlay.
# Idempotent. gifsicle optional (terminal mode needs only the originals).
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
mkdir -p "$CACHE/sprites" "$CACHE/sprites-big"
rm -f "$CACHE/sprites"/.*.tmp 2>/dev/null

for PACK in "$ROOT"/data/*/pack.json; do
    jq -r '.species | to_entries[]
           | ("\(.key) \(.value.sprite_url)"),
             (if .value.sprite_shiny_url then "\(.key)-shiny \(.value.sprite_shiny_url)" else empty end)' \
        "$PACK" > "$CACHE/.sprite-urls"
    i=0
    while read -r name url; do
        [ -f "$CACHE/sprites/$name.gif" ] && continue
        # download to a temp name and mv on success: an interrupted transfer must
        # never leave a truncated .gif at the final path (it would not be retried)
        ( curl -sfL "$url" -o "$CACHE/sprites/.$name.tmp" &&
          mv "$CACHE/sprites/.$name.tmp" "$CACHE/sprites/$name.gif" ) &
        i=$((i + 1)); [ $((i % 10)) -eq 0 ] && wait
    done < "$CACHE/.sprite-urls"
    wait
done
rm -f "$CACHE/.sprite-urls"
echo "sprites: $(ls "$CACHE/sprites" | wc -l | tr -d ' ')"

if command -v gifsicle >/dev/null; then
    for PACK in "$ROOT"/data/*/pack.json; do
        TARGET=$(jq -r '.sprites.target_px // 190' "$PACK")
        WHITEKEY=$(jq -r '.sprites.whitekey // false' "$PACK")
        jq -r '.species | to_entries[]
               | .key, (if .value.sprite_shiny_url then "\(.key)-shiny" else empty end)' \
            "$PACK" | while read -r mon; do
            g="$CACHE/sprites/$mon.gif"
            [ -f "$g" ] || continue
            [ -f "$CACHE/sprites-big/$mon.gif" ] && continue
            src="$g"
            if [ "$WHITEKEY" = "true" ]; then
                # V-pet sprites ship on opaque white: key it out for the overlay
                gifsicle --transparent='#FFFFFF' "$g" -o "$CACHE/sprites-big/.$mon.key.gif"
                src="$CACHE/sprites-big/.$mon.key.gif"
            fi
            dims=$(gifsicle --info "$src" | grep -m1 'logical screen' | grep -oE '[0-9]+x[0-9]+')
            w=${dims%x*}; h=${dims#*x}
            max=$(( w > h ? w : h ))
            scale=$(( TARGET / max )); [ "$scale" -lt 2 ] && scale=2
            gifsicle --resize-method sample --scale "$scale" "$src" -o "$CACHE/sprites-big/$mon.gif"
            gifsicle --flip-horizontal "$CACHE/sprites-big/$mon.gif" -o "$CACHE/sprites-big/$mon-flip.gif"
            rm -f "$CACHE/sprites-big/.$mon.key.gif"
        done
    done
    echo "big: $(ls "$CACHE/sprites-big" | wc -l | tr -d ' ')"
else
    echo "gifsicle not found — skipped overlay upscales (terminal mode doesn't need them)"
fi
