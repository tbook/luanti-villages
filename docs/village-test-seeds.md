# Village test seeds

Fixed world seeds and village sites for the village terrain work (#133: #139, #140, #141, #142,
and #12 for paths). Each case is a seed and a chunk, with what it exercises and the numbers vanilla
VoxeLibre produces there, so a PR can quote before and after on the same terrain.

The numbers come from `tools/lv_probe/` (see its [README](../tools/lv_probe/README.md) for what each
column means and how to run it). They are vanilla: `living_villages` was not loaded.

- Luanti 5.17.0, VoxeLibre (`mineclone2`) 0.92.3
- Mapgen `v7`, default flags, chunksize 5. The probe sets nothing else about the mapgen

## Using a case

Run the probe, which needs no player and touches no real world:

```sh
tools/lv_probe/run_cases.sh               # all cases, vanilla; about four minutes
tools/lv_probe/run_cases.sh --with-mod    # the same with living_villages from this checkout
tools/lv_probe/run.sh 2026 --chunk -1072,1488 --with-mod   # one case
```

Or look at one in the game: create a world with game VoxeLibre, mapgen `v7` and the seed in the
table, and teleport to the center (`/teleport x y z`). The village builds when its chunk
generates, as in any world. Its layout can differ a little from the probe's, which generates the
surroundings first in a fixed order (see Repeatability).

To find more sites, `/living_villages_goto new` teleports above the next predicted village chunk
(`blockseed % 77 == 17`, in `village_index.lua`), and `tools/lv_probe/survey.sh` lists them in bulk.

## Cases

Chunk is the chunk's minimum x and z. Center is the belltower's position.

| Case | Seed | Chunk | Center | Biome | Why |
|------|------|-------|--------|-------|-----|
| cliff | 2026 | -1072, 1488 | -1033, 56, 1527 | Savanna | Floors 89 blocks apart: houses at the top and the foot of a cliff. The complaint behind #133. The floor of one building is 84 blocks above the natural ground under it, another is 92 below it |
| hillside | 2014 | 1248, 1088 | 1287, 44, 1127 | Plains | Treeless slope, floors spread over 60 blocks. The floor of one building is 58 blocks above the natural ground under it. A pillager outpost stands 20 nodes from the nearest house |
| tower | 2002 | 368, 1328 | 407, 2, 1367 | Plains_beach | The floor of one building is 54 blocks above the natural ground under it, so it stands on a tall column. The most trapped columns in the set |
| mountain-edge | 2007 | 208, 768 | 247, 7, 807 | Savanna | The houses are on level ground (floors within 9) but the area includes a mountain 103 blocks high: sheer walls beside buildings, and a building cut 82 blocks into the slope |
| pit | 2025 | 1808, 1328 | 1847, 8, 1367 | JungleEdge | A pit 44 blocks deep in the village area, 20 nodes from the belltower: a ravine or cave mouth |
| forest | 2004 | -1632, -352 | -1593, 15, -313 | RoofedForest | Dense forest: 86% of columns under leaves and about 12,500 trunk nodes. Its layout can differ by a house between runs |
| jungle | 2010 | -2112, -752 | -2073, 13, -713 | Jungle | Large canopies: 94% of columns under leaves and about 11,000 trunk nodes |
| portal | 2024 | 2288, -512 | 2327, 16, -473 | SavannaM | A ruined portal centered inside a house footprint, and a pond 3 nodes away |
| portal-outpost | 2014 | -1712, -1632 | -1673, 4, -1593 | Desert | A ruined portal and a pillager outpost, each centered 1 node from a house. Sand surface |
| outpost | 2018 | 608, 1728 | 647, 11, 1767 | Savanna | A pillager outpost centered 2 nodes from a house |
| flat | 2022 | -832, -1872 | -793, 2, -1833 | Swampland | Control. 21 buildings with a church and a tavern, on ground that varies by 14 over the whole area. Nothing should get worse here |
| flat-small | 2023 | -1152, 528 | -1113, 14, 567 | Savanna | Control. Level grassland, 13 buildings, no tavern. The fastest case |
| snow-flat | 2005 | -1392, -832 | -1353, 7, -793 | ColdTaiga | Snow surface (`mcl_core:snow`, so `place_schematics` swaps in spruce wood) on level ground |
| snow-steep | 2006 | -512, -2192 | -473, 11, -2153 | IcePlains | Snow surface under slopes 132 blocks high, with the floors only 10 apart |
| desert | 2002 | 128, 928 | 167, 11, 967 | Desert | Sand surface, with a church and a tavern |
| mesa | 2017 | -912, -1712 | -873, 4, -1673 | MesaPlateauF_sandlevel | Red sand surface on a mesa |

A "ruined portal" or "outpost" case means the structure's center is within 2 nodes of a house
footprint (the `structures` column in the probe's report shows the distance). Nothing in vanilla
keeps them apart, and #141 is about that.

## Vanilla baseline

One probe run per case: `tools/lv_probe/run_cases.sh`. The columns are described in the probe
README. Terrain, Pit, Fill, Cut, Canopy and Trunks are measured before any building edit; Step,
Steps>1, Traps and Orphans after the build. `ms` is the time in the four generator steps.

| Case | Bldg | C/T | Floors | Nbr | Terrain | Pit | Fill | Cut | Canopy | Trunks | Step | Steps>1 | Traps | Orphans | ms |
|------|------|-----|--------|-----|---------|-----|------|-----|--------|--------|------|---------|-------|---------|-----|
| cliff | 20 | CT | 89 | 88 | 96 | 43 | 84 | 92 | 3% | 78 | 84 | 1374 | 0 | 6 | 336 |
| hillside | 20 | -T | 60 | 48 | 111 | 25 | 58 | 17 | 0% | 0 | 77 | 1172 | 0 | 0 | 334 |
| tower | 18 | -T | 55 | 54 | 79 | 20 | 54 | 30 | 0% | 0 | 58 | 1416 | 246 | 0 | 350 |
| mountain-edge | 18 | -T | 9 | 8 | 103 | 16 | 2 | 82 | 4% | 86 | 83 | 250 | 63 | 50 | 228 |
| pit | 14 | C- | 5 | 3 | 55 | 44 | 2 | 9 | 16% | 473 | 44 | 114 | 10 | 51 | 171 |
| forest | 23 | CT | 14 | 11 | 30 | 21 | 29 | 8 | 86% | 12571 | 17 | 326 | 40 | 95 | 327 |
| jungle | 14 | CT | 7 | 3 | 36 | 6 | 1 | 20 | 94% | 10940 | 20 | 836 | 7 | 114 | 276 |
| portal | 22 | CT | 10 | 7 | 39 | 6 | 9 | 10 | 8% | 208 | 14 | 405 | 16 | 36 | 324 |
| portal-outpost | 13 | -T | 6 | 4 | 58 | 21 | 4 | 32 | 0% | 64 | 35 | 655 | 26 | 0 | 190 |
| outpost | 18 | -T | 13 | 13 | 31 | 1 | 19 | 15 | 3% | 97 | 20 | 307 | 3 | 59 | 469 |
| flat | 21 | CT | 8 | 7 | 14 | 0 | 1 | 4 | 24% | 356 | 3 | 8 | 5 | 64 | 299 |
| flat-small | 13 | -- | 7 | 5 | 8 | 1 | 3 | 1 | 4% | 97 | 1 | 0 | 0 | 6 | 108 |
| snow-flat | 13 | -T | 4 | 3 | 7 | 0 | 3 | 0 | 41% | 675 | 2 | 2 | 0 | 102 | 125 |
| snow-steep | 20 | CT | 10 | 10 | 132 | 16 | 19 | 93 | 0% | 30 | 80 | 958 | 6 | 0 | 246 |
| desert | 21 | CT | 19 | 10 | 40 | 1 | 4 | 4 | 1% | 31 | 12 | 134 | 0 | 0 | 284 |
| mesa | 21 | -T | 11 | 5 | 22 | 9 | 8 | 3 | 0% | 0 | 9 | 20 | 9 | 0 | 266 |

Orphans are leaves with no trunk within 6 nodes, counted only after the build, so it includes any
that generation left unsupported. Compare the count before and after a change, not against zero.
Traps count columns.

### With living_villages (#155)

The same cases with `run_cases.sh --with-mod`, before and after the hole and cliff filling of #155
(`origin/main` at 62ec0be against that branch). Step, Steps>1 and Traps after the build, as above.
Terrain, Pit and the rest do not change. The probe is not exactly repeatable: Traps moved by a few
columns between identical runs of the tree-heavy and snow cases (snow-flat 2 to 4 on main, 0 to 6 with
the change), and Orphans and Steps>1 by about 10%.

| Case | Step | Steps>1 | Traps |
|------|------|---------|-------|
| cliff | 84 / 84 | 2463 / 2451 | 5 / 5 |
| hillside | 82 / 79 | 2044 / 2005 | 0 / 0 |
| tower | 23 / 23 | 1770 / 1764 | 72 / 72 |
| mountain-edge | 83 / 83 | 259 / 250 | 2 / 2 |
| pit | 9 / 9 | 78 / 60 | 0 / 0 |
| forest | 23 / 23 | 647 / 637 | 61 / 61 |
| jungle | 20 / 20 | 637 / 564 | 0 / 0 |
| portal | 14 / 22 | 335 / 332 | 0 / 0 |
| portal-outpost | 36 / 35 | 464 / 467 | 9 / 9 |
| outpost | 20 / 20 | 460 / 455 | 27 / 27 |
| flat | 9 / 9 | 138 / 138 | 7 / 7 |
| flat-small | 12 / 12 | 122 / 122 | 0 / 0 |
| snow-flat | 17 / 18 | 1054 / 750 | 2 / 0 |
| snow-steep | 80 / 80 | 1361 / 1078 | 72 / 72 |
| desert | 8 / 8 | 325 / 315 | 38 / 38 |
| mesa | 12 / 12 | 107 / 97 | 0 / 0 |

### Overhang slabs in the metrics (#219)

Since #219 the probe measures a column under an overhang slab (the mod's `is_overhang`: a solid
run at most 6 thick over at least 4 air) at the ground under it, when that ground continues the
terrain around it (see the probe README). The two tables above are **raw**: the slab top counted
as ground. Below, each cell is `raw / corrected` from the same run, so one world gives both. They
are single runs after the change, on `origin/main` at 9cb8f75 (the layout can differ from the
tables above by a house, and the mod-run column differs from the #155 table for that reason).

| Case | Vanilla Step | Steps>1 | Traps | With mod Step | Steps>1 | Traps |
|------|--------------|---------|-------|---------------|---------|-------|
| cliff | 84 / 84 | 1374 / 1249 | 0 / 0 | 84 / 85 | 2407 / 2271 | 5 / 5 |
| hillside | 77 / 78 | 1172 / 1148 | 0 / 0 | 80 / 80 | 1886 / 1908 | 0 / 0 |
| tower | 58 / 58 | 1416 / 1406 | 246 / 246 | 23 / 23 | 1769 / 1769 | 72 / 72 |
| mountain-edge | 83 / 85 | 250 / 228 | 63 / 63 | 83 / 83 | 272 / 238 | 17 / 17 |
| pit | 44 / 44 | 114 / 114 | 10 / 10 | 9 / 9 | 18 / 18 | 5 / 5 |
| forest | 17 / 17 | 208 / 207 | 40 / 42 | 14 / 14 | 436 / 437 | 5 / 8 |
| jungle | 20 / 15 | 780 / 628 | 7 / 14 | 20 / 13 | 478 / 137 | 0 / 0 |
| portal | 14 / 17 | 406 / 381 | 16 / 16 | 22 / 22 | 352 / 348 | 0 / 0 |
| portal-outpost | 35 / 34 | 655 / 666 | 26 / 35 | 35 / 35 | 467 / 470 | 9 / 9 |
| outpost | 20 / 20 | 307 / 324 | 3 / 10 | 20 / 20 | 489 / 504 | 1 / 5 |
| flat | 3 / 3 | 8 / 8 | 5 / 5 | 10 / 17 | 140 / 142 | 7 / 7 |
| flat-small | 1 / 1 | 0 / 0 | 0 / 0 | 12 / 12 | 122 / 124 | 0 / 0 |
| snow-flat | 2 / 2 | 2 / 2 | 0 / 0 | 13 / 13 | 93 / 93 | 0 / 0 |
| snow-steep | 80 / 81 | 958 / 883 | 6 / 7 | 80 / 81 | 1078 / 997 | 72 / 72 |
| desert | 12 / 12 | 134 / 133 | 0 / 0 | 8 / 8 | 315 / 316 | 38 / 38 |
| mesa | 9 / 10 | 20 / 22 | 9 / 10 | 12 / 14 | 99 / 103 | 0 / 0 |
| Testlandia (seed 18442661806533097198, chunk -912, 2448) | | | | 56 / 53 | 1239 / 1201 | 2 / 4 |

The correction is small almost everywhere and not always downward: a column is lowered only when
the ground under its slab is nearer the surrounding ground than the slab top is, so a cave roof
at village level stays ground, and a bed under water is never ground. The remaining odd cells are
single columns, for example `flat` with mod, where one lowered column turns a step of 10 into 17.
The jungle case moved most (steps>1 478 to 137): its canopy-height ledges. `overhang_columns`,
`overhang_lowered` and `overhang_unknown` in `natural` and `after` count the slab columns.

### Village yield

The sites VoxeLibre tried on seeds 2001 to 2030, 14 per seed, nearest the origin within 2400
nodes (`tools/lv_probe/survey.sh 2001 2030`). #139 quotes its yield against this.

| | Vanilla | #139 planner |
|-|---------|--------------|
| sites tried | 309 | 309 |
| built | 265 (85.8%) | 281 (90.9%) |
| plan failed | 39 (no surface at the center) | 23 (17 no belltower site within 32 blocks of the center, 6 fewer than 8 building sites) |
| rejected as too uneven (`max_height_difference` 56) | 5 | 5 |
| buildings per built village | 16 | 17.6 |
| with a church | 43.8% | 97.2% |
| with a tavern | 88.3% | 90.4% |
| floor range, median | 8 | 8 |
| neighbor floor difference, median | 6 | 5 |
| largest step between columns, median | 18 | 20 |
| villages with at least one trapped column | 66.4% | 73.7% |

The #139 column uses `max_spread` 4 (3 gave 72.8% built, before the belltower could move off a failed center site). The church share for vanilla is plain VoxeLibre; #132 changed it for villages built with `living_villages`.

## Repeatability

Terrain and village centers are fixed by the seed. Everything that depends on trees is not
exactly repeatable, even with the probe's fixed generation order, a fixed `math.random` seed and
one emerge thread: the tree and leaf counts move by about 1% between runs, `Steps>1` by one or
two, and `Orphans` by about 10%.

The layout, meaning the building list and the floor heights, was identical across four runs for
all cases but `forest`, which differed by a house and its heights in one of four. `hillside` was
run twice, `flat` three times, the others four. Treat differences in the tree columns below those
amounts as noise. For `forest`, run it a few times, or lean on the other cases.

A PR's numbers should come from the same procedure on both sides: `run_cases.sh` without and with
the change. With `--with-mod` the layouts differ from vanilla anyway, since `living_villages` places
churches first (#132), so compare the terrain columns, not the building list.

## Not covered

- A village in a seed with a cave mouth that is not a pit: the `pit` case is a deep hole by the
  probe's measure, not a confirmed cave opening.
- Trapped columns and orphaned leaves use provisional definitions (see the probe README). If #141 or
  #142 sharpens them, change `tools/lv_probe/mod/lv_probe/metrics.lua` and redo this table in the
  same PR.
- Paths (#12) are not measured.
