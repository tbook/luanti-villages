-- Run with: lua tests/cells.lua
-- The passability model (#161): what a villager may stand on, in and move through.
local world = {}
local function key(x, y, z) return x .. ":" .. y .. ":" .. z end
local function put(x, y, z, name) world[key(x, y, z)] = name end
local function box(top) return {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, top, 0.5}} end
local defs = {
	air = {walkable = false},
	["mcl_core:stone"] = {walkable = true},
	["mcl_core:grass_path"] = {walkable = true, drawtype = "nodebox", node_box = box(0.4375)},
	["mcl_nether:soul_sand"] = {walkable = true, drawtype = "nodebox", node_box = box(0.375)},
	["mcl_stairs:slab_wood"] = {walkable = true, drawtype = "nodebox", node_box = box(0)},
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
	["mcl_doors:wooden_door_b_1"] = {door = 1}, ["mcl_doors:iron_door_b_1"] = {door = 1, door_iron = 1},
}
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
assert(not stand_on("mcl_stairs:slab_wood"), "a bottom slab is not")
assert(not stand_on("mcl_nether:soul_sand"), "soul sand (0.375) is left out: no village has it")
assert(not stand_on("mcl_fences:fence"), "a fence is not")
assert(not stand_on("mcl_core:lava_source"), "a hazard is not")
assert(not stand_on("air"), "nor is nothing")

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
