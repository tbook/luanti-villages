-- Geometry and read-only validation for holiday market stalls (#286).
-- Table node boxes sit in the ground cell; floor-mounted invisible frames sit
-- in the air cell directly above, matching mcl_decor and mcl_itemframes.
local core = minetest
local cells = dofile(core.get_modpath("living_villages") .. "/cells.lua")

local site = {}
local CARDINALS = {
	{x = 1, z = 0},
	{x = -1, z = 0},
	{x = 0, z = 1},
	{x = 0, z = -1},
}
local FLOOR_TOLERANCE = 0.1
local AIR = "air"

local function pos(x, y, z)
	return {x = x, y = y, z = z}
end

local function copy_pos(p)
	return pos(p.x, p.y, p.z)
end

local function same_dir(a, b)
	return a.x == b.x and a.z == b.z
end

-- Pick the horizontal axis pointing from the bell to a pair midpoint. X wins
-- exact diagonal ties, so the result is stable across Lua table iteration.
local function outward_from(bell, midpoint)
	local dx, dz = midpoint.x - bell.x, midpoint.z - bell.z
	if math.abs(dx) >= math.abs(dz) then
		return {x = dx >= 0 and 1 or -1, z = 0}
	end
	return {x = 0, z = dz >= 0 and 1 or -1}
end

local function make_layout(first, outward)
	local right = {x = -outward.z, z = outward.x}
	local second = pos(first.x + right.x, first.y, first.z + right.z)
	local midpoint = {x = (first.x + second.x) / 2, z = (first.z + second.z) / 2}
	local tables = {copy_pos(first), second}
	local frames = {
		pos(first.x, first.y + 1, first.z),
		pos(second.x, second.y + 1, second.z),
	}
	local seller = pos(first.x - outward.x, first.y, first.z - outward.z)
	local clearance = {}
	for side = -1, 2 do
		for distance = -2, 1 do
			table.insert(clearance, pos(
				first.x + right.x * side - outward.x * distance,
				first.y,
				first.z + right.z * side - outward.z * distance))
		end
	end
	return {
		first = copy_pos(first),
		tables = tables,
		frames = frames,
		frame_param2 = core.dir_to_wallmounted({x = 0, y = -1, z = 0}),
		seller = seller,
		outward = outward,
		right = right,
		midpoint = midpoint,
		clearance = clearance,
		exclusive = {
			{pos = copy_pos(tables[1]), height = 2},
			{pos = copy_pos(tables[2]), height = 2},
			{pos = copy_pos(seller), height = 2},
		},
	}
end

-- `first` is the node cell for the first table; the caller may derive it from
-- an actual standing position. Try each cardinal so direction is defined by
-- the finished pair midpoint, including its half-cell offset.
function site.describe(bell, first)
	if not bell or not first then return nil end
	for _, direction in ipairs(CARDINALS) do
		local candidate = make_layout(first, direction)
		if same_dir(outward_from(bell, candidate.midpoint), direction) then
			return candidate
		end
	end
	return nil
end

local function air_at(p)
	local node = core.get_node_or_nil(p)
	return node ~= nil and node.name == AIR
end

local function protected(p, options)
	if options and options.is_protected then return options.is_protected(p) end
	return core.is_protected(p, "")
end

local function boxes_overlap(a_min, a_max, b_min, b_max)
	return a_min.x < b_max.x and a_max.x > b_min.x
		and a_min.y < b_max.y and a_max.y > b_min.y
		and a_min.z < b_max.z and a_max.z > b_min.z
end

local function default_occupied(table_pos)
	if not core.get_objects_inside_radius then return false end
	local min = pos(table_pos.x - 0.5, table_pos.y - 0.5, table_pos.z - 0.5)
	local max = pos(table_pos.x + 0.5, table_pos.y + 0.5, table_pos.z + 0.5)
	for _, object in ipairs(core.get_objects_inside_radius(table_pos, 1)) do
		local player = object.is_player and object:is_player()
		local entity = not player and object.get_luaentity and object:get_luaentity()
		if player or (entity and entity.name == "mobs_mc:villager") then
			local object_pos = object.get_pos and object:get_pos()
			local properties = object.get_properties and object:get_properties()
			local box = properties and properties.collisionbox
			if object_pos and box and boxes_overlap(
				pos(object_pos.x + box[1], object_pos.y + box[2], object_pos.z + box[3]),
				pos(object_pos.x + box[4], object_pos.y + box[5], object_pos.z + box[6]), min, max) then
				return true
			end
		end
	end
	return false
end

local function occupied(p, options)
	if options and options.is_occupied then return options.is_occupied(p) end
	return default_occupied(p)
end

local function valid_layout(layout, options)
	if type(layout) ~= "table" or type(layout.tables) ~= "table" or type(layout.frames) ~= "table"
		or type(layout.clearance) ~= "table" or type(layout.exclusive) ~= "table"
		or #layout.tables ~= 2 or #layout.frames ~= 2
		or #layout.clearance ~= 16 or #layout.exclusive ~= 3 then
		return false, "invalid_layout"
	end

	-- Props may only be placed into untouched air, and protection applies to
	-- every destination before any later placement module acts.
	for _, destinations in ipairs({layout.tables, layout.frames}) do
		for _, destination in ipairs(destinations) do
			if not air_at(destination) then return false, "destination_not_air" end
			if protected(destination, options) then return false, "protected" end
		end
	end
	for _, table_pos in ipairs(layout.tables) do
		if occupied(table_pos, options) then return false, "occupied" end
	end

	local floor_y
	local table_cells = {}
	for _, table_pos in ipairs(layout.tables) do
		table_cells[table_pos.x .. ":" .. table_pos.z] = true
	end
	for _, cell in ipairs(layout.clearance) do
		local ground = {x = cell.x, y = cell.y, z = cell.z}
		if not cells.has_floor(ground) then return false, "unsafe_floor" end
		local standing = cells.standing_position(ground)
		if floor_y and math.abs(standing.y - floor_y) > FLOOR_TOLERANCE then
			return false, "uneven_floor"
		end
		floor_y = floor_y or standing.y
		local key = cell.x .. ":" .. cell.z
		if not table_cells[key] and not cells.can_stand(ground) then
			return false, "blocked_body"
		end
	end
	return true
end

site.valid = valid_layout

return site
