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
| `structures` | ruined portals, outposts and so on placed within 15 nodes of the village area |
| `ms` | milliseconds in `create_site_plan`, `terraform`, `paths`, and until the last schematic was placed. The surroundings are generated beforehand, so this is the generator's own work |

The area is the buildings' bounding box plus 8 nodes on each side, scanned from 96 above the highest floor and raised in steps of 64 while any column is still solid at the top (`clipped_columns` in the result counts what the last scan found). "Ground" is the topmost walkable
node in a column that is not a tree or leaves, so a ruined portal or an outpost counts as ground
(`structures` says when one is near). #141 and #142 may sharpen the definitions of
`traps` and `orphans`; if they do, change `metrics.lua` and the baselines in the catalog together.

`tests/lv_probe_metrics.lua` covers the pure functions in `metrics.lua`.
