#!/bin/bash
# pet-core.sh — the game core. Hooks and the CLI write events through here;
# after every mutation it re-resolves the pet into resolved.json, which every
# renderer (overlay, terminal, statusline) reads as a pure view.
# Usage: pet-core.sh <event <state>|roll|roll-if-new-day|pick <name>|lang <ko|en|auto>|resolve|status>
# Test overrides: PET_TODAY, PET_YESTERDAY, PET_NOW, PET_SEED.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
mkdir -p "$CACHE"

TODAY="${PET_TODAY:-$(date +%F)}"
NOW="${PET_NOW:-$(date +%s)}"
[ -n "${PET_SEED:-}" ] && RANDOM="$PET_SEED"

# ── daily counters: files hold "<date> <n>"; other days read as 0 ──
read_daily() {
    local d c
    if [ -f "$CACHE/$1" ]; then
        read -r d c < "$CACHE/$1"
        [ "$d" = "$TODAY" ] && { echo "${c:-0}"; return; }
    fi
    echo 0
}
bump_daily() { printf '%s %s\n' "$TODAY" "$(( $(read_daily "$1") + 1 ))" > "$CACHE/$1"; }

# ── streak: consecutive days with ≥1 completed task ──
yesterday() { echo "${PET_YESTERDAY:-$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)}"; }
update_streak() {
    local d="" c=0
    [ -f "$CACHE/streak" ] && read -r d c < "$CACHE/streak"
    if [ "$d" = "$TODAY" ]; then return 0
    elif [ "$d" = "$(yesterday)" ]; then printf '%s %s\n' "$TODAY" "$(( ${c:-0} + 1 ))" > "$CACHE/streak"
    else printf '%s 1\n' "$TODAY" > "$CACHE/streak"; fi
}
read_streak() {
    local d c
    [ -f "$CACHE/streak" ] || { echo 0; return; }
    read -r d c < "$CACHE/streak"
    if [ "$d" = "$TODAY" ] || [ "$d" = "$(yesterday)" ]; then echo "${c:-0}"; else echo 0; fi
}

# ── care mistakes: PostToolUseFailure events, except user interrupts.
# Payload shape verified in docs/notes/2026-07-13-posttooluse-payload.md.
is_interrupt() {
    [ -t 0 ] && return 1
    local payload
    payload="$(cat 2>/dev/null)" || return 1
    [ -n "$payload" ] || return 1
    printf '%s' "$payload" | jq -e '.is_interrupt == true' >/dev/null 2>&1
}

cmd_event() {
    local ev="${1:-idle}"
    case "$ev" in
        done)    printf 'done %s\n' "$NOW" > "$CACHE/state"; update_streak; bump_daily tasks ;;
        mistake) is_interrupt || bump_daily mistakes
                 printf 'working %s\n' "$NOW" > "$CACHE/state" ;;
        *)       printf '%s %s\n' "$ev" "$NOW" > "$CACHE/state" ;;
    esac
    cmd_resolve
}

cmd_resolve() { :; }   # stub — implemented in a later task

# ── partner (the rolled line) ──
pack_file() { echo "$ROOT/data/${1:-pokemon}/pack.json"; }
active_franchise() { jq -r '.franchise // "pokemon"' "$CACHE/partner" 2>/dev/null || echo pokemon; }

default_partner() {   # safe fallback, mirrors v1's chains[1] = charmander
    jq -n --arg d "$TODAY" \
      '{franchise: "pokemon", line: ["charmander","charmeleon","charizard"], type: "fire", date: $d, seed: 0}' \
      > "$CACHE/partner"
}

write_partner() { # <pack-file> <line-index>
    local tmp; tmp="$(mktemp)"
    jq --argjson i "$2" --arg d "$TODAY" --argjson s "$RANDOM" \
       '{franchise: .franchise, line: .lines[$i].mons, type: .lines[$i].type, date: $d, seed: $s}' \
       "$1" > "$tmp" && mv "$tmp" "$CACHE/partner"
    cmd_resolve
    echo "pet: $(jq -r '.line | join(" → ")' "$CACHE/partner")"
}

cmd_roll() {
    local pack n
    pack="$(pack_file "$(active_franchise)")"
    n="$(jq '.lines | length' "$pack")"
    write_partner "$pack" $(( RANDOM % n ))
}

cmd_roll_if_new_day() {
    [ "$(jq -r '.date // empty' "$CACHE/partner" 2>/dev/null)" = "$TODAY" ] || cmd_roll
}

cmd_pick() {
    local name="${1:-}" pack eng
    pack="$(pack_file pokemon)"
    # korean names resolve to their english slug first
    eng="$(jq -r --arg k "$name" \
        '.species | to_entries[] | select(.value.names.ko == $k) | .key' "$pack" | head -1)"
    [ -n "$eng" ] && name="$eng"
    # any line containing the name; random among matches (eevee branches)
    idxs=($(jq -r --arg m "$name" \
        '.lines | to_entries[] | select(.value.mons | index($m)) | .key' "$pack"))
    if [ ${#idxs[@]} -eq 0 ]; then
        echo "unknown gen-1 pokémon: ${1:-?}" >&2
        exit 1
    fi
    write_partner "$pack" "${idxs[RANDOM % ${#idxs[@]}]}"
}

# ── language: override file wins, else system ──
cur_lang() {
    local o
    o="$(cat "$CACHE/lang" 2>/dev/null)"
    case "$o" in ko|en) echo "$o"; return ;; esac
    case "${LC_ALL:-${LANG:-}}" in ko*) echo ko; return ;; esac
    if defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q ko; then
        echo ko
    else
        echo en
    fi
}

cmd_lang() {
    case "${1:-}" in
        ko|en) echo "$1" > "$CACHE/lang"; echo "language: $1" ;;
        auto)  rm -f "$CACHE/lang"; echo "language: auto (system)" ;;
        *)     echo "usage: pet-core.sh lang <ko|en|auto>" >&2; exit 1 ;;
    esac
    cmd_resolve
}

case "${1:-}" in
    event)           cmd_event "${2:-idle}" ;;
    roll)            cmd_roll ;;
    roll-if-new-day) cmd_roll_if_new_day ;;
    pick)            cmd_pick "${2:-}" ;;
    lang)            cmd_lang "${2:-}" ;;
    resolve)         cmd_resolve ;;
    *) echo "usage: pet-core.sh <event <state>|roll|roll-if-new-day|pick <name>|lang <ko|en|auto>|resolve>" >&2; exit 1 ;;
esac
