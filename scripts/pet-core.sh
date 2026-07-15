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

# ── battle HP: date-stamped "<date> <pct>"; duels deplete it, tasks heal ──
read_hp() {
    local d p
    if [ -f "$CACHE/hp" ]; then
        read -r d p < "$CACHE/hp"
        [ "$d" = "$TODAY" ] && { echo "${p:-100}"; return; }
    fi
    echo 100
}
write_hp() { printf '%s %s\n' "$TODAY" "$1" > "$CACHE/hp"; }

cur_state() {
    local st ts
    st=idle
    [ -f "$CACHE/state" ] && read -r st ts < "$CACHE/state"
    echo "$st"
}

# A completed task heals +10 (cap 100); if the pet fainted in a duel, the
# task revives it at 60 instead (no additional heal on top).
heal_or_revive() {
    local hp
    if [ "$(cur_state)" = "fainted" ]; then
        hp=60
    else
        hp=$(( $(read_hp) + 10 ))
        [ "$hp" -gt 100 ] && hp=100
    fi
    write_hp "$hp"
    printf 'done %s\n' "$NOW" > "$CACHE/state"
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
    # fainted (a lost duel) is sticky: only a completed task clears it
    case "$ev" in
        done)    counter_lock; update_streak; bump_daily tasks
                 heal_or_revive; counter_unlock ;;
        mistake) [ "$(cur_state)" = "fainted" ] || printf 'working %s\n' "$NOW" > "$CACHE/state"
                 if ! is_interrupt; then
                     counter_lock; bump_daily mistakes; counter_unlock
                 fi ;;
        *)       [ "$(cur_state)" = "fainted" ] || printf '%s %s\n' "$ev" "$NOW" > "$CACHE/state" ;;
    esac
    cmd_resolve
    # ambient encounters: a completed task may attract a wild challenger
    if [ "$ev" = "done" ] && gen_duel; then
        cmd_resolve   # embed the fresh duel into resolved.json
    fi
}

# jq defs shared by resolve and duel generation (keep the element table in
# exactly one place)
JQ_DEFS='
  def elem_of($atk):
    ($atk | ascii_downcase) as $a |
    if   ($a | test("flame|fire|burning|heat|volcano")) then "fire"
    elif ($a | test("ice|icicle|snow|zero"))    then "ice"
    elif ($a | test("thunder|electric|shock|spark")) then "electric"
    elif ($a | test("water|hydro|tidal|wave"))  then "water"
    elif ($a | test("poison|sludge|acid|poop")) then "poison"
    elif ($a | test("heaven|holy"))             then "holy"
    elif ($a | test("death|devil|hell|dark|oblivion")) then "dark"
    else "vpet" end;
  def species_move($pack; $sp; $lang; $ltype):
    ($pack.species[$sp]) as $spec |
    if ($pack.moves_by // "type") == "species"
    then (if $lang == "ko" then ($spec.attack.ko // "필살기")
          else ($spec.attack.en // "ATTACK") end)
    else (($pack.moves[$ltype] // $pack.moves.normal // ["TACKLE"])[0]) as $raw
       | (if $lang == "ko" then ($pack.moves_ko[$raw] // $raw) else $raw end)
    end;
  def species_elem($pack; $sp; $ltype):
    if ($pack.moves_by // "type") == "species"
    then elem_of(($pack.species[$sp].attack.en // ""))
    else $ltype end;
'

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
  ($pack.species[$sp]) as $spec |
  (if $lang == "ko" then ($spec.names.ko // $spec.names.en) else $spec.names.en end) as $name |
  (($pack.moves_by // "type")) as $mb |
  (if $mb == "species"
   then [ (if $lang == "ko" then ($spec.attack.ko // "필살기")
           else ($spec.attack.en // "ATTACK") end) ]
   else
     (if $mb == "stage" then ($pack.moves[$stage | tostring] // [])
      else ($pack.moves[$p.type] // $pack.moves.normal // []) end) as $raw
     | (if $lang == "ko" then ($raw | map($pack.moves_ko[.] // .)) else $raw end)
   end) as $mv |
  (if $mb == "species" then elem_of(($spec.attack.en // "")) else $p.type end) as $element |
  (if ($pack.edges // null) != null then ($g | length) else $len end) as $stages_total |
  (($dl[0] // null)) as $dj |
  (if $dj != null and $dj.date == $today and ($now < ($dj.end_ts + 6))
   then $dj else null end) as $duel |
  {
    date: $today,
    franchise: $p.franchise, species: $sp, name: $name, type: $p.type,
    element: $element,
    stage: $stage, stages: $stages_total, final: $final,
    tasks: $tasks, mistakes: $mistakes, streak: $streak, shiny: ($p.shiny // false),
    exp_pct: $pct, exp_gold: $final, hp_pct: $hp,
    record: {w: $w, l: $l}, duel: $duel,
    line: $line,
    line_names: ($line | map($pack.species[.] as $s |
        if $lang == "ko" then ($s.names.ko // $s.names.en) else $s.names.en end)),
    moves: $mv,
    lang: $lang, state: $state, state_ts: $ts
  }'

# ── duels: pre-computed battle scripts (spec 2026-07-15). The whole fight
# is generated up front; renderers replay it by wall clock — no daemons.
# LCG constants stay small ((x*75+74) % 65537): jq numbers are IEEE doubles
# and bigger multipliers would overflow exact integer arithmetic.
DUEL_JQ='
  def nxt: (. * 75 + 74) % 65537;
  ($pk[0]) as $pack | ($rs[0]) as $r |
  [foreach range(0; 24) as $_ ($seed | nxt; nxt; .)] as $rolls |
  ($pack.lines | length) as $nl |
  # stage-matched foe: same distance-from-egg in a random line; reroll once
  # if the pick lands on the pet itself
  (if ($pack.edges // null) != null then
     def walk($sp; $n):
       if $n <= 0 then $sp else
         ((($pack.edges // {})[$sp] // []) | map(select(.quality != "reject"))) as $e |
         if ($e | length) == 0 then $sp else walk($e[0].to; $n - 1) end
       end;
     def foe_of($i): walk($pack.lines[$i].mons[0]; $r.stage - 1);
     (foe_of($rolls[0] % $nl)) as $try |
     (if $try == $r.species then foe_of($rolls[1] % $nl) else $try end)
   else
     def foe_of($i): ($pack.lines[$i].mons) as $m | $m[[($r.stage - 1), (($m | length) - 1)] | min];
     (foe_of($rolls[0] % $nl)) as $try |
     (if $try == $r.species then foe_of($rolls[1] % $nl) else $try end)
   end) as $foe |
  ($pack.lines[$rolls[0] % $nl].type // "normal") as $ftype |
  ($pack.species[$foe]) as $fs |
  (if $lang == "ko" then ($fs.names.ko // $fs.names.en) else $fs.names.en end) as $fname |
  species_move($pack; $foe; $lang; $ftype) as $fmove |
  species_elem($pack; $foe; $ftype) as $felem |
  ([($r.tasks + ($rolls[2] % 5) - 2), 1] | max) as $flevel |
  ($r.moves[0] // "ATTACK") as $pmove |
  # alternating damage rolls until a side drops; pet swings first, +4 bias
  def fight($php; $fhp; $i; $acc):
    if $php <= 0 or $fhp <= 0 or $i >= 20 then $acc
    else
      (if $i % 2 == 0 then "pet" else "foe" end) as $side |
      (18 + ($rolls[$i + 3] % 18) + (if $side == "pet" then 4 else 0 end)) as $dmg |
      (if $side == "pet" then [($fhp - $dmg), 0] | max else $fhp end) as $nf |
      (if $side == "foe" then [($php - $dmg), 0] | max else $php end) as $np |
      fight($np; $nf; $i + 1;
            $acc + [{t: (3 + 4 * $i), side: $side,
                     move: (if $side == "pet" then $pmove else $fmove end),
                     dmg: $dmg, pet_hp: $np, foe_hp: $nf}])
    end;
  fight($hp; 100; 0; []) as $turns |
  {
    date: $today, start_ts: $now,
    end_ts: ($now + $turns[-1].t + 4),
    kind: $kind,
    opponent: { species: $foe, name: $fname, level: $flevel,
                element: $felem, move: $fmove, franchise: $r.franchise },
    turns: $turns,
    result: (if $turns[-1].foe_hp == 0 then "win" else "lose" end),
    applied: false
  }'

duel_active() {
    [ -f "$CACHE/duel.json" ] || return 1
    local end ddate
    ddate="$(jq -r '.date // ""' "$CACHE/duel.json" 2>/dev/null)" || return 1
    end="$(jq -r '.end_ts // 0' "$CACHE/duel.json" 2>/dev/null)" || return 1
    [ "$ddate" = "$TODAY" ] && [ "$NOW" -lt $(( ${end:-0} + 6 )) ]
}

gen_duel() { # [force] — returns 0 iff a duel was generated
    command -v jq >/dev/null 2>&1 || return 1
    [ -f "$CACHE/resolved.json" ] || return 1
    duel_active && return 1
    [ "$(cur_state)" = "fainted" ] && return 1
    local pack duels seed tmp
    pack="$(pack_file "$(active_franchise)")"
    [ -f "$pack" ] || return 1
    duels="$(read_daily duels_today)"
    seed=$(( $(jq -r '.seed // 0' "$CACHE/partner" 2>/dev/null || echo 0) \
             + $(read_daily tasks) * 7 + duels * 13 ))
    [ -n "${PET_SEED:-}" ] && seed="$PET_SEED"
    if [ "${1:-}" != "force" ]; then
        [ "$duels" -lt 3 ] || return 1
        [ $(( (seed * 75 + 74) % 65537 % 4 )) -eq 0 ] || return 1
    fi
    tmp="$(mktemp)"
    jq -n --slurpfile pk "$pack" --slurpfile rs "$CACHE/resolved.json" \
       --argjson seed "$seed" --argjson hp "$(read_hp)" --argjson now "$NOW" \
       --arg today "$TODAY" --arg kind "$( [ "${1:-}" = force ] && echo manual || echo wild )" \
       --arg lang "$(cur_lang)" \
       "$JQ_DEFS$DUEL_JQ" > "$tmp" 2>/dev/null && mv "$tmp" "$CACHE/duel.json" || { rm -f "$tmp"; return 1; }
    [ "${1:-}" != "force" ] && bump_daily duels_today
    return 0
}

dex_add_wild() { # <species> <franchise> — defeated wild mon, ⚔ entry
    [ -f "$CACHE/dex.json" ] || echo '[]' > "$CACHE/dex.json"
    local tmp; tmp="$(mktemp)"
    jq --arg s "$1" --arg f "$2" --arg d "$TODAY" \
       'if any(.[]; .species == $s and .franchise == $f) then .
        else . + [{species: $s, franchise: $f, date: $d, shiny: false, wild: true}] end' \
       "$CACHE/dex.json" > "$tmp" && mv "$tmp" "$CACHE/dex.json"
}

# Settle a finished fight exactly once. mkdir lock + atomic applied-flag
# rewrite: skip-on-busy is safe because the holder flips applied before
# releasing, so latecomers see it settled.
apply_duel_outcome() {
    [ -f "$CACHE/duel.json" ] || return 0
    local appl ddate end
    # NOTE: jq "//" treats false as absent — never use `.applied // default`
    # on a boolean (it silently rewrites false)
    appl="$(jq -r 'if (.applied == true or .applied == false) then (.applied | tostring) else "corrupt" end' \
        "$CACHE/duel.json" 2>/dev/null || echo corrupt)"
    case "$appl" in false) ;; true) return 0 ;; *) rm -f "$CACHE/duel.json"; return 0 ;; esac
    ddate="$(jq -r '.date // ""' "$CACHE/duel.json")"
    [ "$ddate" = "$TODAY" ] || { rm -f "$CACHE/duel.json"; return 0; }   # rollover: discard
    end="$(jq -r '.end_ts // 0' "$CACHE/duel.json")"
    [ "$NOW" -ge "${end:-0}" ] || return 0
    local lock="$CACHE/.duel-apply.lock"
    clear_stale_lock "$lock"
    mkdir "$lock" 2>/dev/null || return 0
    appl="$(jq -r 'if .applied == false then "false" else "true" end' \
        "$CACHE/duel.json" 2>/dev/null || echo true)"   # re-check under lock
    if [ "$appl" = "false" ]; then
        local res fhp w l tmp
        res="$(jq -r '.result' "$CACHE/duel.json")"
        fhp="$(jq -r '.turns[-1].pet_hp // 100' "$CACHE/duel.json")"
        w=0; l=0
        [ -f "$CACHE/duels" ] && read -r w l < "$CACHE/duels"
        if [ "$res" = "win" ]; then
            counter_lock; bump_daily tasks; counter_unlock   # the EXP bonus
            dex_add_wild "$(jq -r '.opponent.species' "$CACHE/duel.json")" \
                         "$(jq -r '.opponent.franchise' "$CACHE/duel.json")"
            printf '%s %s\n' "$(( ${w:-0} + 1 ))" "${l:-0}" > "$CACHE/duels"
            [ "${fhp:-0}" -lt 5 ] && fhp=5
        else
            printf '%s %s\n' "${w:-0}" "$(( ${l:-0} + 1 ))" > "$CACHE/duels"
            printf 'fainted %s\n' "$NOW" > "$CACHE/state"
            fhp=0
        fi
        write_hp "$fhp"
        tmp="$(mktemp)"
        jq '.applied = true' "$CACHE/duel.json" > "$tmp" && mv "$tmp" "$CACHE/duel.json"
    fi
    rmdir "$lock" 2>/dev/null
}

cmd_duel() {
    command -v jq >/dev/null 2>&1 || { echo "duel: jq required" >&2; exit 1; }
    [ -f "$CACHE/resolved.json" ] || cmd_resolve
    if [ "$(cur_state)" = "fainted" ]; then
        echo "your pet has fainted — complete a task to revive it"
        return 0
    fi
    if gen_duel force; then
        cmd_resolve
        echo "⚔ a wild $(jq -r '.opponent.name' "$CACHE/duel.json") appeared!"
    else
        echo "a duel is already underway"
    fi
}

update_dex() {
    [ -f "$CACHE/dex.json" ] || echo '[]' > "$CACHE/dex.json"
    local sp fr sh tmp
    sp="$(jq -r '.species' "$CACHE/resolved.json")"
    fr="$(jq -r '.franchise' "$CACHE/resolved.json")"
    sh="$(jq -r '.shiny' "$CACHE/resolved.json")"
    tmp="$(mktemp)"
    jq --arg s "$sp" --arg f "$fr" --arg d "$TODAY" --argjson sh "$sh" \
       'if any(.[]; .species == $s and .franchise == $f)
        then map(if .species == $s and .franchise == $f
                 then (.wild = false | if $sh then .shiny = true else . end)
                 else . end)
        else . + [{species: $s, franchise: $f, date: $d, shiny: $sh}] end' \
       "$CACHE/dex.json" > "$tmp" && mv "$tmp" "$CACHE/dex.json"
}

cmd_dex() {
    [ -f "$CACHE/dex.json" ] || echo '[]' > "$CACHE/dex.json"
    local f pack total caught wild
    for f in pokemon digimon; do
        pack="$(pack_file "$f")"; [ -f "$pack" ] || continue
        total="$(jq '.species | length' "$pack")"
        caught="$(jq --arg f "$f" '[.[] | select(.franchise == $f and .wild != true)] | length' "$CACHE/dex.json")"
        wild="$(jq --arg f "$f" '[.[] | select(.franchise == $f and .wild == true)] | length' "$CACHE/dex.json")"
        echo "$f: caught $caught/$total (⚔ $wild wild)"
    done
    echo "shiny: $(jq '[.[] | select(.shiny)] | length' "$CACHE/dex.json") ✨"
    jq -r 'sort_by(.date)[] | "  \(.date)  \(.species)\(if .shiny then " ✨" else "" end)\(if .wild == true then " ⚔" else "" end)"' "$CACHE/dex.json"
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
              # care tiers: flawless day → the top branch (edge order = canon);
              # 1-2 mistakes → seeded variety among the rest; 3+ → the joke path
              (if $m >= (.mistake_threshold // 3) and ($rej | length) > 0 then $rej
               elif ($norm | length) == 0 then $rej
               elif $m == 0 then [$norm[0]]
               elif ($norm | length) > 1 then $norm[1:]
               else $norm end) as $pool |
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
    apply_duel_outcome
    jq -e . "$CACHE/partner" >/dev/null 2>&1 || default_partner   # missing or corrupt: self-heal
    local pack tasks mistakes streak lang state ts tmp hp w l duelsrc
    pack="$(pack_file "$(active_franchise)")"
    jq -e '.edges' "$pack" >/dev/null 2>&1 && extend_line "$pack"
    tasks="$(read_daily tasks)"
    mistakes="$(read_daily mistakes)"
    streak="$(read_streak)"
    hp="$(read_hp)"
    lang="$(cur_lang)"
    state=idle; ts="$NOW"
    [ -f "$CACHE/state" ] && read -r state ts < "$CACHE/state"
    w=0; l=0
    [ -f "$CACHE/duels" ] && read -r w l < "$CACHE/duels"
    duelsrc="$CACHE/duel.json"
    [ -f "$duelsrc" ] || duelsrc=/dev/null
    tmp="$(mktemp)"
    jq -n --slurpfile pk "$pack" --slurpfile pt "$CACHE/partner" \
       --slurpfile dl "$duelsrc" --argjson now "$NOW" \
       --argjson w "${w:-0}" --argjson l "${l:-0}" \
       --argjson tasks "$tasks" --argjson mistakes "$mistakes" --argjson streak "$streak" \
       --argjson hp "$hp" \
       --arg lang "$lang" --arg state "$state" --argjson ts "${ts:-0}" --arg today "$TODAY" \
       "$JQ_DEFS$RESOLVE_JQ" > "$tmp" && mv "$tmp" "$CACHE/resolved.json"
    update_dex
}

# ── trainer card: SVG always, PNG when a rasterizer exists, ANSI inline ──
TYPE_HEX_TABLE='fire #e8703a
water #4e8fd9
grass #63b458
electric #e3c53a
psychic #d465b0
normal #b5ad9b
fighting #b45947
rock #a29063
ground #c2a25e
poison #9a5fb8
bug #99b83f
flying #8fa8dd
ghost #7168b8
ice #7cc3d1
dragon #6f66d6
vpet #8fae6e'

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

cmd_card() {
    [ -f "$CACHE/resolved.json" ] || cmd_resolve
    [ -f "$CACHE/dex.json" ] || echo '[]' > "$CACHE/dex.json"
    local name lv stage stages species shiny streak lang typ hex sprite b64
    name="$(jq -r '.name' "$CACHE/resolved.json")"
    lv="$(jq -r '.tasks' "$CACHE/resolved.json")"
    stage="$(jq -r '.stage' "$CACHE/resolved.json")"
    stages="$(jq -r '.stages' "$CACHE/resolved.json")"
    species="$(jq -r '.species' "$CACHE/resolved.json")"
    shiny="$(jq -r '.shiny' "$CACHE/resolved.json")"
    streak="$(jq -r '.streak' "$CACHE/resolved.json")"
    lang="$(jq -r '.lang' "$CACHE/resolved.json")"
    typ="$(jq -r '.type' "$CACHE/resolved.json")"
    hex="$(printf '%s\n' "$TYPE_HEX_TABLE" | while read -r t h; do [ "$t" = "$typ" ] && echo "$h"; done)"
    [ -n "$hex" ] || hex="#b5ad9b"
    local pcount dcount scount
    pcount="$(jq '[.[] | select(.franchise == "pokemon")] | length' "$CACHE/dex.json")"
    dcount="$(jq '[.[] | select(.franchise == "digimon")] | length' "$CACHE/dex.json")"
    scount="$(jq '[.[] | select(.shiny)] | length' "$CACHE/dex.json")"
    local sfx cand mime
    sfx="$( [ "$shiny" = "true" ] && echo -shiny )"
    sprite=""; mime="image/gif"
    for cand in "sprites-big/$species$sfx.gif" "sprites-big/$species$sfx.png" \
                "sprites/$species.gif"; do
        [ -f "$CACHE/$cand" ] && { sprite="$CACHE/$cand"; break; }
    done
    if [ -z "$sprite" ] && [ -f "$CACHE/sprites/$species.png" ]; then
        # raw png originals sit on an opaque white background — key on the
        # fly rather than embed a white box; no python3 → no art (cleaner)
        if command -v python3 >/dev/null 2>&1 &&
           python3 "$ROOT/scripts/process-sprite.py" "$CACHE/sprites/$species.png" \
               "$CACHE/.card-sprite.png" "$CACHE/.card-sprite-flip.png" 320 2>/dev/null; then
            sprite="$CACHE/.card-sprite.png"
        fi
    fi
    case "$sprite" in *.png) mime="image/png" ;; esac
    b64=""
    [ -n "$sprite" ] && b64="$(base64 < "$sprite" | tr -d '\n')"

    local L_TRAINER L_STREAK L_STAGE L_DEX L_DAYS
    if [ "$lang" = "ko" ]; then
        L_TRAINER="트레이너"; L_STREAK="연속"; L_DAYS="일"
        L_STAGE="진화 단계"; L_DEX="도감"
    else
        L_TRAINER="TRAINER"; L_STREAK="STREAK"; L_DAYS="d"
        L_STAGE="STAGE"; L_DEX="DEX"
    fi
    local star=""
    [ "$shiny" = "true" ] && star='<path d="M292 30 l4 9 9 1 -7 7 2 10 -8 -5 -8 5 2 -10 -7 -7 9 -1 z" fill="#f5d76e"/>'

    # anything externally-set or data-driven gets XML-escaped ($USER can
    # legally contain &/< — one bad char would break the SVG and the PNG)
    local user_x name_x
    user_x="$(xml_escape "$USER")"
    name_x="$(xml_escape "$name")"

    cat > "$CACHE/card.svg" <<CARDEOF
<svg xmlns="http://www.w3.org/2000/svg" width="480" height="280" font-family="Menlo, Consolas, monospace">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#22262e"/><stop offset="1" stop-color="#15171c"/>
  </linearGradient></defs>
  <rect width="480" height="280" rx="16" fill="url(#g)"/>
  <rect x="0" y="0" width="480" height="8" rx="4" fill="$hex"/>
  <text x="28" y="52" font-size="22" font-weight="bold" fill="#f2e6c8">$name_x</text>
  <text x="28" y="80" font-size="14" fill="#c9cdb8">Lv.$lv · $L_STAGE $stage/$stages</text>
  <text x="28" y="118" font-size="13" fill="#9aa08c">$L_STREAK $streak$L_DAYS</text>
  <text x="28" y="146" font-size="13" fill="#9aa08c">$L_DEX pokemon $pcount/151 · digimon $dcount/70</text>
  <text x="28" y="168" font-size="13" fill="#9aa08c">shiny $scount</text>
  $star
  <image href="data:$mime;base64,$b64" x="290" y="60" width="160" height="160"/>
  <text x="28" y="244" font-size="12" fill="#6f7462">$L_TRAINER $user_x · $TODAY</text>
  <text x="28" y="262" font-size="10" fill="#4d5145">claude-pokemon-pet</text>
</svg>
CARDEOF

    # ANSI card: left rail only — fixed-width right borders can't survive
    # double-width Hangul or emoji, so we don't pretend to have one
    printf '▛▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\n'
    printf '▌ %s%s  Lv.%s\n' "$name" "$( [ "$shiny" = "true" ] && printf ' ✨' )" "$lv"
    printf '▌ %s %s/%s\n' "$L_STAGE" "$stage" "$stages"
    printf '▌ %s %s%s · %s p:%s/151 d:%s/70 ✨%s\n' "$L_STREAK" "$streak" "$L_DAYS" "$L_DEX" "$pcount" "$dcount" "$scount"
    printf '▌ %s %s · %s\n' "$L_TRAINER" "$USER" "$TODAY"
    printf '▙▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄\n'
    echo "card: $CACHE/card.svg"

    # PNG when a rasterizer works — success-based cascade, never silent:
    # a tool being installed doesn't mean it converted
    local png_ok=false tried=false
    if command -v rsvg-convert >/dev/null 2>&1; then
        tried=true
        rsvg-convert -o "$CACHE/card.png" "$CACHE/card.svg" 2>/dev/null && png_ok=true
    fi
    if [ "$png_ok" = false ] && command -v magick >/dev/null 2>&1; then
        tried=true
        magick "$CACHE/card.svg" "$CACHE/card.png" 2>/dev/null && png_ok=true
    fi
    if [ "$png_ok" = false ] && command -v qlmanage >/dev/null 2>&1; then
        tried=true
        if ( cd "$CACHE" && qlmanage -t -s 960 -o . card.svg >/dev/null 2>&1 ) &&
           [ -f "$CACHE/card.svg.png" ]; then
            mv "$CACHE/card.svg.png" "$CACHE/card.png"
            # quicklook pads its thumbnail to a square with unpredictable
            # placement — cropping blind makes it worse, so we don't
            echo "note: quicklook fallback pads the PNG square — install rsvg-convert or imagemagick for an exact-size card" >&2
            png_ok=true
        fi
    fi
    if [ "$png_ok" = true ]; then
        echo "png:  $CACHE/card.png"
    elif [ "$tried" = true ]; then
        echo "note: PNG conversion failed — the SVG at $CACHE/card.svg still works" >&2
    fi
    return 0
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
    duel)            cmd_duel ;;
    dex)             cmd_dex ;;
    card)            cmd_card ;;
    status)          cmd_status ;;
    *) echo "usage: pet-core.sh <event <state>|roll|roll-if-new-day|pick <name>|lang <ko|en|auto>|resolve|duel>" >&2; exit 1 ;;
esac
