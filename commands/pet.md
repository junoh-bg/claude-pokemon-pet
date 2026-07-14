---
description: Manage the Pokémon pet (toggle, random, pick one, status)
---

Manage the Pokémon pet overlay by running the bundled CLI:

```
${CLAUDE_PLUGIN_ROOT}/scripts/claude-pokemon-pet <subcommand>
```

Subcommands: `toggle` | `on` | `off` | `random` | `digimon` | `pokemon` | `pet <name>` | `dex` | `card` | `lang <ko|en|auto>` | `statusline` | `sprites` | `status`.

Map the user's request ("$ARGUMENTS") to the right subcommand:
- empty or "toggle" → `toggle`
- "random", "roll", "new pokemon" → `random`
- "digimon"/"디지몬" → `digimon`; "pokemon"/"포켓몬" → `pokemon` (switch franchise)
- a pokémon or digimon name, English or Korean (e.g. "pikachu", "파이리", "agumon") → `pet <name>`
- "korean"/"한국어" → `lang ko`; "english"/"영어" → `lang en`; "auto" → `lang auto`
- "statusline" → `statusline` (prints setup instructions)
- "dex", "collection", "도감" → `dex` (collection progress)
- "card", "trainer card", "카드" → `card` (renders a shareable trainer card; report the printed file paths)
- "status", "who is my pet" → `status`
- "terminal" → do NOT run it (it is interactive); tell the user to run `claude-pokemon-pet term` in a separate terminal/tmux split
- anything else → show usage

Run it with Bash and report the output to the user in one short sentence.
