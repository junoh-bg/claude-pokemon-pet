# claude-pokemon-pet

A floating Pokémon companion for Claude Code (macOS). A random gen-1 Pokémon
appears on your screen, reacts to what Claude is doing, levels up with every
completed task, and evolves along its real evolution chain.

![charizard](https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/6.gif)

## Features

- **Reacts to your session** — roams around while Claude works
  (`CHARIZARD used FLAMETHROWER!`), bobs while thinking, hops when a task
  completes (`It's super effective!`), fidgets when Claude needs your input,
  and falls asleep when you're idle.
- **Levels & evolves** — its level is the number of tasks Claude completed
  today (resets at midnight). It evolves at Lv.6 and Lv.16 with an EXP bar
  and a proper `What? CHARMANDER is evolving!` moment.
- **Daily gacha** — one of 81 gen-1 evolution chains is rolled the first time
  the overlay starts each day (Magikarp days build character). Your partner
  never changes mid-run; reroll anytime with `/pet random`.
- **Stays out of the way** — click-through and always-on-top, so it never
  steals clicks or focus. Hold ⌥ (Option) and drag to reposition; the spot
  is remembered across restarts.

## Requirements

| Requirement | Why |
|---|---|
| macOS | the overlay is a native AppKit window (JXA) |
| Claude Code with plugin support | hooks + `/pet` command register via the plugin system |
| [`jq`](https://jqlang.github.io/jq/) | the CLI reads the evolution-chain data (JSON) from shell |
| [`gifsicle`](https://www.lcdf.org/gifsicle/) | upscales sprites pixel-perfect (nearest-neighbor) and builds mirrored walking frames |

`jq` and `gifsicle` are the only things to install — everything else
(`curl`, `osascript`) ships with macOS:

```sh
brew install jq gifsicle
```

## Install

1. Install the dependencies above.
2. In Claude Code:

   ```
   /plugin marketplace add junoh-bg/claude-pokemon-pet
   /plugin install claude-pokemon-pet@claude-pokemon-pet
   ```

3. Start a new Claude Code session.

On the first session, sprites for all 151 gen-1 Pokémon are downloaded
(~5 MB, one time, a few seconds) and your first partner appears in the
bottom-right corner of the screen your mouse is on.

## Usage

### `/pet` from Claude Code

```
/pet            toggle the overlay
/pet random     roll a new random partner
/pet mew        switch to a specific pokémon (eevee picks a random branch)
/pet status     show partner, state, and today's task count
```

### CLI

The same commands are available from your shell via the bundled CLI:

```sh
<plugin-dir>/scripts/claude-pet [toggle|on|off|random|pet <name>|sprites|status]
```

Find your plugin directory with `ls ~/.claude/plugins` (it is the directory
containing `scripts/claude-pet`). Optionally symlink it onto your PATH and
bind a tmux key:

```sh
ln -s <plugin-dir>/scripts/claude-pet /opt/homebrew/bin/claude-pet
```

```tmux
# ~/.tmux.conf
bind P run-shell "/opt/homebrew/bin/claude-pet toggle"
```

`claude-pet off` also disables the session autostart until you run
`claude-pet on` (or `/pet`) again.

### Moods

| Session event | Pet behavior | Caption |
|---|---|---|
| You submit a prompt | slow bob | `PIKACHU is getting pumped!` |
| Claude uses tools | roams left/right, faces its walking direction | `PIKACHU used THUNDERBOLT!` |
| Task completes | excited hops (+1 Lv) | `It's super effective!` |
| Permission needed | anxious fidget | `PIKACHU looks at you expectantly` |
| New session | greeting hops | `Go! PIKACHU!` |
| Idle | breathing, dimmed | `PIKACHU is fast asleep` |

## Configuration

Tunables at the top of `scripts/pet-overlay.js`:

| Constant | Default | Meaning |
|---|---|---|
| `EVO2` / `EVO3` | 6 / 16 | tasks per day to reach stage 2 / 3 |
| `BOTTOM_OFFSET` | 30 | default distance from the bottom screen edge (px) |
| `ROAM` | 240 | how far it wanders while working (px) |

## Troubleshooting

- **No pet after install** — run `<plugin-dir>/scripts/claude-pet status`.
  Most common cause: missing `jq`/`gifsicle` (the CLI prints which).
- **Pet on the wrong screen** — it spawns on the screen your mouse is on at
  start. `/pet` twice (off/on) with the mouse on the right screen, or ⌥-drag
  it anywhere, including across displays.
- **Reset position** — `rm ~/.cache/claude-pet/pos`, then restart the pet.
- **Re-download sprites** — `<plugin-dir>/scripts/claude-pet sprites`.
- **Full reset** (level, partner, position, sprites) —
  `rm -r ~/.cache/claude-pet`, then start a new session.

## Uninstall

```
/plugin uninstall claude-pokemon-pet
```

then remove the runtime cache and the optional symlink:

```sh
rm -r ~/.cache/claude-pet
rm -f /opt/homebrew/bin/claude-pet
```

## How it works

| Piece | Role |
|---|---|
| `hooks/hooks.json` | registers Claude Code hooks automatically on install |
| `scripts/pet-state.sh` | hook helper: writes session state + task counter to `~/.cache/claude-pet/` |
| `scripts/pet-overlay.js` | JXA/AppKit overlay: native GIF playback, 20 fps motion engine, battle-log captions, ⌥-drag |
| `scripts/claude-pet` | CLI; rolls the daily gacha at overlay start |
| `scripts/get-sprites.sh` | downloads sprites, builds nearest-neighbor upscales + mirrored variants |
| `data/chains.json` | 81 gen-1 evolution chains + primary type (drives evolution and move pool) |
| `data/gen1.txt` | dex number ↔ name |

Hook events: `UserPromptSubmit` → thinking, `PostToolUse` → working,
`Stop` → done (+1 task), `PermissionRequest` → waiting, `SessionStart` →
hello + overlay autostart. All state lives in `~/.cache/claude-pet/`; the
plugin directory itself is never written to.

## Credits

Sprites are fetched at install time from
[PokeAPI/sprites](https://github.com/PokeAPI/sprites) (gen-5 Black/White
animated set) and are not redistributed with this repo. Pokémon is © Nintendo
/ Creatures Inc. / GAME FREAK inc. This is a fan-made tool, not affiliated
with or endorsed by them.

MIT licensed — see [LICENSE](LICENSE).
