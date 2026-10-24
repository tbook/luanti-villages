# Terrain API

`living_villages.terrain` is available after Living Villages loads. It exposes the
small set of terrain helpers used by mods that place their own buildings.

Coordinates use world X/Z columns. Pad `y` is the surface Y. Building footprints
and protected rectangles use inclusive endpoints.

```lua
local terrain = living_villages.terrain
local ok, result = terrain.terraform(plan, pr, env, {
	config = config,                 -- optional smoothing settings
	schematic_table = schematics,    -- optional; defaults to settlements' table
	protected = {{x0=0, z0=0, x1=8, z1=8, margin=1}},
})
```

`plan` is a list of settlement-style entries (`pos`, `name`, `rotat`, and
`surface_mat`). `env` supplies `engine`, `settlements.surface_mat`, `load_node`,
`scan`, and `clear_trees`; `settlements` can be supplied for its surface material
table. The API never calls VoxeLibre's original terraform. It returns `false,
reason` when it cannot load or plan the work, and `true, stats` on success.
`stats` contains changed/cut/filled columns, steep steps and walls, tree removals,
hole fills and ramps, unloaded block counts, and `written`, the inclusive
`minp`/`maxp` XYZ bounds of nodes written by tree cleanup, smoothing, and hole
filling (nil if no nodes changed).

`pads(plan, schematic_table, config)` and `targets(pads, height_at, config,
protected)` are pure planning helpers. `pads` returns footprint and yard boxes;
each pad's `y` is the surface Y. `targets` calls `height_at(x,z)` and returns
height lookups and smoothing diagnostics. `structure_test(engine, extra_words)`
returns a predicate that identifies structure node names.

`terraform` writes terrain and clears trees. `pads`, `targets`, and
`structure_test` do not read or write the world. Protected rectangles are tables
with inclusive `x0`, `z0`, `x1`, `z1`; optional nonnegative `margin` expands the
rectangle. They remain fixed slope constraints and are excluded from tree cleanup,
smoothing, hole filling, and ramps.
