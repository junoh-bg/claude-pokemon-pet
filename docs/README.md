# docs/

How this repo's documentation is organized. Every phase of the v2 roadmap
went through: approved spec → implementation plan → TDD build → review loop
to PASS → milestone report → merged PR.

| Folder | What lives there |
|---|---|
| [`superpowers/specs/`](superpowers/specs/) | Approved designs. [`2026-07-13-v2-roadmap-design.md`](superpowers/specs/2026-07-13-v2-roadmap-design.md) is the master spec for the v2 expansion (architecture, all five phases, decision log). |
| [`superpowers/plans/`](superpowers/plans/) | Per-phase implementation plans (bite-sized TDD tasks with exact code): phase 1 shared core, phase 2 terminal renderer, phase 3 digimon, phase 4 UI upgrades, phase 5 trainer card. |
| [`milestones/`](milestones/) | Post-phase review reports — what was built, key concepts explained, what the review loops caught. Written for learning, not just record-keeping. |
| [`notes/`](notes/) | Verified technical findings, e.g. [`2026-07-13-posttooluse-payload.md`](notes/2026-07-13-posttooluse-payload.md) — empirical hook-payload verification that redirected the care-mistake design. |

Start with the master spec, then the milestone reports in order — together
they tell the whole story. `CLAUDE.md` (repo root) holds the working
conventions and hard-won invariants (hook-path rules, lock patterns,
renderer purity).
