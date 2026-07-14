# Phase 5: Trainer Card + Docs Overhaul — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `claude-pokemon-pet card` renders a shareable trainer card — SVG always (zero deps), PNG when a rasterizer is available (`rsvg-convert` → `magick` → macOS `qlmanage`, all probed), plus an ANSI card printed in the terminal. Also: the documentation overhaul (README restructure, docs/ index).

**Architecture:** `cmd_card` in the core reads `resolved.json` + `dex.json`, composes the SVG with printf templating (sprite embedded as a base64 GIF data URI — rasterizers render the first frame), cascades converters, prints an ANSI card + file paths. Pure view; no new state.

**Tech Stack:** bash 3.2 + jq + `base64`; feasibility verified live on this machine (qlmanage renders the SVG+embedded-GIF probe; rsvg-convert also present).

## Global Constraints

- All prior invariants. No emoji inside the SVG (font-dependent tofu in rasterizers) — plain text labels; emoji stay in the ANSI card only.
- Card colors keyed off the partner's type via a bash lookup mirroring the overlay's `TYPE_RGB` accents; `vpet` gets the LCD green.
- Localized (resolved `lang`): en/ko label sets, complete in each language — no mixing.
- Output to `$CACHE/card.svg` (+ `card.png` when converted); never write the repo or CWD.
- Version 0.8.0 at the end.

## File Structure

| File | Change |
|---|---|
| `scripts/pet-core.sh` | `cmd_card` + `card` dispatcher entry |
| `scripts/claude-pokemon-pet` | `card` subcommand |
| `commands/pet.md` | "card", "trainer card", "카드" mapping |
| `tests/test-card.sh` | new suite |
| `README.md` | trainer card section + full restructure (docs overhaul) |
| `docs/README.md` | new: index of specs / plans / milestones / notes |
| `CLAUDE.md` | phase status, card notes |
| `.claude-plugin/plugin.json` | 0.8.0 |

---

### Task 1: `cmd_card` (TDD)

**Interfaces produced:** `pet-core.sh card` → prints an ANSI card + `card: <svg path>` (+ `png: <path>` when converted); writes `$CACHE/card.svg`. SVG contains: name, `Lv.N`, stage `k/n`, streak, dex per-franchise counts, shiny marker (`STAR`-drawn, not emoji), trainer (`$USER`), date, plugin footer.

- [ ] **Step 1: Failing tests** — `tests/test-card.sh`:

```bash
#!/bin/bash
. "$(dirname "$0")/lib.sh"
set_tasks() { echo "2026-07-13 $1" > "$CACHE/tasks"; }

setup  # card generates SVG with the partner's real data
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0,"shiny":true}' > "$CACHE/partner"
set_tasks 7; "$CORE" resolve
out="$("$CORE" card)"
assert_eq "card exits 0" "0" "$?"
assert_eq "svg written" "yes" "$([ -f "$CACHE/card.svg" ] && echo yes || echo no)"
case "$(cat "$CACHE/card.svg")" in *CHARMELEON*) ok=yes ;; *) ok=no ;; esac
assert_eq "svg has name" "yes" "$ok"
case "$(cat "$CACHE/card.svg")" in *"Lv.7"*) ok=yes ;; *) ok=no ;; esac
assert_eq "svg has level" "yes" "$ok"
case "$(cat "$CACHE/card.svg")" in *"data:image/gif;base64,"*) ok=yes ;; *) ok=no ;; esac
assert_eq "svg embeds sprite" "yes" "$ok"
case "$out" in *"card:"*) ok=yes ;; *) ok=no ;; esac
assert_eq "prints svg path" "yes" "$ok"
case "$out" in *CHARMELEON*) ok=yes ;; *) ok=no ;; esac
assert_eq "ansi card printed" "yes" "$ok"
if python3 -c 'import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])' "$CACHE/card.svg" 2>/dev/null; then ok=yes; else ok=no; fi
assert_eq "svg is well-formed xml" "yes" "$ok"
teardown

setup  # korean card is fully korean
printf '{"franchise":"pokemon","line":["charmander","charmeleon","charizard"],"type":"fire","date":"2026-07-13","seed":0,"shiny":false}' > "$CACHE/partner"
echo ko > "$CACHE/lang"; set_tasks 3; "$CORE" resolve; "$CORE" card >/dev/null
case "$(cat "$CACHE/card.svg")" in *리자드*) ok=yes ;; *) ok=no ;; esac
assert_eq "ko card has ko name" "yes" "$ok"
case "$(cat "$CACHE/card.svg")" in *트레이너*) ok=yes ;; *) ok=no ;; esac
assert_eq "ko card has ko labels" "yes" "$ok"
teardown
report
```

- [ ] **Step 2: red.**

- [ ] **Step 3: Implement `cmd_card`** in `scripts/pet-core.sh` (+ `card) cmd_card ;;` in the dispatcher):

```bash
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

cmd_card() {
    [ -f "$CACHE/resolved.json" ] || cmd_resolve
    [ -f "$CACHE/dex.json" ] || echo '[]' > "$CACHE/dex.json"
    local name lv stage stages species shiny streak lang fr typ hex sprite b64
    name="$(jq -r '.name' "$CACHE/resolved.json")"
    lv="$(jq -r '.tasks' "$CACHE/resolved.json")"
    stage="$(jq -r '.stage' "$CACHE/resolved.json")"
    stages="$(jq -r '.stages' "$CACHE/resolved.json")"
    species="$(jq -r '.species' "$CACHE/resolved.json")"
    shiny="$(jq -r '.shiny' "$CACHE/resolved.json")"
    streak="$(jq -r '.streak' "$CACHE/resolved.json")"
    lang="$(jq -r '.lang' "$CACHE/resolved.json")"
    fr="$(jq -r '.franchise' "$CACHE/resolved.json")"
    typ="$(jq -r '.type' "$CACHE/resolved.json")"
    hex="$(printf '%s\n' "$TYPE_HEX_TABLE" | while read -r t h; do [ "$t" = "$typ" ] && echo "$h"; done)"
    [ -n "$hex" ] || hex="#b5ad9b"
    local pcount dcount scount
    pcount="$(jq '[.[] | select(.franchise == "pokemon")] | length' "$CACHE/dex.json")"
    dcount="$(jq '[.[] | select(.franchise == "digimon")] | length' "$CACHE/dex.json")"
    scount="$(jq '[.[] | select(.shiny)] | length' "$CACHE/dex.json")"
    sprite="$CACHE/sprites-big/$species$( [ "$shiny" = "true" ] && echo -shiny ).gif"
    [ -f "$sprite" ] || sprite="$CACHE/sprites/$species.gif"
    b64=""
    [ -f "$sprite" ] && b64="$(base64 < "$sprite" | tr -d '\n')"

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

    cat > "$CACHE/card.svg" <<CARDEOF
<svg xmlns="http://www.w3.org/2000/svg" width="480" height="280" font-family="Menlo, Consolas, monospace">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#22262e"/><stop offset="1" stop-color="#15171c"/>
  </linearGradient></defs>
  <rect width="480" height="280" rx="16" fill="url(#g)"/>
  <rect x="0" y="0" width="480" height="8" rx="4" fill="$hex"/>
  <text x="28" y="52" font-size="22" font-weight="bold" fill="#f2e6c8">$name</text>
  <text x="28" y="80" font-size="14" fill="#c9cdb8">Lv.$lv · $L_STAGE $stage/$stages</text>
  <text x="28" y="118" font-size="13" fill="#9aa08c">$L_STREAK $streak$L_DAYS</text>
  <text x="28" y="146" font-size="13" fill="#9aa08c">$L_DEX pokemon $pcount/151 · digimon $dcount/70</text>
  <text x="28" y="168" font-size="13" fill="#9aa08c">shiny $scount</text>
  $star
  <image href="data:image/gif;base64,$b64" x="290" y="60" width="160" height="160"/>
  <text x="28" y="244" font-size="12" fill="#6f7462">$L_TRAINER $USER · $TODAY</text>
  <text x="28" y="262" font-size="10" fill="#4d5145">claude-pokemon-pet</text>
</svg>
CARDEOF

    # ANSI card
    printf '┌────────────────────────────────┐\n'
    printf '│ %-24s %s │\n' "$name" "$( [ "$shiny" = "true" ] && printf '✨' || printf '  ')"
    printf '│ Lv.%-4s %s %s/%s              │\n' "$lv" "$L_STAGE" "$stage" "$stages"
    printf '│ %s %s%s · %s p:%s d:%s        │\n' "$L_STREAK" "$streak" "$L_DAYS" "$L_DEX" "$pcount" "$dcount"
    printf '│ %s %s · %s          │\n' "$L_TRAINER" "$USER" "$TODAY"
    printf '└────────────────────────────────┘\n'
    echo "card: $CACHE/card.svg"

    # PNG when a rasterizer exists (exact-size first, quicklook fallback)
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -o "$CACHE/card.png" "$CACHE/card.svg" 2>/dev/null && echo "png:  $CACHE/card.png"
    elif command -v magick >/dev/null 2>&1; then
        magick "$CACHE/card.svg" "$CACHE/card.png" 2>/dev/null && echo "png:  $CACHE/card.png"
    elif command -v qlmanage >/dev/null 2>&1; then
        ( cd "$CACHE" && qlmanage -t -s 960 -o . card.svg >/dev/null 2>&1 ) &&
            [ -f "$CACHE/card.svg.png" ] && mv "$CACHE/card.svg.png" "$CACHE/card.png" && echo "png:  $CACHE/card.png"
    fi
}
```

- [ ] **Step 4: green**, plus a real run against the live cache: `scripts/pet-core.sh card` — confirm PNG produced and open it visually (`open $CACHE/card.png`) — one manual eyeball since SVG rasterization can't be asserted by grep.
- [ ] **Step 5: Commit** `feat: trainer card — svg/png/ansi`.

### Task 2: CLI + command doc

- [ ] `card)  "$CORE" card ;;` + usage line in `scripts/claude-pokemon-pet`; `commands/pet.md`: "card", "trainer card", "카드" → `card`. Suite green. Commit `feat: card subcommand`.

### Task 3: Docs overhaul

- [ ] **README restructure**: order — hero/demo → Features (trim to 6 crisp bullets covering both franchises) → Requirements (per-mode table) → Install → Usage (slash command, CLI, franchises, terminal mode, statusline, dex, card, positioning/⌥-drag, language) → Configuration → Updating → Troubleshooting → Uninstall → How it works → Privacy → Credits. Fix stale bits (intro already covers digimon; make the hero line franchise-neutral: "A Pokémon & Digimon companion for Claude Code").
- [ ] **docs/README.md** (new): one-page index — what lives in `docs/superpowers/specs` (approved designs), `docs/superpowers/plans` (per-phase implementation plans), `docs/milestones` (post-phase review reports), `docs/notes` (verified technical findings), with links to each file and one-line descriptions.
- [ ] **CLAUDE.md**: mark phase 5 ✅ (add card to piece list), prune anything stale.
- [ ] Commit `docs: restructure README, add docs index`.

### Task 4: Version + QA

- [ ] 0.8.0; suite on macOS + Debian container (card test must pass there too — no rasterizer in the container: PNG step skips cleanly, SVG+ANSI still asserted); real-cache card eyeball.
- [ ] Commit `docs: v0.8.0 — trainer card`.

## Post-plan checks
Review loop → PASS; milestone doc; PR → auto-merge. (The franchise-identity plan is a separate decision doc — not part of this branch.)
