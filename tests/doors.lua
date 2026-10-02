local doors = dofile("doors.lua")

-- mcl_doors' box: a leaf on the node's -z edge at facedir 0, turned a quarter
-- per param2 so that its -z face ends up facing -facedir_to_dir(param2).
local def = {node_box = {type = "fixed", fixed = {{-8 / 16, -8 / 16, -8 / 16, 8 / 16, 8 / 16, -5 / 16}}}}
assert(doors.leaf_side(def, 0) == "n")
assert(doors.leaf_side(def, 1) == "w")
assert(doors.leaf_side(def, 2) == "s")
assert(doors.leaf_side(def, 3) == "e")
-- A definition without a box (a stub) gets mcl_doors' own.
assert(doors.leaf_side({}, 3) == "e")
-- A box in the middle of the node lies on no edge.
assert(doors.leaf_side({node_box = {type = "fixed", fixed = {-0.2, -0.5, -0.2, 0.2, 0.5, 0.2}}}, 0) == nil)

local open, mirrored = doors.variant("mcl_doors:spruce_door_b_2")
assert(open == true and mirrored == false)
open, mirrored = doors.variant("mcl_doors:spruce_door_t_3")
assert(open == false and mirrored == true)
assert(doors.variant("mcl_doors:spruce_door_b_4") == true)
assert(doors.variant("mcl_core:stone") == nil)

-- A toggle turns the door a quarter: forward when closed, back when open, and
-- the other way round for a mirrored door.
local function sides(name, param2)
	local current, toggled = doors.leaf_sides({name = name, param2 = param2}, def)
	return current .. toggled
end
assert(sides("test:door_b_1", 0) == "nw")
assert(sides("test:door_b_2", 1) == "wn")
assert(sides("test:door_b_3", 0) == "ne")
assert(sides("test:door_b_4", 3) == "en")
assert(doors.leaf_sides({name = "test:stone"}, def) == nil)

-- The door of #121 as found: open (_b_2), param2 3, so its leaf lies along the
-- east edge, and closing it moves the leaf to the south edge, against the wall.
local found = {name = "mcl_doors:spruce_door_b_2", param2 = 3}
local north, east, west, south = {"n"}, {"e"}, {"w"}, {"s"}
assert(doors.leaf_sides(found, def) == "e")
-- In from the north and out to the east is blocked as found, free once closed.
assert(doors.crossing(found, def, north, east) == "toggle")
-- West to east likewise.
assert(doors.crossing(found, def, west, east) == "toggle")
-- North to west only needs the east edge clear, which it is.
assert(doors.crossing(found, def, north, west) == "keep")
-- Nothing gets through a door that leaves no state with the edges free; a
-- diagonal neighbor needs two edges.
assert(doors.crossing(found, def, {"n", "e"}, south) == false)

-- An ordinary door in a wall opens for a straight crossing, as vanilla does,
-- and is left alone once it is open.
local closed = {name = "mcl_doors:wooden_door_b_1", param2 = 0}
assert(doors.crossing(closed, def, north, south) == "toggle")
assert(doors.crossing({name = "mcl_doors:wooden_door_b_2", param2 = 1}, def, north, south) == "keep")
-- A closed door is left shut when opening it would only swing the leaf into the way.
assert(doors.crossing(closed, def, west, east) == "keep")
-- Doors this module cannot judge are left to vanilla.
assert(doors.crossing({name = "mcl_core:stone"}, def, north, south) == nil)

local toward = doors.sides_toward({x = 5, y = 0, z = 5}, {x = 4, y = 0, z = 6})
assert(#toward == 2 and toward[1] == "w" and toward[2] == "s")

print("doors.lua: ok")
