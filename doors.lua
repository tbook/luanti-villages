-- Where a VoxeLibre door's leaf lies, and which crossings of its cell that
-- leaves free (#121). A door's leaf is a thin slab on one edge of its node, so
-- a villager can walk through the cell only if the leaf is on neither the edge
-- they enter by nor the one they leave by. Whether that holds depends on the
-- door's state and on the turn the route makes inside the cell, not just on
-- "open" and "closed". No engine calls: callers pass nodes and definitions in.
local doors = {}

local SIDES = {
	n = {x = 0, z = -1}, s = {x = 0, z = 1}, e = {x = 1, z = 0}, w = {x = -1, z = 0},
}

-- mcl_doors gives every door variant this box (api_doors.lua), so a stub
-- definition without one still gets the real geometry.
local DEFAULT_BOX = {-8 / 16, -8 / 16, -8 / 16, 8 / 16, 8 / 16, -5 / 16}

-- Luanti's facedir turns a node a quarter at a time so that its -z face ends up
-- facing -dir(param2), where facedir_to_dir(0..3) is +z, +x, -z, -x. That is the
-- rotation stairs use, and the one mcl_doors relies on.
local function rotate(x, z, facedir)
	if facedir == 1 then return z, -x end
	if facedir == 2 then return -x, -z end
	if facedir == 3 then return -z, x end
	return x, z
end

local function first_box(def)
	local box = def and def.node_box
	local fixed = type(box) == "table" and box.fixed
	if type(fixed) ~= "table" then return DEFAULT_BOX end
	if type(fixed[1]) == "number" then return fixed end
	return type(fixed[1]) == "table" and fixed[1] or DEFAULT_BOX
end

-- The edge of its cell a leaf with `def`'s box lies on at `facedir`, as "n",
-- "s", "e" or "w", or nil if the box is not flush with an edge.
function doors.leaf_side(def, facedir)
	local box = first_box(def)
	local x, z = rotate((box[1] + box[4]) / 2, (box[3] + box[6]) / 2, facedir % 4)
	if math.max(math.abs(x), math.abs(z)) < 0.25 then return nil end
	if math.abs(z) >= math.abs(x) then return z < 0 and "n" or "s" end
	return x > 0 and "e" or "w"
end

-- mcl_doors names its variants _b_/_t_ 1 (closed), 2 (open), then 3 and 4 for
-- the mirrored pair. Returns whether the door is open and whether it is mirrored.
function doors.variant(name)
	local number = name and name:match("_[bt]_([1-4])$")
	if not number then return nil end
	number = tonumber(number)
	return number % 2 == 0, number > 2
end

-- Toggling turns param2 a quarter (api_doors.lua on_open_close): forward for a
-- closed door, back for an open one, and the other way round when mirrored.
local function toggled_facedir(facedir, open, mirrored)
	if open == mirrored then return facedir + 1 end
	return facedir - 1
end

-- The leaf's edge now and after a toggle, or nil when the door's geometry is
-- not one this module understands.
function doors.leaf_sides(node, def)
	local open, mirrored = doors.variant(node and node.name)
	if open == nil then return nil end
	local facedir = (node.param2 or 0) % 4
	local current = doors.leaf_side(def, facedir)
	local toggled = doors.leaf_side(def, toggled_facedir(facedir, open, mirrored) % 4)
	if not current or not toggled then return nil end
	return current, toggled, open
end

-- The edges of a door cell that a walker at `other` uses, going by the cell
-- offset between the two. A diagonal neighbor uses both.
function doors.sides_toward(door, other)
	local sides = {}
	local dx, dz = other.x - door.x, other.z - door.z
	if dx > 0 then table.insert(sides, "e") elseif dx < 0 then table.insert(sides, "w") end
	if dz > 0 then table.insert(sides, "s") elseif dz < 0 then table.insert(sides, "n") end
	return sides
end

local function leaves_free(leaf, sides)
	for _, side in ipairs(sides) do
		if side == leaf then return false end
	end
	return true
end

-- What a walker who enters the door's cell by `entry` and leaves by `exit`
-- (lists of edges, see sides_toward) has to do: "keep" the door as it is,
-- "toggle" it, or false when neither state lets them through. nil means the
-- door is not one this module can judge, and the caller should act as vanilla
-- does. An open door is preferred, as vanilla opens every closed door it meets.
function doors.crossing(node, def, entry, exit)
	local current, toggled, open = doors.leaf_sides(node, def)
	if not current then return nil end
	local needed = {}
	for _, side in ipairs(entry) do table.insert(needed, side) end
	for _, side in ipairs(exit) do table.insert(needed, side) end
	local now, later = leaves_free(current, needed), leaves_free(toggled, needed)
	if open then
		if now then return "keep" end
		if later then return "toggle" end
	else
		if later then return "toggle" end
		if now then return "keep" end
	end
	return false
end

return doors
