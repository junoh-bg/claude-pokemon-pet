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
    EXT=$(jq -r '.sprites.format // "gif"' "$PACK")
    jq -r '.species | to_entries[]
           | ("\(.key) \(.value.sprite_url)"),
             (if .value.sprite_shiny_url then "\(.key)-shiny \(.value.sprite_shiny_url)" else empty end)' \
        "$PACK" > "$CACHE/.sprite-urls"
    i=0
    while read -r name url; do
        [ -f "$CACHE/sprites/$name.$EXT" ] && continue
        # download to a temp name and mv on success: an interrupted transfer must
        # never leave a truncated file at the final path (it would not be retried)
        ( curl -sfL "$url" -o "$CACHE/sprites/.$name.tmp" &&
          mv "$CACHE/sprites/.$name.tmp" "$CACHE/sprites/$name.$EXT" ) &
        i=$((i + 1)); [ $((i % 10)) -eq 0 ] && wait
    done < "$CACHE/.sprite-urls"
    wait
    if [ "$EXT" = "png" ]; then
        # this pack replaced an older gif set: purge stale files so renderers
        # can't pick up the superseded art
        jq -r '.species | keys[]' "$PACK" | while read -r mon; do
            rm -f "$CACHE/sprites/$mon.gif" \
                  "$CACHE/sprites-big/$mon.gif" "$CACHE/sprites-big/$mon-flip.gif"
        done
    fi
done
rm -f "$CACHE/.sprite-urls"
echo "sprites: $(ls "$CACHE/sprites" | wc -l | tr -d ' ')"

for PACK in "$ROOT"/data/*/pack.json; do
    EXT=$(jq -r '.sprites.format // "gif"' "$PACK")
    TARGET=$(jq -r '.sprites.target_px // 190' "$PACK")
    if [ "$EXT" = "png" ]; then
        # PNG packs: keyed (border flood-fill) + scaled + flip via python
        command -v python3 >/dev/null || { echo "python3 not found — skipped $(jq -r .franchise "$PACK") overlay sprites"; continue; }
        jq -r '.species | keys[]' "$PACK" | while read -r mon; do
            p="$CACHE/sprites/$mon.png"
            [ -f "$p" ] || continue
            [ -f "$CACHE/sprites-big/$mon.png" ] && continue
            python3 "$ROOT/scripts/process-sprite.py" "$p" \
                "$CACHE/sprites-big/$mon.png" "$CACHE/sprites-big/$mon-flip.png" "$TARGET" ||
                echo "sprite processing failed: $mon" >&2
        done
        continue
    fi
    command -v gifsicle >/dev/null || { echo "gifsicle not found — skipped overlay upscales (terminal mode doesn't need them)"; continue; }
    jq -r '.species | to_entries[]
           | .key, (if .value.sprite_shiny_url then "\(.key)-shiny" else empty end)' \
        "$PACK" | while read -r mon; do
        g="$CACHE/sprites/$mon.gif"
        [ -f "$g" ] || continue
        [ -f "$CACHE/sprites-big/$mon.gif" ] && continue
        dims=$(gifsicle --info "$g" | grep -m1 'logical screen' | grep -oE '[0-9]+x[0-9]+')
        w=${dims%x*}; h=${dims#*x}
        max=$(( w > h ? w : h ))
        scale=$(( TARGET / max )); [ "$scale" -lt 2 ] && scale=2
        gifsicle --resize-method sample --scale "$scale" "$g" -o "$CACHE/sprites-big/$mon.gif"
        gifsicle --flip-horizontal "$CACHE/sprites-big/$mon.gif" -o "$CACHE/sprites-big/$mon-flip.gif"
    done
done
echo "big: $(ls "$CACHE/sprites-big" | wc -l | tr -d ' ')"
