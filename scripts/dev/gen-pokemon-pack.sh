#!/bin/bash
# Dev-time only: regenerates data/pokemon/pack.json from the v1 data files
# (data/chains.json, data/gen1.txt, data/lang-ko.json). Kept for provenance;
# the v1 files were deleted in v0.4.0 — restore them from git history first:
#   git show v0.3.3:data/chains.json > data/chains.json   (etc.)
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p data/pokemon

ids=$(awk '{printf "{\"key\":\"%s\",\"value\":%s}\n", $2, $1}' data/gen1.txt | jq -s 'from_entries')

jq -n --argjson ids "$ids" \
      --slurpfile chains data/chains.json \
      --slurpfile ko data/lang-ko.json '
  ($chains[0]) as $c | ($ko[0]) as $k |
  {
    franchise: "pokemon",
    gates: [0, 6, 16],
    sprites: {
      base_url: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-v/black-white/animated",
      target_px: 190
    },
    lines: $c,
    species: ($ids | to_entries | map({
        key: .key,
        value: { id: .value,
                 names: { en: (.key | ascii_upcase),
                          ko: ($k.names[.key] // null) } }
      }) | from_entries),
    moves: {
      normal:   ["TACKLE", "BODY SLAM", "HYPER BEAM"],
      fire:     ["EMBER", "FLAMETHROWER", "FIRE BLAST"],
      water:    ["WATER GUN", "SURF", "HYDRO PUMP"],
      grass:    ["VINE WHIP", "RAZOR LEAF", "SOLAR BEAM"],
      electric: ["THUNDER SHOCK", "THUNDERBOLT", "THUNDER"],
      psychic:  ["CONFUSION", "PSYBEAM", "PSYCHIC"],
      fighting: ["KARATE CHOP", "SEISMIC TOSS", "SUBMISSION"],
      rock:     ["ROCK THROW", "ROCK SLIDE", "EARTHQUAKE"],
      ground:   ["DIG", "BONE CLUB", "EARTHQUAKE"],
      poison:   ["POISON STING", "ACID", "SLUDGE"],
      bug:      ["LEECH LIFE", "PIN MISSILE", "TWINEEDLE"],
      flying:   ["GUST", "WING ATTACK", "DRILL PECK"],
      ghost:    ["LICK", "NIGHT SHADE", "DREAM EATER"],
      ice:      ["AURORA BEAM", "ICE BEAM", "BLIZZARD"],
      dragon:   ["DRAGON RAGE", "SLAM", "HYPER BEAM"]
    },
    moves_ko: $k.moves
  }' > data/pokemon/pack.json
echo "wrote data/pokemon/pack.json ($(jq '.species | length' data/pokemon/pack.json) species)"
