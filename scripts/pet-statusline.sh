#!/bin/bash
# One-line pet for the Claude Code statusline. Pure view of resolved.json;
# re-asks pet-core.sh to resolve when the date stamp is stale. Always exits 0.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
R="$CACHE/resolved.json"
TODAY="${PET_TODAY:-$(date +%F)}"

command -v jq >/dev/null 2>&1 || exit 0
[ "$(jq -r '.date // empty' "$R" 2>/dev/null)" = "$TODAY" ] || "$ROOT/scripts/pet-core.sh" resolve 2>/dev/null
[ -f "$R" ] || { echo "🥚 no pet yet"; exit 0; }

jq -r '
  def temoji: {fire:"🔥",water:"💧",grass:"🌿",electric:"⚡",psychic:"🔮",
    fighting:"🥊",rock:"🪨",ground:"⛰️",poison:"☠️",bug:"🐛",flying:"🕊️",
    ghost:"👻",ice:"❄️",dragon:"🐉",normal:"⭐"}[.type] // "⭐";
  def semoji: {working:"⚔️",thinking:"🤔",waiting:"⏳",done:"✨",hello:"👋"}[.state] // "💤";
  def bar: (.exp_pct * 5 / 100 | floor) as $f
    | (("▰" * $f) // "") + (("▱" * (5 - $f)) // "");
  "\(temoji) \(.name) Lv.\(.tasks) \(bar) \(semoji)"
' "$R" 2>/dev/null || echo "🥚 no pet yet"
exit 0
