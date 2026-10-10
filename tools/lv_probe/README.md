# Village probe

Generates the villages VoxeLibre would try on a world seed, in a headless server on a throwaway
world, and measures them. It exists so the village work in #133 (#139, #140, #141, #142) can be
compared with vanilla on the same terrain. The seeds and their vanilla numbers are in
[`docs/village-test-seeds.md`](../../docs/village-test-seeds.md).

Needs Luanti 5.17 with VoxeLibre (`mineclone2`) in the user's games directory, and `jq` for the
report. The probe is a world mod (`mod/lv_probe/`). It wraps the village steps to measure them and does not
change what they do.

## Run it

```sh
tools/lv_probe/run_cases.sh              # every case in cases.txt on its own fresh world, then the table
tools/lv_probe/run_cases.sh --with-mod   # the same with living_villages from this checkout
tools/lv_probe/run.sh 2026 --chunk -1072,1488   # one village, by seed and chunk
tools/lv_probe/run.sh 2001 --sites 12 --radius 2400   # the 12 sites nearest the origin of a seed
tools/lv_probe/survey.sh 2001 2030       # many seeds at once, then the village yield
tools/lv_probe/report.sh                 # table of everything in results/
tools/lv_probe/yield.sh results/*.jsonl  # what became of the sites that were tried
```

`--with-mod` loads `living_villages` from the checkout the script is in (copied into the throwaway
world, so a worktree measures itself; `--mod-dir PATH` picks another and implies `--with-mod`) and
the mods it depends on from the user mods directory. Without it the run is vanilla VoxeLibre. Each
run claims a free port and uses a scratch directory per checkout, so runs from several worktrees
and a running game do not collide.

For a before-and-after, run `run_cases.sh` on `main` and on the branch (or without and with
`--with-mod`) and compare the two tables. The cases are in `cases.txt`; add one there and in
the catalog together.

Each run builds `$TMPDIR/lv_probe/world_<label>`, starts the server, waits for the probe to stop it,
and copies the result to `tools/lv_probe/results/<label>.jsonl` (git-ignored). The label is the seed,
then `@x_z` with `--chunk`, then `-mod` with `--with-mod`. A run takes up to a few minutes, so start
it in the background. Several can run at once if each gets its own `LV_PROBE_PORT`.

How the probe picks sites: `village_index.lua` predicts the mapchunks that get a village try
(blockseed % 77 == 17). The probe visits the ones nearest the origin, emerges each chunk, and
force-loads its blocks so the `mcl_villages:structblock` LBM builds the village exactly as in
play. A site is only a try: VoxeLibre rejects uneven ground (`outcome: not_built`, `reason:
heightmap too uneven`) and some tries find no surface (`plan_failed`).

Before building, the probe generates the chunk and its 26 neighbors one at a time in a fixed
order, as a player standing in the village would have them. Without that, `find_surface` in `mcl_villages/utils.lua` busy-waits 10 s for each
ungenerated chunk the plan reaches (`mcl_vars.get_node` with `force`, which the emerge thread cannot
finish while the server thread holds the lock). The plan then comes out much smaller and the
timings are multiples of 10 s. VoxeLibre does this in play too whenever a village is built beside
ungenerated terrain. The fixed order, one emerge thread and `math.randomseed(1)` before each site
make runs repeat as closely as they can, but tree counts still vary by about 1% (see Repeatability
in the catalog).

A world made from the menu with the same seed, `mg_name = v7` and the game's default mapgen
settings produces the same terrain and a village at the same chunk, laid out the same up to the
repeatability limits in the catalog. The probe sets
`fixed_map_seed` and `mg_name = v7` and nothing else about the mapgen.

`tools/lv_probe/check_terrain.sh` is a separate, short check for `village_terrain.lua` (#143): on a fresh
world it reads an ungenerated area before and after `village_terrain.emerge`, and expects the first to be
refused and the second to succeed.

## Jobsite census (#217)

```sh
LV_PROBE_CENSUS=300 tools/lv_probe/run.sh 2002 --chunk -832,128 --with-mod
```

`LV_PROBE_CENSUS=SECONDS` (a whole number; needs `--with-mod`, else exit 2) keeps each built village
alive for SECONDS, with villagers treated as having a player near and the time held at a working
morning, then appends a `"type":"census"` line after that village's result line in
`tools/lv_probe/results/<label>.jsonl` (e.g. `2002@-832_128-mod.jsonl`). 300 s lets most villagers
settle. It does not change how villagers choose. `run.sh` raises its give-up limit to
sites x (SECONDS + 120) + 600 when that exceeds 3600 (`LV_PROBE_LIMIT` overrides).

Fields of the line: `seed`, `chunk`, `seconds`; `villagers[]` (villagers with an `_id` inside the
village area: `id`, `profession`, `child`, `jobsite`, `bed`, `pos`, `state`, `order`, `job_route`);
`stations[]` (every workstation node in the area: `name`, `pos`, `claim` and `claimant` (the
claimant's profession), `approach` and `standable`: counts of the cardinal approach cells
`navigation.lua` would use and how many of them a villager can stand in); `timeline[]` (each change of
a villager's profession or jobsite: `t`, `id` (first 6 characters), `what`, `pos`, `bed`). The census
steps every 10 s, so `t` is a multiple of 10.

## Well watch (#11)

```sh
LV_PROBE_CENSUS=300 LV_PROBE_CENSUS_PUTTER=240 tools/lv_probe/run.sh 2001 --chunk -112,-992 --with-mod
```

`LV_PROBE_CENSUS_PUTTER=SECONDS` (with a census) holds the morning Putter stage for the first SECONDS of the
census, then work time, and adds `wells` to the census line (`wells.lua`): the wells `well.lua` found, villagers
that set off for one (`villagers_bound`), arrived and left, `stays` (seconds from first arrival to leaving),
`max_arrived` and `max_near` (most at a well at once), and `rim` (samples of villagers seen above the ground level
within 3.4 nodes of a well's water: on its steps; the walls are closer than 2.2).

## Plant census (#214, #224)

Every result has `natural.plants` and `after.plants` (`plants.lua`): counts over the village area of
`buried_growth` / `buried_plant` (a stalk or plant with a solid block directly over it), `dirt_on_growth`
(soil directly on bamboo, cactus or sugar cane), `floating` (a plant or stalk with air under its base),
`hole_all` / `hole_any` (a base 2 or more below all / any of the four neighbouring ground tops; `hole_any`
also counts natural slopes), `growth`, `plants`, `vines`, `vines_unsupported`, and `samples` (up to 8
positions per count).

## Tree remains census (#232)

Every result has `natural.remains` and `after.remains` (`remains.lua`), over the village area: `cocoa` and
`cocoa_loose` (pods, and those with no trunk on the node they face), `vines` and `vines_loose` (vines that
`mcl_core.check_vines_supported` would drop), `leaves` and `leaves_orphan` (leaves with no trunk within 6 nodes, which
VoxeLibre decays only when a trunk beside them is dug), `orphan_clusters`, `orphan_high` (orphans 4 or more above the
highest solid node under them) and `samples`. Trunks are looked up 6 nodes beyond the area.

## What it reports

One JSON line per site, and `report.sh` prints the main columns.

| Column | Meaning |
|--------|---------|
| `bldg`, `CT` | buildings in the plan; C and T mark a church and a tavern |
| `floor`, `nbr` | spread of building floor heights (`pos.y`), and the largest difference between two buildings whose positions are within 30 nodes |
| `terr`, `pit` | before any edit: height spread over the village area, and the deepest pit (how far a column lies below the lowest of the four columns 4 away). A ravine or cave mouth gives a deep pit |
| `fill`, `cut` | tallest fill and deepest cut between a building floor and the natural ground under it. A village on a tower has a large fill |
| `canopy`, `trunks` | fraction of columns under leaves, and trunk nodes, before any edit |
| `step`, `steps>1` | after the build: largest height difference between adjacent columns outside building footprints, and how many adjacent pairs differ by more than one block |
| `traps` | after the build: columns in a basin a villager cannot climb out of (walk up at most 1 block, down any distance, to the belltower). Water columns are skipped |
| `orphans` | leaf nodes with no trunk within 6 nodes, such as a crown left when a trunk was cleared |
| `census`, `census_dirt`, `dirt_tops`, `surfaces` | (#151) node names in the top 6 nodes of every ground column, before and after; where the dirt sits by depth below the column top, and up to 400 exposed dirt columns; the surface material of each building's pad |
| `structures` | ruined portals, outposts and so on placed within 15 nodes of the village area |
| `ms` | milliseconds in `create_site_plan`, `terraform`, `paths`, and until the last schematic was placed. The surroundings are generated beforehand, so this is the generator's own work |

The area is the buildings' bounding box plus 8 nodes on each side, scanned from 96 above the highest floor and raised in steps of 64 while any column is still solid at the top (`clipped_columns` in the result counts what the last scan found). "Ground" is the topmost walkable
node in a column that is not a tree or leaves, so a ruined portal or an outpost counts as ground
(`structures` says when one is near). #141 and #142 may sharpen the definitions of
`traps` and `orphans`; if they do, change `metrics.lua` and the baselines in the catalog together.

### Overhang slabs (#219)

Since #219 a column whose topmost walkable node is the top of an overhang slab is measured at
the ground under the slab when that is where a villager walks. A slab is the mod's definition
(`village_terrain.is_overhang`, #209): a solid run at most 6 thick with at least 4 air nodes
directly under it. `run.sh` copies `village_terrain.lua` from the checkout it is in into the probe
mod and the probe calls that function, so the two cannot drift apart.

The mod's rule alone also matches the roof of a cave or ledge that villagers do walk on (applied
alone it moved the forest case from 5 to 138 traps), so `metrics.levels` lists the heights a
column might be walked at (the top, then the ground under each slab; a bed under water is not
one) and `metrics.resolve` takes the level nearest the ground of the columns around it (the
median of the columns without a slab within 2, 4, 6 then 10 blocks, at least 3 of them), else
nearest the median building floor. A column that is only a slab over the void has no ground.

The corrected maps feed `steps`, `pit_depth`, `heights`, `traps` and `fill_cut`. The old numbers,
with the slab top as ground, stay beside them so earlier tables remain comparable:
`after.steps_raw`, `after.traps_raw`, `natural.pit_depth_raw`, `natural.heights_raw`,
`natural.fill_cut_raw` (and the same `_raw` fields in `after`), and `report.sh` prints `step_raw`,
`steps>1_raw` and `traps_raw`. `overhang_columns` counts the slab columns, `overhang_lowered` those
that took the ground under the slab and `overhang_unknown` those with no ground under it.
`after.traps.samples` lists up to 8 trapped regions (`x,z n=columns y=corrected/raw` and the node
names down the column) to see what a trap is. Tables before #219 are raw; the catalog gives both.
`census` and `orphans` are not affected.

`after.steps_literal` and `after.traps_literal` apply the mod's rule alone (always the ground under
a slab), to tell how much of a change is the rule and how much `resolve`'s choice. In the catalog
the rule alone makes steps and traps worse nearly everywhere; the choice mostly keeps the slab top
(ledges and cave roofs villagers walk on), so corrected is close to raw except where the top is not
ground at all (jungle: cocoa pods and vine crusts in the canopy). `overhang_how` counts how the
ambiguous columns were decided: by the ground within 2, 4, 6 or 10 blocks, or by the median
building floor when fewer than 3 slab-free columns lay within 10 (`by_ref`; 0 in every catalog case,
natural and after the build), or not at all (`undecided`). `overhang_samples` lists some lowered
columns with the node names down them. A column that is only a slab over the void counts in
`unknown_columns`.

Results written before #219 have none of these fields, so the corrected tables in the catalog
cannot be rebuilt from the tracked `results/*.jsonl`: regenerate them with `run_cases.sh` and
`run_cases.sh --with-mod`.

`tests/lv_probe_metrics.lua` covers the pure functions in `metrics.lua`.
