-- One answer to "can a villager stand here, and can it move from here to there"
-- (#161). Before this there were three: core.find_path's one-block walker,
-- navigation.lua's planner checks and common.lua's wander checks, and they
-- disagreed. This module classifies a cell from the real node definitions, for
-- mobs_mc/villager.lua's body (collisionbox 0.6 wide, 1.95 tall); no side effects.
--
-- The planner (through navigation.lua), wander.lua, seat.lua and church.lua reach
-- it through common.lua, and fisherman.lua and diagnostic.lua call it directly.
local core = minetest

local cells = {}

-- mobs_mc/villager.lua's collisionbox: {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}.
local HALF_WIDTH = 0.3
local HEIGHT_NODES = 2
local EDGE = 0.001
-- The lowest floor top, in node units from the node's center, a villager walks
-- on as a floor. A bottom slab tops out at 0.0 and is not one. A grass path,
-- farmland and soul sand top out a sixteenth or two short of a full node
-- (0.4375): the villager's feet just sit lower and the engine walks it on and
-- off without a jump. Asking for 0.49 made every village road a hole in the
-- map, and cut the tavern off from the rest of the village (#156).
local MIN_FLOOR_TOP = 0.4
-- Nodes a villager never stands on, though they are walkable: do_jump
-- (mcl_mobs/movement.lua) will not jump a fence, gate or wall, and a trapdoor is
-- no floor.
local NOT_FLOORS = {"fence", "fence_gate", "wall", "trapdoor"}

cells.HALF_WIDTH = HALF_WIDTH
cells.HEIGHT_NODES = HEIGHT_NODES

local function round(value)
	return math.floor(value + 0.5)
end

-- The highest point of a node's collision, from its center (-0.5 is the bottom).
-- A nodebox with no collision box of its own collides as its node box (Luanti
-- does this): a carpet is a sixteenth of a node thick, not a block.
function cells.collision_box_top(def)
	local box = def and (def.collision_box or (def.drawtype == "nodebox" and def.node_box))
	if not box or box.type ~= "fixed" then return 0.5 end
	local fixed = box.fixed
	if type(fixed) ~= "table" then return -0.5 end
	if type(fixed[1]) == "number" then return fixed[5] or -0.5 end
	local top = -0.5
	for _, part in ipairs(fixed) do
		if type(part) == "table" and type(part[5]) == "number" then top = math.max(top, part[5]) end
	end
	return top
end

function cells.is_hazard(name, def)
	if (def.damage_per_second or 0) > 0 then return true end
	return core.get_item_group(name, "fire") > 0
		or core.get_item_group(name, "cactus") > 0
		or core.get_item_group(name, "dangerous") > 0
end

-- A node the villager's body may pass through: not something it collides with,
-- and not something that hurts it. Openness alone is not enough -- fire is not
-- walkable, carries no collision box and is not a liquid, so a check that only
-- asks whether a villager fits would happily place one in a fire.
--
-- `options.thin`: a carpet counts as clear. It is a walkable sliver a villager
-- stands on top of, and the church floor (#126) is laid with it; carpet at head
-- height still blocks, so pass this for the feet cell only.
-- `options.door`: a wooden door counts as clear, since the planner and the mover
-- open it. An iron door never does.
function cells.is_open(pos, options)
	local node = core.get_node_or_nil(pos)
	local def = node and core.registered_nodes[node.name]
	if not node then return false end
	if options and options.thin and core.get_item_group(node.name, "carpet") > 0 then return true end
	if core.get_item_group(node.name, "door") > 0 then
		return options and options.door and core.get_item_group(node.name, "door_iron") == 0 or false
	end
	if not def then return false end
	if def.walkable or (def.collision_box and def.collision_box.type ~= "none") then return false end
	if def.liquidtype and def.liquidtype ~= "none" then return false end
	return not cells.is_hazard(node.name, def)
end

-- Whether the node under `pos` is a floor a villager standing in `pos` rests on.
function cells.has_floor(pos)
	local node = core.get_node_or_nil({x = pos.x, y = pos.y - 1, z = pos.z})
	local def = node and core.registered_nodes[node.name]
	if not def or not def.walkable then return false end
	-- A villager's feet rest on the top of the supporting node.
	if cells.collision_box_top(def) < MIN_FLOOR_TOP then return false end
	for _, group in ipairs(NOT_FLOORS) do
		if core.get_item_group(node.name, group) > 0 then return false end
	end
	return not cells.is_hazard(node.name, def)
end

-- The planner's walk position: `pos` is the cell the feet are in, which may be
-- a carpet; the head cell must be open, and a wooden door is passable in either.
function cells.can_stand(pos)
	return cells.is_open(pos, {door = true, thin = true})
		and cells.is_open({x = pos.x, y = pos.y + 1, z = pos.z}, {door = true})
		and cells.has_floor(pos)
end

-- Whether a villager can step from the cell `from` to the adjacent cell `to`,
-- both already known to be standable. Only a rise needs more: it is a jump, which
-- swings the head through the column one above the current head, at
-- `from.y + 2`, a cell `can_stand(to)` never looks at. So a low roof over the
-- villager's own side keeps it from jumping even when the taller neighboring room
-- is open (#56).
function cells.can_move(from, to)
	if to.y <= from.y then return true end
	return cells.is_open({x = from.x, y = from.y + 2, z = from.z}, {door = true})
end

-- Whether every node the standing box at `pos` touches, from layer `bottom` to
-- `top`, is open. A box is 0.6 wide, so it can reach a neighbouring column.
function cells.box_is_open(pos, bottom, top, thin)
	-- Shrink the span by a hair so a box whose edge lands exactly on a node
	-- boundary is not treated as reaching into the node beyond it. Villagers
	-- stand on half-node offsets constantly, so without this the check
	-- rejects a node the villager only touches -- most often the bed it is
	-- climbing out of, since a bed is walkable.
	local options = thin and {thin = true} or nil
	for x = round(pos.x - HALF_WIDTH + EDGE), round(pos.x + HALF_WIDTH - EDGE) do
		for z = round(pos.z - HALF_WIDTH + EDGE), round(pos.z + HALF_WIDTH - EDGE) do
			for y = bottom, top do
				if not cells.is_open({x = x, y = y, z = z}, options) then return false end
			end
		end
	end
	return true
end

-- Whether a villager's whole body fits at a continuous position `pos`, over a
-- floor under its center column (standing with part of the box over an edge is
-- ordinary). With `thin`, carpet in the villager's own cell does not count
-- against it.
function cells.has_standing_space(pos, thin)
	local feet = round(pos.y)
	return cells.box_is_open(pos, feet, feet, thin)
		and cells.box_is_open(pos, feet + 1, feet + HEIGHT_NODES - 1)
		and cells.has_floor({x = round(pos.x), y = feet, z = round(pos.z)})
end

-- What the classifier says about a walk position, for the Lookup Tool.
function cells.describe(pos)
	local function name_at(at)
		local node = core.get_node_or_nil(at)
		return node and node.name or "unloaded"
	end
	local head = {x = pos.x, y = pos.y + 1, z = pos.z}
	local below = {x = pos.x, y = pos.y - 1, z = pos.z}
	local parts = {}
	table.insert(parts, "feet " .. name_at(pos) .. (cells.is_open(pos, {door = true, thin = true}) and " (open)" or " (blocked)"))
	table.insert(parts, "head " .. name_at(head) .. (cells.is_open(head, {door = true}) and " (open)" or " (blocked)"))
	table.insert(parts, "floor " .. name_at(below) .. (cells.has_floor(pos) and " (supports)" or " (no support)"))
	return table.concat(parts, "; "), cells.can_stand(pos)
end

return cells
