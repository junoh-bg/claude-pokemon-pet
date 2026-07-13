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

case "${1:-}" in
    event)   cmd_event "${2:-idle}" ;;
    resolve) cmd_resolve ;;
    *) echo "usage: pet-core.sh <event <state>|resolve>" >&2; exit 1 ;;
esac
