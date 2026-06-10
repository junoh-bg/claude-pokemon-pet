# claude-pokemon-pet

A floating Pokémon companion for Claude Code (macOS). A random gen-1 Pokémon
appears on your screen each day, reacts to what Claude is doing, levels up
with every completed task, and evolves along its real evolution chain.

![demo](https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated/6.gif)

- **Reacts to your session** — roams around while Claude works
  (`CHARIZARD used FLAMETHROWER!`), bobs while thinking, hops when a task
  completes (`It's super effective!`), fidgets when Claude needs your input,
  and falls asleep when idle.
- **Levels & evolves** — Lv = tasks Claude completed today (resets daily).
  Evolves at Lv.6 and Lv.16, with an EXP bar and a proper
  `What? CHARMANDER is evolving!` moment.
- **New partner daily** — one of 81 gen-1 evolution chains is rolled each
  day (Magikarp days build character). `/pet random` rerolls anytime.
- **Stays out of the way** — click-through, always-on-top, no background
  card. Hold ⌥ and drag to reposition; the spot is remembered.

## Install

Requires macOS, [Homebrew](https://brew.sh) packages `jq` and `gifsicle`:

```
brew install jq gifsicle
```

In Claude Code:

```
/plugin marketplace add junoh-bg/claude-pokemon-pet
/plugin install claude-pokemon-pet@claude-pokemon-pet
```

Start a new session — sprites download automatically (~5 MB, one time) and
your first partner appears in the bottom-right corner.

## Use

`/pet` from Claude Code, or the CLI directly:

```
scripts/claude-pet            # toggle overlay (also: on | off)
scripts/claude-pet random     # roll a new random partner
scripts/claude-pet pet mew    # pick a specific pokémon (eevee → random branch)
scripts/claude-pet status     # overlay pid, chain, state, tasks
```

Optional: put the CLI on your PATH and bind a tmux key:

```
ln -s ~/.claude/plugins/marketplaces/claude-pokemon-pet/scripts/claude-pet /opt/homebrew/bin/claude-pet
# ~/.tmux.conf
bind P run-shell "claude-pet toggle"
```

## How it works

| Piece | Role |
|---|---|
| `hooks/hooks.json` | registers Claude Code hooks automatically on install |
| `scripts/pet-state.sh` | hook helper: writes session state + task counter to `~/.cache/claude-pet/` |
| `scripts/pet-overlay.js` | JXA/AppKit overlay: native GIF playback, 20fps motion engine, battle-log captions |
| `scripts/claude-pet` | CLI |
| `scripts/get-sprites.sh` | downloads sprites, builds nearest-neighbor upscales + mirrored variants |
| `data/chains.json` | 81 gen-1 evolution chains + primary type (drives evolution and move pool) |
| `data/gen1.txt` | dex number ↔ name |

Hook events: UserPromptSubmit → thinking, PostToolUse → working,
Stop → done (+1 task), PermissionRequest → waiting, SessionStart → hello +
overlay autostart (`claude-pet off` disables autostart until `on`).

Tunables live at the top of `pet-overlay.js`: evolution thresholds,
roam range, bottom offset.

## Credits

Sprites are fetched at install time from
[PokeAPI/sprites](https://github.com/PokeAPI/sprites) (gen-5 Black/White
animated set) and are not redistributed with this repo. Pokémon is © Nintendo
/ Creatures Inc. / GAME FREAK inc. This is a fan-made tool, not affiliated
with or endorsed by them.

MIT licensed — see [LICENSE](LICENSE).
