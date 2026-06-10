#!/bin/bash
# Claude Code hook helper: pet-state.sh <state>
# "done" also bumps today's task counter (drives level/evolution).

CACHE="$HOME/.cache/claude-pet"
mkdir -p "$CACHE"
printf '%s %s\n' "${1:-idle}" "$(date +%s)" > "$CACHE/state"

if [ "$1" = "done" ]; then
    today=$(date +%F); n=0
    if [ -f "$CACHE/tasks" ]; then
        read -r d c < "$CACHE/tasks"
        [ "$d" = "$today" ] && n=${c:-0}
    fi
    printf '%s %s\n' "$today" "$((n + 1))" > "$CACHE/tasks"
fi
exit 0
