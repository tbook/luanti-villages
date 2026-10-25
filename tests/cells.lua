-- Run with: lua tests/cells.lua
-- The passability model (#161): what a villager may stand on, in and move through.
local world = {}
local function key(x, y, z) return x .. ":" .. y .. ":" .. z end
local function put(x, y, z, name) world[key(x, y, z)] = name end
local function box(top) return {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, top, 0.5}} end
local defs = {
	air = {walkable = false},
	["mcl_core:stone"] = {walkable = true},
	["mcl_core:cobble"] = {walkable = true},
	["mcl_core:mossycobble"] = {walkable = true},
	["mcl_core:sandstonesmooth2"] = {walkable = true},
	["mcl_core:grass_path"] = {walkable = true, drawtype = "nodebox", node_box = box(0.4375)},
	["mcl_stairs:stair_cobble"] = {
		walkable = true, drawtype = "nodebox", collision_box = {type = "fixed", fixed = {
			{-0.5, -0.5, -0.5, 0.5, 0, 0.5}, {-0.5, 0, 0, 0.5, 0.5, 0.5},
		}},
	},
	["mcl_stairs:slab_cobble"] = {walkable = true, drawtype = "nodebox", node_box = box(0)},
	["mcl_nether:soul_sand"] = {walkable = true, drawtype = "nodebox", node_box = box(0.375)},
	["mcl_stairs:slab_wood"] = {walkable = true, drawtype = "nodebox", node_box = box(0)},
	["mcl_stairs:slab_wood_top"] = {walkable = true, drawtype = "nodebox", node_box = {type = "fixed", fixed = {-0.5, 0, -0.5, 0.5, 0.5, 0.5}}},
	["mcl_fences:fence"] = {walkable = true, collision_box = box(1.0)},
	["mcl_wool:carpet"] = {walkable = true, drawtype = "nodebox", node_box = box(-0.4375)},
	["mcl_fire:fire"] = {walkable = false},
	["mcl_core:water_source"] = {walkable = false, liquidtype = "source"},
	["mcl_core:lava_source"] = {walkable = true, damage_per_second = 8},
	["mcl_doors:wooden_door_b_1"] = {walkable = true},
	["mcl_doors:iron_door_b_1"] = {walkable = true},
}
local groups = {
	["mcl_fences:fence"] = {fence = 1}, ["mcl_wool:carpet"] = {carpet = 1}, ["mcl_fire:fire"] = {fire = 1},
	["mcl_stairs:slab_wood"] = {slab = 1}, ["mcl_stairs:slab_wood_top"] = {slab = 1, slab_top = 1},
	["mcl_stairs:slab_cobble"] = {slab = 1},
	["mcl_doors:wooden_door_b_1"] = {door = 1}, ["mcl_doors:iron_door_b_1"] = {door = 1, door_iron = 1},
}
-- mcl_decor/src/paths.lua generates these nodes from tpl_path: the visible
-- cobbles are uneven, but the collision box is one sixteenth high over a floor.
local decor_path_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.4375, 0.5}}
local decor_path_node_box = {type = "fixed", fixed = {
	{-0.4375, -0.5, -0.4375, -0.125, -0.4375, -0.125},
	{-0.125, -0.5, -0.0625, 0.0625, -0.4375, 0.125},
	{-0.3125, -0.5, 0.1875, -0.0625, -0.4375, 0.4375},
	{0.0625, -0.5, -0.375, 0.25, -0.4375, -0.1875},
	{0.125, -0.5, 0.125, 0.375, -0.4375, 0.375},
	{0.25, -0.5, -0.125, 0.375, -0.4375, 0},
	{-0.4375, -0.5, 0, -0.3125, -0.4375, 0.125},
}}
local decor_paths = {"gravel", "cobble", "stone", "granite", "andesite", "diorite",
	"netherrack", "deepslate", "deepslate_cobbled", "tuff"}
for _, material in ipairs(decor_paths) do
	local name = "mcl_decor:path_" .. material
	defs[name] = {
		walkable = true, drawtype = "nodebox", node_box = decor_path_node_box,
		collision_box = decor_path_box,
	}
	groups[name] = {path = 1}
end
defs["test:thick_path"] = {
	walkable = true, collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.1, 0.5}},
}
groups["test:thick_path"] = {path = 1}
defs["test:danger_path"] = {walkable = true, collision_box = decor_path_box, damage_per_second = 1}
groups["test:danger_path"] = {path = 1}
minetest = {
	registered_nodes = defs,
	get_modpath = function() return "." end,
	get_node_or_nil = function(pos) return {name = world[key(pos.x, pos.y, pos.z)] or "air"} end,
	get_item_group = function(name, group) return (groups[name] or {})[group] or 0 end,
}
local cells = dofile("cells.lua")
local function stand_on(floor) world = {}; put(0, 0, 0, floor); return cells.can_stand({x = 0, y = 1, z = 0}) end

assert(stand_on("mcl_core:stone"), "a full block is floor")
-- The tavern's route went nowhere because a grass path was not floor (#156).
assert(stand_on("mcl_core:grass_path"), "a grass path is floor")
assert(stand_on("mcl_stairs:slab_wood"), "a bottom slab is a floor")
assert(stand_on("mcl_stairs:slab_wood_top"), "the top of an upper slab is a floor")
assert(not stand_on("mcl_nether:soul_sand"), "soul sand (0.375) is left out: no village has it")
assert(not stand_on("mcl_fences:fence"), "a fence is not")
assert(not stand_on("mcl_core:lava_source"), "a hazard is not")
assert(not stand_on("air"), "nor is nothing")

-- A mcl_decor path overlays the feet cell and stands on the full block below.
world = {}; put(0, 0, 0, "mcl_core:stone"); put(0, 1, 0, "mcl_decor:path_cobble")
assert(cells.can_stand({x = 0, y = 1, z = 0}), "path overlay is clear at the feet and supported below")
local path_standing = cells.standing_position({x = 0, y = 1, z = 0})
assert(math.abs(path_standing.y - 0.5725) < 1e-9, "stands on the path collision top: " .. path_standing.y)
assert(not cells.is_open({x = 0, y = 1, z = 0}, {door = true}), "path at head height blocks")
put(0, 1, 0, "test:thick_path")
assert(not cells.is_open({x = 0, y = 1, z = 0}, {thin = true}), "a thick path-group node is not transparent")
put(0, 1, 0, "test:danger_path")
assert(not cells.is_open({x = 0, y = 1, z = 0}, {thin = true}), "a hazardous path-group node still blocks")
put(0, 1, 0, "mcl_decor:path_cobble")
put(0, 0, 0, "air")
assert(not cells.can_stand({x = 0, y = 1, z = 0}), "an unsupported path is not a floor")

-- A carpet uses a sixteenth-high nodebox too, and the standing position rises
-- to its top just as it does for the paths above.
put(0, 0, 0, "mcl_core:stone"); put(0, 1, 0, "mcl_wool:carpet")
local carpet_standing = cells.standing_position({x = 0, y = 1, z = 0})
assert(math.abs(carpet_standing.y - 0.5725) < 1e-9, "stands on carpet's actual top: " .. carpet_standing.y)

-- A lower slab beside full-block ground is a half-step, not an obstacle to a
-- route through the row. The planner should use the slab directly rather than
-- detouring around it.
local planner = dofile("planner.lua")
world = {}
for x = -1, 3 do for z = -1, 1 do put(x, 0, z, "mcl_core:stone") end end
put(1, 0, 0, "mcl_stairs:slab_wood")
local slab_path = planner.find_path({x = 0, y = 1, z = 0}, cells.can_stand,
	function(pos) return pos.x == 2 and pos.y == 1 and pos.z == 0 end, {range = 8})
assert(slab_path, "route across lower slab exists")
local crossed_slab = false
for _, pos in ipairs(slab_path) do
	if pos.x == 1 and pos.y == 1 and pos.z == 0 then crossed_slab = true end
end
assert(crossed_slab, "route crosses the lower slab instead of detouring")

-- Carpets already count as thin floor covers in the shared passability model;
-- keep that behavior at route level as well as in the cell checks below.
world = {}
for x = -1, 3 do for z = -1, 1 do put(x, 0, z, "mcl_core:stone") end end
put(1, 1, 0, "mcl_wool:carpet")
local carpet_path = planner.find_path({x = 0, y = 1, z = 0}, cells.can_stand,
	function(pos) return pos.x == 2 and pos.y == 1 and pos.z == 0 end, {range = 8})
assert(carpet_path, "route across carpet exists")
local crossed_carpet = false
for _, pos in ipairs(carpet_path) do
	if pos.x == 1 and pos.y == 1 and pos.z == 0 then crossed_carpet = true end
end
assert(crossed_carpet, "route crosses carpet instead of detouring")

-- Full-block road materials and cobble stairs/slabs remain traversable through
-- the planner too (VoxeLibre mcl_stairs definitions).
for _, floor in ipairs({
	"mcl_core:cobble", "mcl_core:mossycobble", "mcl_core:sandstonesmooth2",
	"mcl_stairs:stair_cobble", "mcl_stairs:slab_cobble",
}) do
	world = {}
	for x = -1, 3 do for z = -1, 1 do put(x, 0, z, "mcl_core:stone") end end
	put(1, 0, 0, floor)
	local path = planner.find_path({x = 0, y = 1, z = 0}, cells.can_stand,
		function(pos) return pos.x == 2 and pos.y == 1 and pos.z == 0 end, {range = 8})
	assert(path, "route exists across " .. floor)
	local crossed = false
	for _, pos in ipairs(path) do
		if pos.x == 1 and pos.y == 1 and pos.z == 0 then crossed = true end
	end
	assert(crossed, "route crosses " .. floor .. " instead of detouring")
end

-- Each mcl_decor path variant is a thin overlay in the feet cell, not a floor
-- node one cell below it. Check real template collision geometry on solid ground.
for _, material in ipairs(decor_paths) do
	local name = "mcl_decor:path_" .. material
	world = {}
	for x = -1, 3 do for z = -1, 1 do put(x, 0, z, "mcl_core:stone") end end
	put(1, 1, 0, name)
	local path = planner.find_path({x = 0, y = 1, z = 0}, cells.can_stand,
		function(pos) return pos.x == 2 and pos.y == 1 and pos.z == 0 end, {range = 8})
	assert(path, "route exists across " .. name)
	local crossed = false
	for _, pos in ipairs(path) do
		if pos.x == 1 and pos.y == 1 and pos.z == 0 then crossed = true end
	end
	assert(crossed, "route crosses " .. name .. " instead of detouring")
end

-- Normal ground, a path overlay, carpet and a lower slab are all one connected
-- route at their real support cells.
world = {}
for x = -1, 5 do for z = -1, 1 do put(x, 0, z, "mcl_core:stone") end end
put(1, 1, 0, "mcl_decor:path_cobble")
put(2, 1, 0, "mcl_wool:carpet")
put(3, 0, 0, "mcl_stairs:slab_wood")
local cover_path = planner.find_path({x = 0, y = 1, z = 0}, cells.can_stand,
	function(pos) return pos.x == 4 and pos.y == 1 and pos.z == 0 end, {range = 8})
assert(cover_path, "route exists across ground, path, carpet and slab")
local crossed_cells = {}
for _, pos in ipairs(cover_path) do crossed_cells[pos.x] = true end
assert(crossed_cells[1] and crossed_cells[2] and crossed_cells[3], "route crosses all three floor transitions")

-- The feet cell may hold carpet, the head may not.
world = {}; put(0, 0, 0, "mcl_core:stone"); put(0, 1, 0, "mcl_wool:carpet")
assert(cells.can_stand({x = 0, y = 1, z = 0}), "feet in carpet")
put(0, 1, 0, "air"); put(0, 2, 0, "mcl_wool:carpet")
assert(not cells.can_stand({x = 0, y = 1, z = 0}), "carpet at head height blocks")

-- A wooden door is passable, an iron one not, fire and water never.
world = {}; put(0, 0, 0, "mcl_core:stone")
put(0, 1, 0, "mcl_doors:wooden_door_b_1")
assert(cells.can_stand({x = 0, y = 1, z = 0}), "wooden door")
assert(not cells.is_open({x = 0, y = 1, z = 0}), "a door is not open unless asked")
put(0, 1, 0, "mcl_doors:iron_door_b_1")
assert(not cells.can_stand({x = 0, y = 1, z = 0}), "iron door")
put(0, 1, 0, "mcl_fire:fire")
assert(not cells.can_stand({x = 0, y = 1, z = 0}), "fire")
put(0, 1, 0, "mcl_core:water_source")
assert(not cells.can_stand({x = 0, y = 1, z = 0}), "water")

-- A rise needs the cell above the departure head.
world = {}
put(0, 0, 0, "mcl_core:stone"); put(1, 1, 0, "mcl_core:stone")
local from, to = {x = 0, y = 1, z = 0}, {x = 1, y = 2, z = 0}
assert(cells.can_move(from, to), "open above")
put(0, 3, 0, "mcl_core:stone")
assert(not cells.can_move(from, to), "a low roof stops the jump")
assert(cells.can_move(to, from), "a drop needs no headroom")

-- The standing box reaches into the next column when the villager is off center.
world = {}; put(0, 0, 0, "mcl_core:stone"); put(1, 1, 0, "mcl_core:stone")
assert(cells.has_standing_space({x = 0, y = 1, z = 0}), "centered")
assert(not cells.has_standing_space({x = 0.45, y = 1, z = 0}), "box reaches into the wall")

-- Head room over a bed top (#191): the bed's collision tops out at 0.0625 over
-- its node's centre, so a villager on it has its head 0.0125 into a top-half
-- slab two nodes up; a full node over the feet cell blocks it as well.
defs["mcl_beds:bed_red_bottom"] = {walkable = true, collision_box = box(0.06)}
defs["mcl_stairs:slab_wood_top"] = {
	walkable = true, drawtype = "nodebox", node_box = {type = "fixed", fixed = {-0.5, 0, -0.5, 0.5, 0.5, 0.5}},
}
world = {}
put(0, 0, 0, "mcl_core:stone"); put(0, 1, 0, "mcl_beds:bed_red_bottom")
local on_bed = {x = 0, y = 1.0725, z = 0}
assert(cells.has_head_room(on_bed), "open air over a bed")
put(0, 3, 0, "mcl_stairs:slab_wood_top")
assert(not cells.has_head_room(on_bed), "a top slab two nodes above the bed is in the villager's head")
put(2, 0, 0, "mcl_core:stone"); put(2, 3, 0, "mcl_stairs:slab_wood_top")
assert(cells.has_head_room({x = 2, y = 0.51, z = 0}), "the same ceiling clears a villager on the floor")
put(0, 3, 0, "air"); put(0, 4, 0, "mcl_stairs:slab_wood_top")
assert(cells.has_head_room(on_bed), "a ceiling one node higher is clear")
put(0, 3, 0, "mcl_core:stone")
assert(not cells.has_head_room(on_bed), "a full node above blocks")
put(0, 3, 0, "air")
-- Off centre, the box reaches into the next column.
put(1, 3, 0, "mcl_stairs:slab_wood_top"); put(0, 4, 0, "air")
assert(not cells.has_head_room({x = 0.3, y = 1.0725, z = 0}), "the box reaches under the neighbouring ceiling")
assert(cells.has_head_room({x = 0.1, y = 1.0725, z = 0}), "but not from the middle of the cell")

-- Where an entity stands in a cell: on the floor, or on the carpet in the cell.
world = {}
put(5, 0, 5, "mcl_core:stone")
local at = cells.standing_position({x = 5, y = 1, z = 5})
assert(at.x == 5 and at.z == 5 and math.abs(at.y - 0.51) < 1e-9, "on the floor's top: " .. at.y)
put(5, 1, 5, "mcl_wool:carpet")
at = cells.standing_position({x = 5, y = 1, z = 5})
assert(math.abs(at.y - 0.5725) < 1e-9, "on the carpet's top: " .. at.y)

print("cells.lua: ok")
