# Milestone Review — Phase 1: Shared Core Refactor (v0.4.0)

**Branch/PR:** `feat/phase1-shared-core` → PR #1 · **Review:** PASS after two fix rounds · **Tests:** 90 assertions, all green

## What was built

Phase 1 of the v2 roadmap: every piece of *game logic* moved out of the macOS
overlay into a new bash+jq core, so the upcoming renderers (terminal for
Linux/SSH, statusline) and franchises (Digimon) plug into one brain instead of
re-implementing it.

```
Claude Code hooks ──events──▶ pet-core.sh ──writes──▶ resolved.json ◀──reads── renderers
(SessionStart, PostToolUse,   (counters, gacha,       (the full contract:      (pet-overlay.js today;
 PostToolUseFailure, Stop…)    evolution, i18n)        species, level, EXP,     terminal + statusline
                                                       localized name/moves)    in Phase 2)
```

## Project structure after Phase 1

| Path | Role |
|---|---|
| `scripts/pet-core.sh` | THE game core: event recording, daily task/mistake/streak counters, gacha, pick, language, resolve |
| `data/pokemon/pack.json` | franchise pack: 81 lines, 151 species (en/ko), move pools, sprite config, gates `[0,6,16]` |
| `scripts/pet-overlay.js` | JXA overlay, now a pure view of `resolved.json` |
| `hooks/hooks.json` | routes 6 hook events into the core |
| `tests/` | zero-dep bash harness; 90 assertions; real captured hook fixtures |
| `scripts/dev/gen-pokemon-pack.sh` | provenance: regenerates the pack from v1 data (in git history) |

## Key concepts (for learning)

- **Event reduction, not polling.** The core is a tiny event-sourcing setup:
  hooks append facts (task done, tool failed), and `resolve` folds facts +
  pack data into one denormalized view file. Renderers never compute — they
  draw. This is the same pattern as a Redux store or a materialized view in a
  database, in 230 lines of bash.
- **The renderer contract is a file.** `resolved.json` is versionless IPC:
  atomic `mktemp`+`mv` writes mean a reader never sees a half-written JSON.
  Any process on the machine (JXA, Python, a tmux statusline) can consume it.
- **Hooks are hostile territory.** A hook runs on *every tool call of every
  session*: it must exit 0, print nothing, and survive missing dependencies —
  a failing hook degrades the user's Claude Code experience, not just the pet.
  Hence the `event) … 2>/dev/null; exit 0` guard and jq-absence early return.
- **Empirical verification beat the plan.** The plan assumed we could sniff
  tool errors from PostToolUse stdin. Reality (probe + docs): PostToolUse
  fires on success only; failures fire `PostToolUseFailure`. Discovering this
  before coding cost one probe project; discovering it after would have cost a
  silent, never-firing feature.

## How the review loop went

Round 1 (NEEDS-FIXES): 3 Important — resolved.json went stale at midnight
(v1 recomputed per tick; the new file only updated on events), the hook path
could exit non-zero without jq, and one test leaked host system language
(this machine is Korean macOS — the suite passed here but asserted nothing).
Plus 2 Minor. Round 2: all fixed, one residual Minor (an unguarded `mkdir`
stderr). Round 3: PASS. Fixes: `date`-stamped resolved.json + re-resolve on
staleness (status subcommand + overlay NSTask kick, ≤1/min), unconditional
exit-0 event path, `PET_LANG` test seam, corrupt-partner self-healing.

## Production practices demonstrated

- TDD per task (red → green → commit), golden-value tests derived from the
  v1 formulas, hermetic test sandboxes with injectable clock/seed/locale.
- Real fixtures over assumed shapes (captured hook payloads).
- Behavior parity as the acceptance bar for a refactor: same evolution gates,
  same gold EXP cycling, byte-identical names/moves data.
- Upgrade path considered: v1 `tasks` file carries over (level survives);
  partner re-rolls once due to the format change.

## Next steps

- **Phase 2** (next): pure-stdlib Python terminal renderer (kitty/iTerm2
  graphics, ANSI fallback) + statusline script — ships Linux/RunPod support.
- **Phase 3 prerequisite** to start in parallel: research a reliable Digimon
  V-pet sprite source (flagged feasibility gate in the spec).
- Awaiting user sign-off on this milestone before starting Phase 2.
