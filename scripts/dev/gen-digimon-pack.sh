#!/bin/bash
# Dev-time only: regenerates data/digimon/pack.json from data/digimon/curation.json
# (fetch-verified Wikimon V-pet data, 2026-07-13). Edge order within a species
# must stay in curation-file order — the seeded evolution pick indexes into it.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

jq '
  def disp: {"metalgreymon_virus": "METALGREYMON", "extyranomon": "EX-TYRANOMON",
             "darktyranomon": "DARK TYRANOMON"}[.] // ascii_upcase;
  def kdisp: if . == "메탈그레이몬(바이러스종)" then "메탈그레이몬" else . end;
  . as $c |
  {
    franchise: "digimon",
    gates: [0, 2, 5, 10, 18],
    moves_by: "species",
    mistake_threshold: 3,
    sprites: { format: "png", keying: "floodfill", target_px: 180 },
    lines: [ $c.versions[] | {
      version: .version, type: "vpet",
      mons: [ .stages[0].members[0] ],
      members: [ .stages[].members[] ]
    } ],
    species: ([ $c.versions[].stages[].members[] ] | unique | map({
      key: .,
      value: { names: { en: disp, ko: (($c.korean[.] // null) | if . then kdisp else . end) },
               attack: ($c.attacks[.] // { en: "Attack", ko: null }),
               sprite_url: $c.art[.] }
    }) | from_entries),
    edges: ([ $c.versions[].edges[] ]
      | map({from: .from, to: .to, quality: .quality})
      | group_by(.from)
      | map({ key: .[0].from, value: map({to: .to, quality: .quality}) })
      | from_entries),
    moves: { "1": ["BUBBLE"], "2": ["ACID BUBBLE"],
             "3": ["SPIT SHOT", "SCRATCH", "HEADBUTT"],
             "4": ["HEAVY SHOT", "FIERCE BITE", "POWER SLAM"],
             "5": ["GIGA BLAST", "FINAL STRIKE", "FULL POWER SHOT"] },
    moves_ko: { "BUBBLE": "거품 공격", "ACID BUBBLE": "산성 거품", "SPIT SHOT": "발사 공격",
                "SCRATCH": "할퀴기", "HEADBUTT": "박치기", "HEAVY SHOT": "강력 발사",
                "FIERCE BITE": "물어뜯기", "POWER SLAM": "몸통 부딪히기",
                "GIGA BLAST": "기가 블래스트", "FINAL STRIKE": "필살 일격",
                "FULL POWER SHOT": "전력 발사" }
  }' data/digimon/curation.json > data/digimon/pack.json
echo "wrote data/digimon/pack.json ($(jq '.species | length' data/digimon/pack.json) species)"
