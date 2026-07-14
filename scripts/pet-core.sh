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
mkdir -p "$CACHE" 2>/dev/null   # runs before the event-path guard; must stay silent

TODAY="${PET_TODAY:-$(date +%F)}"
NOW="${PET_NOW:-$(date +%s)}"
[ -n "${PET_SEED:-}" ] && RANDOM="$PET_SEED"

# ── tiny mkdir locks: hooks run concurrently ("async": true) ──
clear_stale_lock() { # <path> — clear a lock leaked by a killed process
    [ -d "$1" ] || return 0
    local mtime
    # GNU stat first (-c %Y): on Linux, BSD-style `stat -f %m` does NOT fail —
    # -f is filesystem mode there and returns the MOUNT POINT string, which
    # poisons the arithmetic. macOS lacks -c, so it falls through to BSD form.
    mtime=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 0
    # a failed/non-numeric stat means the lock vanished mid-check — that is
    # NOT staleness; treating it as age-infinity would rmdir a lock another
    # process just acquired and let two holders into the critical section
    case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
    [ $(( $(date +%s) - mtime )) -gt 10 ] && rmdir "$1" 2>/dev/null
    return 0
}
# Serialize counter read-modify-writes: an unlocked bump loses increments
# under concurrent hooks, which silently miscounts tasks/mistakes — the
# inputs that gate (permanent) evolution. Bounded wait ≈1s, never fails.
counter_lock() {
    # budget: 75 iterations, MEASURED ~2.9s worst case under a held lock
    # (subprocess overhead dominates the nominal sleep) — inside the 5s
    # hook timeout; re-measure, don't re-derive from sleep math
    local lock="$CACHE/.counter.lock" i=0
    while [ "$i" -lt 75 ]; do
        mkdir "$lock" 2>/dev/null && return 0
        # staleness is a 10s condition: probing it every spin just burns
        # subprocesses and starves the actual lock holder under contention
        [ $(( i % 25 )) -eq 24 ] && clear_stale_lock "$lock"
        sleep 0.02
        i=$((i + 1))
    done
    return 0   # last resort: proceed unlocked rather than drop the event
}
counter_unlock() { rmdir "$CACHE/.counter.lock" 2>/dev/null; }

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
        done)    printf 'done %s\n' "$NOW" > "$CACHE/state"
                 counter_lock; update_streak; bump_daily tasks; counter_unlock ;;
        mistake) printf 'working %s\n' "$NOW" > "$CACHE/state"
                 if ! is_interrupt; then
                     counter_lock; bump_daily mistakes; counter_unlock
                 fi ;;
        *)       printf '%s %s\n' "$ev" "$NOW" > "$CACHE/state" ;;
    esac
    cmd_resolve
}

# ── resolve: reduce pack + partner + counters to resolved.json ──
RESOLVE_JQ='
  ($pk[0]) as $pack | ($pt[0]) as $p |
  ($pack.gates) as $g |
  ($p.line) as $line | ($line | length) as $len |
  ([$g[] | select(. <= $tasks)] | length) as $reach |
  ([([$reach, 1] | max), $len] | min) as $stage |
  $line[$stage - 1] as $sp |
  ((($pack.edges // {})[$sp]) // []) as $out |
  (($stage == $len) and (($out | length) == 0)) as $final |
  ($g[$stage - 1] // 0) as $base |
  (if $final then ((($tasks - $base) % 10) * 10)
   else ([([((($tasks - $base) * 100 / ((($g[$stage] // ($base + 10)) - $base))) | floor), 100] | min), 0] | max)
   end) as $pct |
  ([([100 - 15 * $mistakes + 10 * $tasks, 100] | min), 10] | max) as $hp |
  ($pack.species[$sp]) as $spec |
  (if $lang == "ko" then ($spec.names.ko // $spec.names.en) else $spec.names.en end) as $name |
  (if ($pack.moves_by // "type") == "stage"
   then ($pack.moves[$stage | tostring] // [])
   else ($pack.moves[$p.type] // $pack.moves.normal) end) as $mv |
  {
    date: $today,
    franchise: $p.franchise, species: $sp, name: $name, type: $p.type,
    stage: $stage, stages: $len, final: $final,
    tasks: $tasks, mistakes: $mistakes, streak: $streak, shiny: ($p.shiny // false),
    exp_pct: $pct, exp_gold: $final, hp_pct: $hp,
    line: $line,
    line_names: ($line | map($pack.species[.] as $s |
        if $lang == "ko" then ($s.names.ko // $s.names.en) else $s.names.en end)),
    moves: (if $lang == "ko" then ($mv | map($pack.moves_ko[.] // .)) else $mv end),
    lang: $lang, state: $state, state_ts: $ts
  }'

update_dex() {
    [ -f "$CACHE/dex.json" ] || echo '[]' > "$CACHE/dex.json"
    local sp fr sh tmp
    sp="$(jq -r '.species' "$CACHE/resolved.json")"
    fr="$(jq -r '.franchise' "$CACHE/resolved.json")"
    sh="$(jq -r '.shiny' "$CACHE/resolved.json")"
    tmp="$(mktemp)"
    jq --arg s "$sp" --arg f "$fr" --arg d "$TODAY" --argjson sh "$sh" \
       'if any(.[]; .species == $s and .franchise == $f)
        then map(if .species == $s and .franchise == $f and $sh then .shiny = true else . end)
        else . + [{species: $s, franchise: $f, date: $d, shiny: $sh}] end' \
       "$CACHE/dex.json" > "$tmp" && mv "$tmp" "$CACHE/dex.json"
}

cmd_dex() {
    [ -f "$CACHE/dex.json" ] || echo '[]' > "$CACHE/dex.json"
    local f pack total caught
    for f in pokemon digimon; do
        pack="$(pack_file "$f")"; [ -f "$pack" ] || continue
        total="$(jq '.species | length' "$pack")"
        caught="$(jq --arg f "$f" '[.[] | select(.franchise == $f)] | length' "$CACHE/dex.json")"
        echo "$f: caught $caught/$total"
    done
    echo "shiny: $(jq '[.[] | select(.shiny)] | length' "$CACHE/dex.json") ✨"
    jq -r 'sort_by(.date)[] | "  \(.date)  \(.species)\(if .shiny then " ✨" else "" end)"' "$CACHE/dex.json"
}

# ── digimon-style growth: extend the line when daily gates unlock stages.
# The branch is chosen AT the crossing (care mistakes then decide) and the
# choice is recorded in the partner file — permanent for the day.
extend_line() { # <pack-file>
    local pack="$1" tasks mistakes len reach next tmp
    # Hooks run concurrently (async): without mutual exclusion, two resolvers
    # interleave read-decide-append and corrupt the line (duplicate/overshot
    # stages). mkdir is atomic; the loser skips — the next event catches up.
    local lock="$CACHE/.extend.lock"
    clear_stale_lock "$lock"
    mkdir "$lock" 2>/dev/null || return 0
    tasks="$(read_daily tasks)"; mistakes="$(read_daily mistakes)"
    while :; do
        len="$(jq '.line | length' "$CACHE/partner")"
        reach="$(jq --argjson t "$tasks" '[.gates[] | select(. <= $t)] | length' "$pack")"
        [ "$reach" -gt "$len" ] || break
        next="$(jq -r --slurpfile pt "$CACHE/partner" --argjson m "$mistakes" '
            ($pt[0]) as $p | ($p.line[-1]) as $sp |
            ((.edges // {})[$sp] // []) as $e |
            if ($e | length) == 0 then empty else
              ([$e[] | select(.quality == "reject")]) as $rej |
              ([$e[] | select(.quality != "reject")]) as $norm |
              (if $m >= (.mistake_threshold // 3) and ($rej | length) > 0 then $rej
               elif ($norm | length) > 0 then $norm
               else $rej end) as $pool |
              $pool[(($p.seed + ($p.line | length)) % ($pool | length))].to
            end' "$pack")"
        [ -n "$next" ] || break   # species with no outgoing edges: growth simply stops
        tmp="$(mktemp)"
        jq --arg n "$next" '.line += [$n]' "$CACHE/partner" > "$tmp" && mv "$tmp" "$CACHE/partner"
    done
    rmdir "$lock" 2>/dev/null
}

cmd_resolve() {
    command -v jq >/dev/null 2>&1 || return 0   # hook path must survive a bare PATH
    jq -e . "$CACHE/partner" >/dev/null 2>&1 || default_partner   # missing or corrupt: self-heal
    local pack tasks mistakes streak lang state ts tmp
    pack="$(pack_file "$(active_franchise)")"
    jq -e '.edges' "$pack" >/dev/null 2>&1 && extend_line "$pack"
    tasks="$(read_daily tasks)"
    mistakes="$(read_daily mistakes)"
    streak="$(read_streak)"
    lang="$(cur_lang)"
    state=idle; ts="$NOW"
    [ -f "$CACHE/state" ] && read -r state ts < "$CACHE/state"
    tmp="$(mktemp)"
    jq -n --slurpfile pk "$pack" --slurpfile pt "$CACHE/partner" \
       --argjson tasks "$tasks" --argjson mistakes "$mistakes" --argjson streak "$streak" \
       --arg lang "$lang" --arg state "$state" --argjson ts "${ts:-0}" --arg today "$TODAY" \
       "$RESOLVE_JQ" > "$tmp" && mv "$tmp" "$CACHE/resolved.json"
    update_dex
}

cmd_status() {
    # resolved.json is only rewritten on events; re-resolve if absent or stale
    # (e.g. first status of a new day — counters reset at midnight)
    if [ "$(jq -r '.date // empty' "$CACHE/resolved.json" 2>/dev/null)" != "$TODAY" ]; then
        cmd_resolve
    fi
    jq -r '"partner: \(.line | join(" → "))",
           "now:     \(.name) (stage \(.stage)/\(.stages))",
           "state:   \(.state)",
           "tasks:   \(.tasks) today · mistakes: \(.mistakes) · streak: \(.streak)d",
           "lang:    \(.lang)"' "$CACHE/resolved.json"
}

# ── partner (the rolled line) ──
pack_file() { echo "$ROOT/data/${1:-pokemon}/pack.json"; }
active_franchise() { jq -r '.franchise // "pokemon"' "$CACHE/partner" 2>/dev/null || echo pokemon; }

default_partner() {   # safe fallback, mirrors v1's chains[1] = charmander
    jq -n --arg d "$TODAY" \
      '{franchise: "pokemon", line: ["charmander","charmeleon","charizard"], type: "fire", date: $d, seed: 0}' \
      > "$CACHE/partner"
}

write_partner() { # <pack-file> <line-index>
    local tmp rate s
    tmp="$(mktemp)"
    rate="$(jq -r '.sprites.shiny_rate // 0' "$1")"
    s=false
    if [ "$rate" -gt 0 ] 2>/dev/null; then
        [ $(( RANDOM % rate )) -eq 0 ] && s=true
        case "${PET_SHINY:-}" in 1) s=true ;; 0) s=false ;; esac   # test seam;
        # inside the rate guard so it can never shiny a franchise that has none
    fi
    jq --argjson i "$2" --arg d "$TODAY" --argjson sd "$RANDOM" --argjson sh "$s" \
       '{franchise: .franchise, line: .lines[$i].mons, type: .lines[$i].type,
         date: $d, seed: $sd, shiny: $sh}' \
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
    local name="${1:-}" f pack eng idxs
    for f in pokemon digimon; do
        pack="$(pack_file "$f")"
        [ -f "$pack" ] || continue
        # korean names resolve to their english slug first
        eng="$(jq -r --arg k "$name" \
            '.species | to_entries[] | select(.value.names.ko == $k) | .key' "$pack" | head -1)"
        [ -z "$eng" ] && eng="$name"
        # any line containing the name; random among matches (eevee branches);
        # a digimon pick starts the LINE whose graph contains the species (the egg)
        idxs=($(jq -r --arg m "$eng" \
            '.lines | to_entries[] | select((.value.members // .value.mons) | index($m)) | .key' "$pack"))
        if [ ${#idxs[@]} -gt 0 ]; then
            write_partner "$pack" "${idxs[RANDOM % ${#idxs[@]}]}"
            return
        fi
    done
    echo "unknown pokémon/digimon: ${1:-?}" >&2
    exit 1
}

cmd_franchise() {
    local f="${1:-}" pack n
    pack="$(pack_file "$f")"
    [ -f "$pack" ] || { echo "unknown franchise: ${f:-?}" >&2; exit 1; }
    n="$(jq '.lines | length' "$pack")"
    write_partner "$pack" $(( RANDOM % n ))
}

# ── language: override file wins, then PET_LANG (test seam), else system ──
cur_lang() {
    local o
    o="$(cat "$CACHE/lang" 2>/dev/null)"
    case "$o" in ko|en) echo "$o"; return ;; esac
    case "${PET_LANG:-}" in ko|en) echo "$PET_LANG"; return ;; esac
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
    # The event path runs on every hook of every session: it must never exit
    # non-zero or emit noise, whatever the state of PATH or the cache.
    event)           cmd_event "${2:-idle}" 2>/dev/null; exit 0 ;;
    roll)            cmd_roll ;;
    roll-if-new-day) cmd_roll_if_new_day ;;
    pick)            cmd_pick "${2:-}" ;;
    franchise)       cmd_franchise "${2:-}" ;;
    lang)            cmd_lang "${2:-}" ;;
    resolve)         cmd_resolve ;;
    dex)             cmd_dex ;;
    status)          cmd_status ;;
    *) echo "usage: pet-core.sh <event <state>|roll|roll-if-new-day|pick <name>|lang <ko|en|auto>|resolve>" >&2; exit 1 ;;
esac
