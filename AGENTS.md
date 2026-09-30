# Agent guide

Living Villages (`living_villages`) is a Luanti mod that extends the villagers in VoxeLibre
(game id `mineclone2`, version 0.92.3). It wraps VoxeLibre's villager entity definition from
`mobs_mc` rather than replacing it. Trades, professions, and bed-ownership metadata stay in
VoxeLibre's format, so removing the mod leaves a working world.

## Code map

| File | Role |
|------|------|
| `init.lua` | Entry point. Sets the villager model and textures, handles sleeping pose and waking, removes duplicate villagers, and installs the other modules into `mobs_mc:villager` |
| `common.lua` | Shared helpers with no side effects: schedule stages, standing space, bed and jobsite lookups |
| `births.lua` | Bed-limited births. The cooldown is stored in bed metadata |
| `navigation.lua` | Trips to beds, jobsites, and targets. Uses VoxeLibre's pathing first, then falls back to `planner.lua` |
| `planner.lua` | Limited A* search over walkable positions, including stairs and wooden doors |
| `farmer.lua` | Farmer visits to crops near a claimed composter |
| `fisherman.lua` | Water-based fisherman profession, the fishing loop, and the bobber and rod entities |
| `nitwit.lua` | Keeps nitwits from being demoted to unemployed by VoxeLibre's jobsite check |
| `keeper.lua` | Tavern keeper role, which is a butcher underneath and claims a jukebox, plus its menu and hours |
| `tavern.lua` | The evening tavern visit and keeper takeover |
| `seat.lua` | Chair reservation and the sitting pose |
| `meal.lua` | Serving and eating dinner on plates, and the `living_villages:meal` display entity |
| `tavern_schematic.lua` | Furnishes newly generated taverns by editing the stock schematic in memory |
| `diagnostic.lua` | Read-only Lookup Tool inspector for privileged players |
| `village_index.lua` | `/living_villages_goto` testing command and the list of generated villages |
| `tests/*.lua` | Standalone tests, one per module, that stub the engine |
| `docs/navigation-scenarios.md` | Manual in-game test scenarios |

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
