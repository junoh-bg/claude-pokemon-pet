# Claude Pet — Pokémon & Digimon

A companion for Claude Code that lives on your screen. A random partner
appears each day, reacts to what Claude is doing, levels up with every
completed task, and evolves along its real evolution chain — 151 gen-1
Pokémon, or the five original 1997 Digimon V-pet lines with branching
evolution that judges how your session went.

<p align="center">
  <img src="assets/demo.gif" width="720" alt="claude-pokemon-pet — a Charizard reacting to a Claude Code session">
</p>

On macOS it floats over everything as a native overlay. On Linux, over SSH,
or on a headless RunPod it lives inside your terminal or your statusline.

## Quick start

```
/plugin marketplace add junoh-bg/claude-pokemon-pet
/plugin install claude-pokemon-pet@claude-pokemon-pet
/reload-plugins
```

macOS: `brew install jq gifsicle` first. That's it — your partner appears
bottom-right on the next session. Then try:

```sh
claude-pokemon-pet digimon     # switch franchise
claude-pokemon-pet dex         # your collection
claude-pokemon-pet card        # a shareable trainer card
```

## Commands

Everything is available two ways: the slash command
(`/claude-pokemon-pet:pet …` — type `/pet` and pick it) or the bundled CLI
(`~/.claude/plugins/marketplaces/claude-pokemon-pet/scripts/claude-pokemon-pet`,
worth symlinking onto your PATH).

| Command | What it does |
|---|---|
| *(none)* / `toggle` | overlay on/off (off also disables session autostart) |
| `on` · `off` | explicit overlay control |
| `random` | reroll today's partner (same franchise) |
| `digimon` · `pokemon` | switch franchise — rolls a fresh partner in it |
| `pet <name>` | pick a species — English or Korean (`pet pikachu`, `pet 파이리`, `pet agumon`) |
| `dex` | everything you've ever raised, per franchise, shinies marked |
| `card` | render a trainer card (PNG/SVG file + ANSI inline) |
| `term` | run the pet inside the current terminal (Linux/SSH/anywhere) |
| `statusline` | print setup for the one-line statusline pet |
| `lang ko` · `en` · `auto` | language override (default: system language) |
| `status` | partner, stage, today's tasks / care mistakes / streak |
| `sprites` | re-download sprite art |

## Your pet's day

| Session event | Pet reaction |
|---|---|
| You submit a prompt | slow bob — `PIKACHU is getting pumped!` |
| Claude uses tools | roams and waddles; every battle caption fires a lunge with element-colored impact sparks — `AGUMON used Baby Flame!` strikes in fire-orange |
| Task completes | excited hops, impact shake, **+1 level** |
| A tool call fails | **+1 care mistake** — HP bar dips, the pet recoils (and Digimon evolution takes note) |
| Permission needed | anxious fidget |
| Idle | falls asleep, dimmed |

- **Level = tasks Claude completed today** (resets at midnight; the daily
  gacha rolls a fresh partner each morning — shiny 1/64 ✨).
- **Evolution** comes with a proper cinematic: sprite flash,
  `What? CHARMANDER is evolving!`, then
  `Congratulations! Your CHARMANDER evolved into CHARMELEON!`
- Pokémon evolve at Lv.6 and Lv.16. Fully evolved partners grind a gold
  EXP bar instead.
- A 🔥 streak flame appears at 2+ consecutive days with completed tasks.

## Digimon mode

```sh
claude-pokemon-pet digimon
```

One of the five original **Digital Monster** V-pet lines (Ver.1–Ver.5, 70
species), drawn with colorful official art. Five stages, gated by today's
tasks: Baby → In-Training (2) → Rookie (5) → Champion (10) → Ultimate (18).

Unlike Pokémon, evolution **branches** — and it watches your session.
Care mistakes (failing tool calls; pressing Esc doesn't count) decide the
branch at each evolution gate:

- **0 mistakes** — the canonical branch, audited against the anime and
  games: a flawless 아구몬 becomes 그레이몬, 가부몬 becomes 가루몬.
- **1–2 mistakes** — a mid-tier champion from the rest of the chart
  (seeded per day, so it's stable until midnight).
- **3+ mistakes** — the canonical joke path: Numemon and friends await
  the sloppy.

Every choice locks in the moment it happens, exactly like the 1997
device. `status` shows today's tally.

Battle text uses each species' real signature attack in your language:
`아구몬의 베이비 플레임!` / `AGUMON used Baby Flame!` — with official
Korean names for all 70 species.

## Terminal mode — Linux, SSH, RunPods

No display needed. The pet renders *inside* a terminal, so it works over
SSH to a headless box — the graphics stream as ordinary terminal output:

```sh
claude-pokemon-pet term        # in a tmux split or a second SSH session
```

Run it **on the machine where Claude Code runs** (that's where the hooks
and state live). Graphics auto-detect, best first:

| Tier | Terminals |
|---|---|
| Kitty graphics protocol | kitty, WezTerm, Ghostty |
| iTerm2 inline images | iTerm2 |
| ANSI half-blocks | any 256-color terminal, including inside tmux |

Force one with `PET_TERM_MODE=kitty|iterm|ansi`. Quit with **q**, Esc, or
Ctrl-C — the pane is restored either way (if a force-killed session ever
leaves it stuck, type `reset` to recover it).

## Statusline pet

The universal fallback — one line in Claude Code's statusline, works in
absolutely any terminal:

```
🔥 리자몽 Lv.23 ▰▰▰▱▱ ⚔️
```

`claude-pokemon-pet statusline` prints the one-line `settings.json` snippet
(we never edit your settings for you) and a live preview.

## Dex & trainer card

```
$ claude-pokemon-pet dex
pokemon: caught 23/151
digimon: caught 8/70
shiny: 1 ✨
  2026-07-13  charmander
  2026-07-14  patamon ✨
```

```sh
claude-pokemon-pet card
```

Writes `card.svg` (always) and `card.png` (when `rsvg-convert`,
ImageMagick, or macOS Quick Look is available — Quick Look pads it square;
`brew install librsvg` for an exact-size card), plus an ANSI card inline:
partner art, level, stage, streak, dex progress, trainer name — in your
language.

## Positioning & language

- The overlay is system-wide, above every app and Space, and click-through.
  **Hold ⌥ (Option) and drag** to move it anywhere (saved across restarts).
- Names and battle text follow your system language — Korean systems get
  official names and battle text (`피카츄의 10만볼트!`,
  `효과는 굉장했다!`). Override with `lang ko` / `lang en` / `lang auto`.

## Requirements

Everyone needs Claude Code with plugin support and
[`jq`](https://jqlang.github.io/jq/). Per mode:

| Mode | Needs |
|---|---|
| Floating overlay (macOS) | [`gifsicle`](https://www.lcdf.org/gifsicle/); digimon sprites also use `python3` (present with Xcode CLT) |
| Terminal pet | any OS + `python3` (≥3.8, stdlib only) + `curl` |
| Statusline | just `jq` |
| Trainer card PNG (optional) | `rsvg-convert` or ImageMagick (Quick Look works, padded) |

## Updating

```
/plugin marketplace update claude-pokemon-pet
/reload-plugins
```

<details>
<summary><b>Troubleshooting</b></summary>

- **No pet after install** — run `claude-pokemon-pet status`; it names any
  missing dependency.
- **Pet on the wrong screen** — it spawns on the screen your mouse is on at
  start; ⌥-drag it anywhere, including across displays.
- **Reset position** — `rm ~/.cache/claude-pokemon-pet/pos`, restart the pet.
- **Re-download sprites** — `claude-pokemon-pet sprites`.
- **Full reset** (level, partner, dex, position, sprites) —
  `rm -r ~/.cache/claude-pokemon-pet`, then start a new session.
</details>

<details>
<summary><b>How it works</b></summary>

| Piece | Role |
|---|---|
| `hooks/hooks.json` | registers Claude Code hooks on install |
| `scripts/pet-core.sh` | the game core: reduces hook events to `resolved.json` — the single file every renderer reads |
| `scripts/pet-overlay.js` | macOS overlay (JXA/AppKit), a pure view: GIF/PNG playback, 20 fps motion, FX, ⌥-drag |
| `scripts/pet-term.py` + `petgif.py` / `petpng.py` | terminal renderer (pure-stdlib Python): image decode, kitty/iTerm2/ANSI backends |
| `scripts/pet-statusline.sh` | one-line statusline renderer |
| `scripts/get-sprites.sh` + `process-sprite.py` | sprite fetch + install-time processing (border flood-fill keying) |
| `data/pokemon/pack.json` · `data/digimon/pack.json` | franchise packs: species, evolution graphs, names (en/ko), attacks, sprite sources |

Hook events: `UserPromptSubmit` → thinking, `PostToolUse` → working,
`PostToolUseFailure` → care mistake, `Stop` → done (+1 task),
`PermissionRequest` → waiting, `SessionStart` → hello + autostart. All
state lives in `~/.cache/claude-pokemon-pet/`; the plugin directory is
never written to. Developer docs: [`docs/`](docs/).
</details>

## Privacy & security

Runs entirely on your machine. Sprites are downloaded once at install
(from PokeAPI and digi-api) — no other network calls, no data collected,
nothing sent anywhere. The overlay is a local `osascript` window; every
hook is a small shell script you can read in `scripts/`.

## Credits

Sprites are fetched at install time and never redistributed: Pokémon from
[PokeAPI/sprites](https://github.com/PokeAPI/sprites) (gen-5 animated set),
Digimon official art from [digi-api](https://digi-api.com); evolution-chart
and Korean-name data curated from [Wikimon](https://wikimon.net) and
Bandai's official Korean reference. Pokémon © Nintendo / Creatures Inc. /
GAME FREAK inc.; Digimon © Bandai. A fan-made tool, not affiliated with or
endorsed by them. MIT licensed — see [LICENSE](LICENSE).
