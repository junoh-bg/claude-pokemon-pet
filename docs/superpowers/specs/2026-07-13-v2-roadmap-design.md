# claude-pokemon-pet v2 — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorming complete)
**Scope:** One combined design covering four tracks — terminal-first portability
(Linux / SSH / RunPod), Digimon franchise pack with V-pet mechanics, UI
upgrades, and extras (statusline pet, trainer card) — implemented as a phased
roadmap.

## Goals

1. **Portability**: the pet works for users on Linux and, critically, for
   researchers who SSH into headless boxes (RunPod GPU pods, remote dev
   machines, devcontainers). A GUI overlay cannot work there; a
   terminal-rendered pet can, because terminal graphics stream over SSH.
2. **Digimon**: a second franchise with authentic 1997 V-pet mechanics —
   5–6 evolution stages and *branching* evolution driven by how well the
   session is going (care mistakes).
3. **UI upgrades** for the existing macOS overlay: Battle FX, shinies + dex
   collection, richer HUD, evolution cinematics.
4. **Extras**: statusline pet (universal fallback renderer), shareable
   trainer card.

Non-goals (explicitly out of scope): a Linux desktop GUI overlay (GTK),
sound effects, subagent mini-pets. These were considered and deferred.

## Architecture: shared core + thin renderers

Guiding principle: **hooks write events → a bash+jq core reduces them to
`resolved.json` → renderers are pure views.**

We go from one renderer × one franchise to three renderers (macOS JXA
overlay, terminal, statusline) × two franchises (Pokémon, Digimon). Game
logic must therefore live in exactly one place. The JXA overlay and a
Python terminal renderer cannot share executable code, but they can share:

1. **Franchise packs** (JSON data),
2. **State + resolution** (computed by the bash core into `resolved.json`).

Renderers contain zero game logic.

### Franchise packs

`data/chains.json` generalizes to `data/pokemon/pack.json` and
`data/digimon/pack.json`. A pack contains:

- **species**: id, display names (`en`, `ko` where available), dex number,
  primary type.
- **evolution graph**: nodes (species) and edges with conditions:
  `min_tasks` (daily task threshold), `max_mistakes` (care-mistake ceiling),
  `fallback: true` (taken when no other edge qualifies). Pokémon's linear
  chains are single unconditional edges — current behavior is preserved
  exactly, including Eevee's random branch and the gold cyclic EXP bar after
  the final stage.
- **move pools** (per type, as today).
- **sprite source config**: where `get-sprites.sh` fetches from, cell size,
  upscale factor.

Packs are schema-validated with jq at load; on invalid/missing data the
core falls back to the default partner (Charmander), preserving today's
safe-fallback behavior.

### Core: `scripts/pet-core.sh`

Grows out of `pet-state.sh`. Responsibilities:

- **Record events** (called by hooks and CLI): state changes
  (thinking/working/done/waiting/hello), task completion, tool error,
  gacha roll, franchise switch, manual pet pick.
- **Count care mistakes**: the `PostToolUse` hook starts reading its stdin
  JSON; an erroring tool call increments a daily `mistakes` counter
  (resets at midnight, like `tasks`). *The exact hook payload schema for
  detecting tool errors must be verified at the start of implementation.*
- **Resolve** after every event: write
  `~/.cache/claude-pokemon-pet/resolved.json` containing current species,
  stage, level, EXP %, shiny flag, mood, mistakes count, streak count, and
  caption inputs (display name, move pool, language).
- **Record the dex**: append every partner ever rolled to `dex.json`
  (species, franchise, date, shiny).
- **Track streak**: consecutive days with ≥1 completed task.

Everything stays bash + jq — no new dependencies for the core. All state
remains under `~/.cache/claude-pokemon-pet/`; the plugin directory is never
written to.

### Renderers

- **macOS overlay (`pet-overlay.js`)** — refactored to read
  `resolved.json` instead of computing chains/levels itself. Its animation
  engine (20 fps motion, GIF playback, ⌥-drag) is untouched. Evolution
  detection = comparing the previous resolved snapshot to the current one.
- **Terminal renderer (`scripts/pet-term.py`)** — new, see below.
- **Statusline (`scripts/pet-statusline.sh`)** — new, one-line formatter.

## Terminal renderer + statusline (the Linux/SSH answer)

**Audience decision:** terminal-first. Desktop-Linux GUI overlay is out of
scope; SSH/headless researchers are the primary new audience, and the
terminal renderer also works on desktop Linux and macOS.

- **`claude-pokemon-pet term`** runs a pure-stdlib **Python 3** renderer in
  a tmux split or second terminal pane *on the same box where Claude Code
  runs*. Over SSH the graphics stream to the local screen as ordinary
  terminal output — this is what makes RunPod support work.
- **Graphics tiers**, auto-detected (probe with timeout, fall through):
  1. **Kitty graphics protocol** — kitty, WezTerm, Ghostty, Konsole.
  2. **iTerm2 inline images** — iTerm2 on macOS.
  3. **ANSI half-block pixel art** — any 256-color terminal. Requires
     decoding sprite GIF frames in pure Python (stdlib `zlib`/`struct`;
     a small LZW GIF decoder, ~150 lines).
  No new dependencies at any tier.
- **Features**: same moods, captions, EXP bar, and evolution moments as the
  overlay, adapted to a small fixed-height region: sprite + speech line +
  bar. FX adaptations: ANSI sparkles for particles, row-jiggle for screen
  shake, invert-flash frames for the evolution silhouette.
- **Statusline pet**: `pet-statusline.sh` emits a single line for Claude
  Code's statusline, e.g. `🔥 CHARMELEON Lv.12 ▰▰▰▱ working`. Works in any
  terminal with no graphics support at all — the universal fallback.
  `claude-pokemon-pet statusline` prints setup instructions (a documented
  one-line settings change); we do **not** silently edit the user's
  `settings.json`.

macOS keeps the floating JXA overlay as its premium mode; `term` and the
statusline work there too.

## Digimon franchise pack (V-pet mechanics)

- **Roster**: classic V-pet / Adventure lines, ~40–60 species. Example:
  Botamon → Koromon → Agumon → {Greymon | Tyrannomon | Meramon | Numemon}
  → {MetalGreymon | Mamemon | Monzaemon …} → Mega, plus parallel lines
  from the other Fresh roots (Punimon, Poyomon, …).
- **Stages**: Fresh → In-Training → Rookie → Champion → Ultimate → Mega,
  gated by daily task count. Initial thresholds 0 / 2 / 5 / 10 / 18 / 30
  (pack values, tunable). The existing gold cyclic EXP bar takes over after
  Mega.
- **Branching**: at each evolution the core picks the first edge whose
  conditions pass. Few mistakes → strong forms; ≥3 care mistakes that day →
  the joke `fallback` edge (Numemon). Deterministic and explainable:
  `pet status` shows `care mistakes today: 2`.
- **Care mistakes** = daily count of erroring tool calls (see core section).
- **Sprites — feasibility risk, research gate**: there is no PokeAPI
  equivalent for Digimon.
  - *Recommended source*: original 16×16 V-pet LCD sprites (fan-archived),
    upscaled pixel-perfect by the existing gifsicle pipeline — the
    authentic 1997 tamagotchi look, visually distinct from Pokémon mode.
  - *Fallback source*: Digimon World DS-era color sprites (manual sheet
    extraction; more work, murkier redistribution).
  - Implementation **starts with a research task to lock a reliable,
    fetchable sprite source** before any Digimon code is written. Sprites
    are fetched at install time, never redistributed in the repo (same
    policy as Pokémon).
- **UX**: `pet digimon` / `pet pokemon` switches the active franchise
  (daily gacha rolls within it); `pet random` re-rolls within the active
  franchise; picking a species by name (`pet agumon`) also switches the
  active franchise to that species' franchise. Active franchise persists
  in the cache. Korean names included where data is
  available, English otherwise.
- Digimon mode skips shinies (LCD sprites are monochrome).

## UI upgrades & extras

On the macOS overlay, with terminal adaptations where feasible:

- **Battle FX**: type-colored particle bursts via `CAEmitterLayer`
  (QuartzCore is already imported) synced to move captions; impact flash +
  brief window shake on task completion.
- **Shinies + Dex**: PokeAPI ships the animated *shiny* gen-5 set;
  `get-sprites.sh` fetches it too (+~5 MB, still one-time). 1/64 roll at
  daily gacha, sparkle entrance, persisted for the day. `pet dex` prints
  collection progress from `dex.json` (`caught 23/151 · 1 shiny ✨`,
  per-franchise).
- **Richer HUD**: speech bubble with tail replaces the flat caption bar;
  level badge; daily-streak flame (consecutive days with ≥1 task); an HP
  bar that dips on tool errors and refills on task completion — powered by
  the same `mistakes` counter as Digimon branching.
- **Evolution cinematics**: white-silhouette flash cycles → reveal →
  staged `Congratulations!` caption sequence, in both overlay and terminal.
- **Trainer card**: `pet card` composes an **SVG** (pure text, zero deps)
  with partner art, name, level, stage, dex progress, streak, trainer name
  (`$USER`), date. Converted to PNG when a converter is available
  (`qlmanage` on macOS, ImageMagick where installed); otherwise saves the
  SVG and prints an ANSI card in the terminal.

## Phased roadmap

Each phase ships independently and leaves the plugin fully working.

| Phase | Delivers | Depends on |
|---|---|---|
| 1 | Core refactor: franchise packs, `pet-core.sh`, `resolved.json`, mistakes counter, dex + streak recording; overlay reads core | — |
| 2 | Terminal renderer + statusline → **Linux/RunPod support ships** | 1 |
| 3 | Digimon pack + V-pet branching (sprite research runs in parallel from day 1) | 1 |
| 4 | Shinies, `pet dex`, richer HUD, Battle FX, evolution cinematics | 1 (2 for terminal ports) |
| 5 | Trainer card | 4 (dex) |

## Testing & error handling

- **Core**: fixture-based shell tests — given `tasks`/`mistakes` counts and
  a pack, assert the resolved species/stage/EXP. Runnable in a Linux
  container (CI-friendly, no GUI needed).
- **Terminal renderer**: headless tests asserting emitted escape sequences
  per graphics tier; tier detection has an explicit timeout + fallthrough.
- **Packs**: jq schema validation at load; invalid → safe fallback partner.
- **Dependency checks**: `status` continues to diagnose missing deps
  (jq, gifsicle) and now also reports terminal graphics capability.
- **Hook payloads**: the tool-error detection in `PostToolUse` is verified
  against the real hook stdin schema as the first implementation step of
  Phase 1. If the payload turns out not to expose tool errors, Digimon
  branching degrades to a per-day seeded random branch choice (the design
  alternative we rejected as primary but agreed is safe), and the HP bar is
  dropped from the HUD.

## Decisions log

| Decision | Choice | Alternatives considered |
|---|---|---|
| First track | All three, one phased design | Linux-first, Digimon-first, UI-first |
| Linux audience | Terminal-first (SSH/headless) | Desktop GTK overlay; both |
| Digimon depth | V-pet branching via care mistakes | Linear chains; random branch |
| Architecture | Shared core + thin renderers | Parallel apps; single-runtime rewrite |
| UI upgrades | All four (FX, shinies+dex, HUD, cinematics) | — |
| Extras | Statusline pet, trainer card | Cries/jingles, subagent pets (deferred) |
