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

## Digimon — canonical-first edge ordering (applied)

Independently, the scout's stricter pokémon method (per-species chain
resolution + `/generation/1` filtering) confirmed the same result:
81/81 lines, 151/151 species, 0 corrections.

Champion→ultimate: **no reordering possible or needed** — all 30 champions
have exactly one ultimate edge (verified programmatically).

Rookie tier (flawless-day = first edge), applied via a `canon` priority map
in `gen-digimon-pack.sh` (curation.json stays the untouched wikitext
record). Method: anime partner pairings where in-graph; Wikimon
bold-flagged on-screen evolutions (episode-cited) next; franchise
prominence/citation count last:

| Rookie | First edge | Basis | Changed |
|---|---|---|---|
| agumon | greymon | Tai's partner (Adventure) | no |
| gabumon | **garurumon** | Matt's partner (Adventure) | yes (was kabuterimon) |
| betamon | **seadramon** | on-screen, Adventure 02 ep.14 (Wikimon bold-flag) | yes (was devimon) |
| patamon | unimon | Angemon not in Ver.3 graph; closest holy/Vaccine type | no |
| elecmon | angemon | no pairing; franchise prominence (lower confidence) | no |
| kunemon | **bakemon** | citation tie-break, Adventure "Bakemon army" | yes (was orgemon) |
| piyomon | **leomon** | Birdramon not in Ver.4 graph; most iconic in-graph | yes (was monochromon) |
| palmon | leomon | Togemon not in roster; same reasoning | no |
| gazimon | **devidramon** | highest citation count in-graph | yes (was darktyranomon) |
| gizamon | **deltamon** | highest citations + Adventure-02-era game source | yes (was devidramon) |

Confidence tiers: partner pairings (rock-solid) > episode-cited (betamon)
> canon-adjacent picks (patamon/piyomon/palmon) > prominence-based
(elecmon/kunemon/gazimon/gizamon, medium).
