# CLAUDE.md — claude-pokemon-pet

A Claude Code plugin: floating Pokémon pet that reacts to session hooks.
v2 roadmap: `docs/superpowers/specs/2026-07-13-v2-roadmap-design.md`.

## Architecture (v0.4.0+)

**Hooks write events → `scripts/pet-core.sh` (bash+jq) reduces them to
`~/.cache/claude-pokemon-pet/resolved.json` → renderers are pure views.**
Never put game logic (leveling, evolution, gacha, i18n data) in a renderer;
never make the core depend on a renderer. Franchise data lives in JSON packs
(`data/<franchise>/pack.json`).

## Hard rules

- **bash 3.2** (macOS `/bin/bash`): no `mapfile`, `${var,,}`, associative arrays.
- **Hook path is sacred**: `pet-core.sh event *` must always exit 0 and stay
  silent, whatever the state of PATH or the cache. Anything before the `case`
  dispatch runs unguarded — keep it silent too (`2>/dev/null`).
- Zero new runtime deps for the core (jq + gifsicle only). Terminal renderer
  (Phase 2) may use pure-stdlib Python 3.
- Runtime writes go only to `~/.cache/claude-pokemon-pet/`; never the plugin dir.
- BSD/GNU date portability: `date -v-1d +%F 2>/dev/null || date -d yesterday +%F`.
- Conventional commits, colon separator.

## Testing

- `bash tests/run.sh` — zero-dep harness, must pass before every commit.
- Tests are hermetic: throwaway `$HOME`, and env seams `PET_TODAY`,
  `PET_YESTERDAY`, `PET_NOW`, `PET_SEED`, `PET_LANG`. Never let a test touch
  the real cache or depend on host locale — **this dev machine is Korean
  macOS**; anything reading system language will return `ko`.
- Real hook payload fixtures live in `tests/fixtures/` (captured via a probe
  project, see `docs/notes/2026-07-13-posttooluse-payload.md`).
- Manual overlay QA: toggle the *installed* plugin off first
  (`~/.claude/plugins/marketplaces/claude-pokemon-pet/scripts/claude-pokemon-pet off`),
  launch the dev overlay (`nohup osascript -l JavaScript scripts/pet-overlay.js "$PWD" &`),
  verify, kill it, toggle the installed one back `on`.

## Code review

- Reviewer: `code-reviewer` agent (model: sonnet), on the branch diff.
- Checklist: bash-3.2 compat; behavior parity vs v1 formulas; hook-path
  exit-0/silence; atomic writes (mktemp+mv) for JSON state; RESOLVE_JQ math
  vs golden tests; test hermeticity; stale refs after file moves.
- Loop until PASS; fix ALL findings including Minor.

## Lessons learned (Phase 1)

- **`PostToolUse` fires only on successful tool calls.** Failures fire
  `PostToolUseFailure` (top-level `error` + `is_interrupt`, no
  `tool_response`). Verify hook payloads empirically with a dump-hook probe
  before designing around them.
- **`resolved.json` is event-driven, so it goes stale at midnight.** It
  carries a `date` stamp; `status` re-resolves when stale and the overlay
  NSTask-kicks `pet-core.sh resolve` (≤1/min) on a stale stamp. Any new
  renderer must do the same stale check.
- pgrep/pkill on `pet-overlay.js` hits the *installed* plugin's overlay too —
  mind the running instance when testing locally.
- **`extend_line` invariant** (Phase 3): digimon evolution choices are
  recorded in the partner file at the gate crossing and never re-evaluated.
  The seeded pick indexes into pack edge order — `gen-digimon-pack.sh` must
  preserve curation-file edge order (jq `group_by` is stable; don't replace it
  with something that isn't).
- **Hooks run concurrently** (`"async": true`): any read-modify-write of
  cache state needs the mkdir-lock pattern (`clear_stale_lock` + `mkdir`,
  wall-clock staleness — never `PET_NOW`). Counter bumps use a bounded-wait
  lock (losing an increment is data loss); `extend_line` uses skip-on-busy
  (the next event catches up). Reviews of Phase 3 found BOTH races live —
  assume any new mutation has this bug until proven otherwise. Known accepted
  residual: timeout-based stale reclamation can, in a sub-ms window, rmdir a
  fresh lock if a live owner held one >10s (pathological); fencing tokens are
  disproportionate here. Measured worst-case hook latency under a held
  counter lock: ~2.7s (bounded, inside the 5s hook timeout).

## Phase status

1. ✅ Shared core refactor (PR #1)
2. ✅ Terminal renderer + statusline (Linux/SSH/RunPod)
3. ✅ Digimon pack + V-pet branching
4. ⬜ Shinies, dex command, HUD, battle FX, evo cinematics
5. ⬜ Trainer card
