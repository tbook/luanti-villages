# Terrain API

`living_villages.terrain` is available after Living Villages loads. It exposes the
small set of terrain helpers used by mods that place their own buildings.

Coordinates use world X/Z columns. Pad `y` is the surface Y. Building footprints
and protected rectangles use inclusive endpoints.

```lua
local terrain = living_villages.terrain
local plan = {{
	name = "my_building",
	pos = {x = 100, y = 12, z = 100}, -- y is the surface Y
	rotat = "0",
	surface_mat = "mcl_core:dirt_with_grass",
}}
local schematics = {{name = "my_building", hwidth = 5, hdepth = 7, hheight = 6}}
local protected = {{x0 = 80, z0 = 80, x1 = 95, z1 = 95, margin = 1}}
local volume, why = living_villages.terrain.volume(plan, schematics, {protected = protected})
if not volume then error(why) end
minetest.emerge_area(volume.minp, volume.maxp, function(_, _, remaining)
	if remaining ~= 0 then return end
	local ok, result = living_villages.terrain.terraform(plan, nil, {
		schematic_table = schematics,
		protected = protected,
	})
	if not ok then minetest.log("warning", result) end
end)
```

Use the actual dimensions of each schematic in `hwidth`, `hdepth`, and
`hheight`. `volume` is a read-only query: it does not inspect map nodes, emerge
blocks, or write terrain. Its returned `minp`/`maxp` are inclusive world node
coordinates, expanded outward to full 16-node mapblocks. Emerge that box before
calling `terraform`; terraform does not emerge terrain itself.

For candidate sites whose surface height is not known yet, omit `pos.y` and pass
the inclusive vertical search interval. After reading the footprint and choosing
its final surface height, query again with the final plan and emerge that box
before terraforming:

```lua
local candidate = {{name = "my_building", pos = {x = 100, z = 100}, rotat = "90"}}
local scan, why = living_villages.terrain.volume(candidate, schematics, {
	surface_y = {min = ground_y - 48, max = ground_y + 48},
	protected = protected,
})
if not scan then error(why) end
-- Emerge scan.minp..scan.maxp, inspect the footprint, then set candidate[1].pos.y.
local final = living_villages.terrain.volume(candidate, schematics, {protected = protected})
-- Emerge final.minp..final.maxp before calling terraform as above.
```

`plan` is a list of settlement-style entries (`pos`, `name`, `rotat`, and
`surface_mat`). The API uses the loaded engine, settlements, and `mcl_vars` globals
to read terrain and clear trees. A custom schematic table does not require a
settlements table; supply `surface_mat` if settlements is unavailable. Advanced
callers may inject an `env` table with `engine`, `settlements`, `load_node`,
`scan`, and `clear_trees`. The API never calls VoxeLibre's original terraform.
It returns `false, reason` when required terrain is unavailable or planning
fails, and `true, stats` on success. It checks the whole smoothing, tree, and hole
area for unloaded mapblocks before writing any terrain.
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
`structure_test`, and `volume` do not read or write the world. `volume(plan,
schematic_table, options)` returns `{minp, maxp}` or `nil, reason`. The schematic
table uses the same `name`, `hwidth`, `hdepth`, and `hheight` fields as terraform.
For entries with a known integer `pos.y`, that surface height is used. If any
entry omits it, `options.surface_y = {min, max}` is required and both inclusive
endpoints are included in the volume. Empty plans, unknown schematics, invalid
dimensions, coordinates, rotations, config ranges, or a missing surface interval
return `nil, reason`; no partial bounds are returned. Pass the same `options.config`
to `volume` and terraform when overriding smoothing settings. `options.protected`
is accepted for call symmetry; protected columns remain inside the envelope because
they still constrain the terrain around them.

For town-edge grading, `boundary_volume(rectangles, ground_y, options)` is a
read-only pre-emerge query over a dense list of inclusive
`{x0, z0, x1, z1}` rectangles. It requires no schematics or settlement plan.
Default radius and cap are both 20 nodes. The later internal planner uses the
same strict Euclidean radius and slope rules as village smoothing. It keeps
interior heights fixed at `ground_y` regardless of map contents and excludes
every interior column from writes. The query's inclusive bounds include the
default +/-48-node ground inspection, tree cleanup's configured horizontal and
40-node vertical reach, and the column fill and plant cleanup reaches. It rounds
outward to whole mapblocks and returns `nil, reason` if input is invalid or the
rounded box crosses the world map limit. It does not read or write the map.

After emerging that volume and waiting for completion, call
`smooth_boundary(rectangles, ground_y, options)` with the same boundary and
options. It reuses the town-boundary planner and existing terrain writer, clears
trees in one batch while protecting every boundary rectangle, and grades only
eligible exterior columns. Radius and movement cap default to 20; columns at the
radius stay fixed, and radius zero makes no changes. Water, ice, nearby shoreline
ground, structures and overhangs are left alone. Interior ground stays a hard
planning constraint at `ground_y`, and no interior node is written. This
operation does not run the hole-filling stage.

`terrain.boundary_structure_protection == 1` advertises support for
`options.structure_boxes`, a dense array of inclusive world-space `{min, max}`
building boxes, and `options.is_protected(pos)`, a node-protection predicate.
When supplied together, boundary smoothing skips tree cleanup and treats tree
and leaf columns as obstacles, since an unrecorded log structure cannot be
distinguished safely from a tree. Grading protects whole columns if any node in
the write volume is protected. Known building columns do not cause an extra
structure buffer, while other structures retain their buffer. Callers that
require these protections must check the capability before invoking the writer
and provide complete boxes.

The function returns `true, stats` or `false, reason`. A false result after
cleanup or column writing can follow partial terrain changes; it does not roll
them back. `stats.changed`, `cut`, and `filled` count graded columns;
`max_movement` is the largest surface-height change, and `steps_over_one` is a
diagnostic. `tree_removed` counts removed tree nodes. `written` is the inclusive
XYZ envelope of nodes actually changed, or nil when none changed. The same
`options.env` injection pattern as `terraform` is available for engine and helper
functions.

Protected rectangles are tables
with inclusive `x0`, `z0`, `x1`, `z1`; optional nonnegative `margin` expands the
rectangle. They remain fixed slope constraints and are excluded from tree cleanup,
smoothing, hole filling, and ramps.
