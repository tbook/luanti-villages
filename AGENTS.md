# Agent guide

Living Villages (`living_villages`) is a Luanti mod that extends the villagers in VoxeLibre
(game id `mineclone2`, version 0.92.3). It wraps VoxeLibre's villager entity definition from
`mobs_mc` rather than replacing it. Trades, professions, and bed-ownership metadata stay in
VoxeLibre's format, so removing the mod leaves a working world with one exception: the
pulpit is the mod's only node. Placed pulpits become unknown nodes and clerics who used one as
their jobsite lose it, so vanilla demotes them.

## Code map

| File | Role |
|------|------|
| `init.lua` | Entry point. Sets the villager model and textures, handles sleeping pose and waking, removes duplicate villagers, and installs the other modules into `mobs_mc:villager` |
| `common.lua` | Shared helpers with no side effects: schedule stages, standing space, bed and jobsite lookups |
| `births.lua` | Bed-limited births. The cooldown is stored in bed metadata |
| `navigation.lua` | Trips to beds, jobsites, and targets. Uses VoxeLibre's pathing first, then falls back to `planner.lua` |
| `step.lua` | Lets a villager on a planned route jump a full step topped with carpet, which vanilla's `do_jump` reads as a two-block stack |
| `planner.lua` | Limited A* search over walkable positions, including stairs and wooden doors |
| `doors.lua` | Which edge of its cell a door's leaf lies on, and which entries and exits of the cell that leaves free |
| `farmer.lua` | Farmer visits to crops near a claimed composter |
| `fisherman.lua` | Water-based fisherman profession, the fishing loop, and the bobber and rod entities |
| `nitwit.lua` | Keeps nitwits from being demoted to unemployed by VoxeLibre's jobsite check |
| `keeper.lua` | Tavern keeper role, which is a butcher underneath and claims a jukebox, plus its menu and hours |
| `music.lua` | On holidays the keeper on duty plays the jukebox's disc from dinner to close |
| `tavern.lua` | The evening tavern visit and keeper takeover |
| `wander.lua` | Replaces vanilla's aimless walk with short, checked straight legs that stop short of walls |
| `seat.lua` | Chair reservation and the sitting pose, for dinner tables and church pews |
| `meal.lua` | Serving and eating dinner on plates, and the `living_villages:meal` display entity |
| `tavern_schematic.lua` | Furnishes newly generated taverns by editing the stock schematic in memory |
| `cleric.lua` | Clerics claim free pulpits through the same node metadata vanilla uses and work there |
| `pulpit.lua` | The `living_villages:pulpit` node, a lectern clone that is no profession's jobsite |
| `church.lua` | The holiday church service: villagers take pews or stand at the back, and the cleric stands at the pulpit |
| `bell.lua` | The holiday bell gathering: villagers walk to the village bell and drift about it in anchored `wander.lua` legs |
| `church_site.lua` | Makes the church the first building a new village places, so most villages have one |
| `church_schematic.lua` | Furnishes newly generated churches with a pulpit and chairs, by editing the stock schematic in memory |
| `paths.lua` | Natural paths (#12): counts villager steps per grass block, turns heavily walked ones into `mcl_core:grass_path`, and reverts faded ones. The thresholds are settings, still to be tuned on real villages |
| `floor_guard.lua` | Undoes Luanti 5.17's collision snapping a villager through its floor after a long server step |
| `diagnostic.lua` | Read-only Lookup Tool inspector for privileged players |
| `village_terrain.lua` | Shared pieces for the village terrain work (#133): village area, one-pass height lookup, emerge-first, column writes, and the installer that replaces `mcl_villages` generator steps. The `living_villages_smooth_villages` setting turns it off |
| `site_planner.lua` | Replaces `settlements.create_site_plan` with a planner that approves only level sites (#139): footprint spread, neighbor floor difference, no water, rounded-up average floor, at least 8 buildings, church reserved first. Also the `/living_villages_plan` dry run. Install it after `church_site.lua` |
| `village_fragments.lua` | Fragment cleanup (#141): `scan_structures` finds foreign structures (non-ground-content, non-natural nodes) in one VoxelManip pass for `site_planner.lua` to avoid, and `clear_trees` removes whole trees (flood fill, capped) for the #140 terraform replacement to call before smoothing |
| `village_smoothing.lua` | Replaces `settlements.terraform` (#140): loads the area synchronously, clears trees via `village_fragments.lua`, then smooths ground around pads (footprint plus yard) with a blended, slope-limited, capped target height. The planning half (`targets`) is pure. Falls back to vanilla terraform if the area won't load |
| `village_index.lua` | `/living_villages_goto` testing command and the list of generated villages |
| `tests/*.lua` | Standalone tests, one per module, that stub the engine. `tests/fixtures/` holds data extracted from VoxeLibre, such as the stock church |
| `tests/stock_buildings.lua` | Reachability test (#159): every stock village building, at four rotations with doors shut and open, must let a villager in to each bed, jobsite and jukebox and out from each room, by `navigation.lua`'s real `gopath` with the engine's pathfinder stubbed out. `tests/support/stock_world.lua` builds the stub map from `tests/fixtures/buildings/`; `tests/support/stock_buildings_known.lua` lists the cases that fail today, with reasons, and a fix removes its entry |
| `docs/navigation-scenarios.md` | Manual in-game test scenarios |
| `docs/village-test-seeds.md` | Test seeds for the village terrain work (#133): seed, chunk, what each exercises, and the vanilla baseline numbers |
| `tools/extract_schematics/` | Regenerates `tests/fixtures/buildings/` (the stock schematics and the definitions of the nodes in them) from the installed VoxeLibre in a headless server. Rerun it when the supported VoxeLibre version changes. Not loaded by the mod |
| `tools/lv_probe/` | Headless village probe: generates a seed's villages on a throwaway world and measures them. Not loaded by the mod. See its README |

## Testing

```sh
for t in tests/*.lua; do lua5.1 "$t"; done   # CI uses Lua 5.1; any newer lua also runs them
```

Each test file stubs the parts of `minetest`/`core` that it needs and `dofile`s the module under
test. Add or extend the matching test when you change behavior. CI
(`.github/workflows/lua-tests.yml`) runs a syntax check on every `*.lua` file and then runs
every test.

## Conventions

- Target the Lua 5.1 / LuaJIT language level. Indent with tabs. Each file starts with
  `local core = minetest`.
- Load modules with `dofile(core.get_modpath("living_villages") .. "/x.lua")`. Entity
  registrations, including those in `fisherman.lua` and `meal.lua`, have to run during the mod's
  normal load, not inside `register_on_mods_loaded`. This is because `register_entity` checks
  the current mod name.
- Registered names such as entities, formspecs, and LBMs, along with media file names, use the
  `living_villages` prefix. Log lines start with `[living_villages]`.
- **Don't rename saved state.** The `_villages_*` fields on villager entities and the
  `villages_last_birth` bed metadata key are saved in players' worlds. They kept their old names
  when the mod was renamed, and renaming them now would silently reset those villagers.
- Header comments explain why a module exists and refer to GitHub issues as `#NN`. Keep
  comments about as dense as the code around them.
- Work out visual constants such as poses, offsets, and attachment points from the model and
  asset data (`models/living_villages_villager.b3d`). Don't find them by trial and error.
- The keeper depends on VoxeLibre's `get_activity` global. If an upstream change removes it,
  the mod logs a warning and villagers fall back to the default schedule. Handle that case
  whenever you touch the schedule.
- Read VoxeLibre's own source (`mods/ENTITIES/mobs_mc/villager.lua`, `mcl_mobs`) before
  changing any behavior this mod wraps.

## Git

Work on feature branches named `feature/<issue>-<slug>` and merge into `main` with PRs.
