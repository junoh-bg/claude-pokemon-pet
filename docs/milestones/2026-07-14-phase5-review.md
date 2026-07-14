# Milestone Review — Phase 5: Trainer Card + Docs Overhaul (v0.8.0)

**Branch/PR:** `feat/phase5-trainer-card` · the final phase of the original
v2 roadmap.

## What was built

- **`claude-pokemon-pet card`** — a shareable trainer card. Always: an SVG
  (bash heredoc, zero new dependencies, sprite embedded as a base64 data
  URI, type-colored accent bar, fully localized en/ko label sets) plus an
  ANSI card inline. When a rasterizer works: `card.png` via a
  success-based cascade (`rsvg-convert` → ImageMagick → macOS Quick Look).
- **Docs overhaul** — README restructured around both franchises (features
  rewritten, dex/card section, per-mode requirements incl. optional
  rasterizers), a `docs/README.md` index tying specs → plans → milestones →
  notes into one narrative, CLAUDE.md brought current.

## Design notes (for learning)

- **The ANSI card has no right border on purpose.** `printf %-24s` counts
  bytes, not display columns — double-width Hangul makes every "closed box"
  ragged. A left-rail card sidesteps the entire wide-character alignment
  problem instead of half-solving it.
- **Escape what you interpolate.** `$USER` is just an env var; one `&`
  breaks XML well-formedness and — because rasterizers reject malformed
  SVG — silently kills the PNG too. A 3-line `xml_escape` closes the whole
  class.
- **Availability is not success.** The first cascade checked `command -v`
  and stopped; a present-but-failing tool produced silence while a working
  fallback sat one branch away. The shipped cascade falls through on
  *failure* and says so on stderr when everything failed.
- **Test your fallbacks against reality.** The "obvious" fix for Quick
  Look's square padding (a top-anchored `sips` crop) was tried live and
  *beheaded the card* — Quick Look's placement isn't predictable. Shipped
  resolution: honest stderr note + README caveat, per the reviewer's
  alternative clause.

## Review loop

Two rounds. Round 1 (2 Important, 3 Minor): unescaped `$USER` breaking SVG
well-formedness (and thereby the PNG, silently); an availability-based
rasterizer cascade that never fell through on actual conversion failure;
Quick Look's square padding undocumented; stale README synopsis; and a
sprite-embed assertion that passed with zero image bytes. Round 2 verified
every fix adversarially (escape ordering can't double-escape; the stub GIF
round-trips through a real decoder; forced-failure shadowing proved the
cascade is genuinely failure-triggered) — PASS.

## Roadmap status

All five original phases shipped. Post-roadmap queue: digimon colorful-art
re-source + full EN/KO localization (user feedback; data curated and
verified), dual-franchise `displayName` branding (identity decision:
keep the `claude-pokemon-pet` ID), rebuilt demo page.
