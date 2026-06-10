---
description: Manage the Pokémon pet (toggle, random, pick one, status)
---

Manage the Pokémon pet overlay by running the bundled CLI:

```
${CLAUDE_PLUGIN_ROOT}/scripts/claude-pokemon-pet <subcommand>
```

Subcommands: `toggle` | `on` | `off` | `random` | `pet <name>` | `sprites` | `status`.

Map the user's request ("$ARGUMENTS") to the right subcommand:
- empty or "toggle" → `toggle`
- "random", "roll", "new pokemon" → `random`
- a pokémon name (e.g. "pikachu", "mew") → `pet <name>`
- "status", "who is my pet" → `status`
- anything else → show usage

Run it with Bash and report the output to the user in one short sentence.
