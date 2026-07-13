# PostToolUse payload verification (care-mistake detection)

**Date:** 2026-07-13 · **Verified on:** Claude Code current release, macOS
**Method:** docs research (hooks reference) + empirical capture via a probe
project with dump hooks (`tests/fixtures/` holds the real captured payloads).

## Findings

1. **PostToolUse fires ONLY on successful tool calls.** Confirmed twice
   empirically: a Bash `exit 7` and a failed `Read` produced no PostToolUse
   event. The docs say the same ("runs immediately after a tool completes
   successfully").
2. **`PostToolUseFailure` is the dedicated failure event.** It fires for tool
   calls that throw or return failure (a non-zero Bash exit included). Its
   stdin JSON has **no `tool_response`**; failure is signaled by top-level
   fields:
   - `error` (string, e.g. `"Exit code 7"`)
   - `is_interrupt` (bool; **absent** for ordinary failures, `true` when the
     user interrupted the call)
3. Bash's PostToolUse `tool_response` is `{stdout, stderr, interrupted,
   isImage, …}` — no exit code, no error flag. Error sniffing via PostToolUse
   is impossible; the original plan's `MISTAKE_FILTER` hypothesis is dead.

## Decision (supersedes the plan's Task 3 stdin-sniffing design)

- `hooks/hooks.json` registers **`PostToolUseFailure` → `pet-core.sh event
  mistake`** alongside the existing `PostToolUse` → `event working`.
- `event mistake`: counts a daily care mistake **unless** the payload has
  `is_interrupt == true` (a user pressing Esc is not the pet's fault), and
  writes state `working` (a failing tool call is still activity).
- `event working` does not inspect stdin at all.
- Filter: `(.is_interrupt // false) | not` → count.
- On Claude Code versions predating `PostToolUseFailure` the hook simply
  never fires: mistakes stay 0, which degrades exactly to the spec's
  documented fallback (no HP-bar movement; Digimon branching falls back to
  the always-qualifying edge conditions).

## Fixtures (real captures)

- `tests/fixtures/posttooluse-ok.json` — successful Bash call.
- `tests/fixtures/posttoolusefailure-error.json` — Bash `exit 7`.
- `tests/fixtures/posttoolusefailure-interrupt.json` — same payload with
  `is_interrupt: true` (synthesized from the documented field; the only
  synthetic fixture).
