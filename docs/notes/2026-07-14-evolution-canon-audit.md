# Evolution canon audit (games/anime fidelity)

**Trigger:** user request — "go over all the evolution trees for pokemon
and digimon; should follow the actual games and anime." Edge order became
gameplay-meaningful with the care-tier rule (flawless day → first edge).

## Pokémon — verified game-accurate, zero corrections

Method: fetched every PokeAPI evolution chain (100 chains cover all gen-1
membership), enumerated all root→leaf paths, trimmed to the contiguous
gen-1 (id ≤ 151) run, and diffed the resulting path set against our 81
pack lines programmatically.

Result: **all 81 lines are exact PokeAPI paths; nothing extra, nothing
wrong.** The 5 path-set differences are gen-2+ branch shadows that
correctly have no gen-1 line: `[eevee]` (espeon/umbreon branch),
`[meowth]` (Galarian perrserker branch), `[oddish, gloom]` (bellossom),
`[poliwag, poliwhirl]` (politoed), `[slowpoke]` (slowking). Our three
eevee lines (vaporeon/jolteon/flareon) cover gen-1 exactly.

## Digimon — canonical-first edge ordering

(pending sprite-scout deliverable: anime-canonical champion per rookie,
in-graph feasibility, recommended first-edge order with sources; findings
and applied reorders will be recorded here.)
