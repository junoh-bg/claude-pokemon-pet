#!/bin/bash
# One-line pet for the Claude Code statusline. Pure view of resolved.json;
# re-asks pet-core.sh to resolve when the date stamp is stale. Always exits 0.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
CACHE="$HOME/.cache/claude-pokemon-pet"
R="$CACHE/resolved.json"
TODAY="${PET_TODAY:-$(date +%F)}"
NOW="${PET_NOW:-$(date +%s)}"

command -v jq >/dev/null 2>&1 || { echo "🥚 no pet yet"; exit 0; }
[ "$(jq -r '.date // empty' "$R" 2>/dev/null)" = "$TODAY" ] || "$ROOT/scripts/pet-core.sh" resolve 2>/dev/null
[ -f "$R" ] || { echo "🥚 no pet yet"; exit 0; }

jq -r --argjson now "$NOW" '
  def temoji: {fire:"🔥",water:"💧",grass:"🌿",electric:"⚡",psychic:"🔮",
    fighting:"🥊",rock:"🪨",ground:"⛰️",poison:"☠️",bug:"🐛",flying:"🕊️",
    ghost:"👻",ice:"❄️",dragon:"🐉",normal:"⭐"}[.type] // "⭐";
  def semoji: {working:"⚔️",thinking:"🤔",waiting:"⏳",done:"✨",hello:"👋",
    fainted:"💫"}[.state] // "💤";
  def bar: (.exp_pct * 5 / 100 | floor) as $f
    | (("▰" * $f) // "") + (("▱" * (5 - $f)) // "");
  def rec: if ((.record.w // 0) + (.record.l // 0)) > 0
    then " ⚔\(.record.w)-\(.record.l)" else "" end;
  if (.duel != null and (.duel.end_ts + 6) > $now and .state != "fainted")
  then "⚔ \(.name) vs \(.duel.opponent.name)"
  else "\(temoji) \(if .shiny then "✨" else "" end)\(.name) Lv.\(.tasks) \(bar) \(semoji)\(rec)"
  end
' "$R" 2>/dev/null || echo "🥚 no pet yet"
exit 0
