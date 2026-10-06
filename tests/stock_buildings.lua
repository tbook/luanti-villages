-- Can a villager get into and out of every stock village building (#159)? Each
-- fixture in tests/fixtures/buildings/ is placed on flat ground with this mod's
-- furnishing applied, at every rotation and with its doors shut and open. Then
-- villagers are sent to every bed, jobsite and the tavern's jukebox from outside,
-- and from the rooms inside to the outdoors.
-- The routes come from navigation.lua's real gopath with the engine's own
-- pathfinder stubbed out, so this exercises the planner and the passability
-- checks it uses. Whatever route comes back is then checked here, by rules that
-- are not the planner's own.
--
--   lua tests/stock_buildings.lua
--   STOCK_ONLY=tavern STOCK_VERBOSE=1 lua tests/stock_buildings.lua
local stock_world = dofile("tests/support/stock_world.lua")
local doors = dofile("doors.lua")
-- The cases that do not pass yet, as patterns over the case names printed below.
-- A case that starts passing fails the test until its pattern is removed, and so
-- does a pattern that matches nothing, so the list only ever shrinks.
local known = dofile("tests/support/stock_buildings_known.lua")
local known_hits = {}

local verbose = os.getenv("STOCK_VERBOSE")
local only = os.getenv("STOCK_ONLY")

local BUILDINGS = {
	"belltower", "blacksmith", "butcher", "church", "farm", "lamp", "large_house",
	"library", "medium_house", "small_house", "tavern", "well",
}
local DIRECTIONS = {"north", "south", "west", "east"}
-- Where the building goes, and how far beyond each side the outdoor beds are.
local ORIGIN = 30
local MARGIN = 7
-- The time of day each kind of trip is scheduled for (common.lua's SCHEDULE).
local HOME, WORK, TAVERN = 0.8, 0.3, 0.7

-- Furnishing this mod gives newly generated buildings (#20, #21, #152), loaded
-- once the engine stubs are in. Each module returns its furnish function when
-- the village generator is absent. Not every branch has all of them.
local FURNISHERS = {
	tavern = "tavern_schematic.lua", church = "church_schematic.lua", library = "library_schematic.lua",
}

local passes, failures, unexpected = 0, 0, {}

local function known_rule(id)
	for index, rule in ipairs(known) do
		if id:find(rule.match) then
			known_hits[index] = true
			return rule
		end
	end
end

local function record(id, ok, detail)
	if ok then
		passes = passes + 1
		if known_rule(id) then
			table.insert(unexpected, id .. " passes now; remove its rule from tests/support/stock_buildings_known.lua")
		end
		if verbose then print("ok   " .. id) end
	else
		failures = failures + 1
		if not known_rule(id) then table.insert(unexpected, id .. ": " .. tostring(detail)) end
		if verbose then print("FAIL " .. id .. ": " .. tostring(detail)) end
	end
end

local function cell_string(pos)
	return ("(%d,%d,%d)"):format(pos.x, pos.y, pos.z)
end

-- The rules a route is held to, none of them the planner's own: each step is to
-- a neighboring cell at most a level up or down; no feet cell is inside
-- something solid and the head cell over each is free; a door is crossed by an
-- entry and exit its leaf lets through in one state or the other; and the route
-- ends beside the target.
local function check_route(world, cells, target)
	local defs = stock_world.defs
	local function door(pos)
		local group = defs[world.get(pos).name].groups.door
		return group and group > 0
	end
	local function solid(pos)
		local def = defs[world.get(pos).name]
		if door(pos) then return false end
		if def.groups.carpet and def.groups.carpet > 0 then return false end
		return def.walkable or (def.collision_box and def.collision_box.type ~= "none")
	end
	for i, cell in ipairs(cells) do
		local previous = cells[i - 1]
		if previous then
			local dx, dz, dy = math.abs(cell.x - previous.x), math.abs(cell.z - previous.z), math.abs(cell.y - previous.y)
			if dx + dz ~= 1 or dy > 1 then
				return false, "steps from " .. cell_string(previous) .. " to " .. cell_string(cell)
			end
		end
		local head = {x = cell.x, y = cell.y + 1, z = cell.z}
		if solid(cell) then
			return false, ("feet inside %s at %s"):format(world.get(cell).name, cell_string(cell))
		end
		if solid(head) then
			return false, ("head inside %s at %s"):format(world.get(head).name, cell_string(head))
		end
		if door(cell) and previous and cells[i + 1] then
			local node = world.get(cell)
			local verdict = doors.crossing(node, defs[node.name], doors.sides_toward(cell, previous),
				doors.sides_toward(cell, cells[i + 1]))
			if verdict == false then return false, "the leaf of the door at " .. cell_string(cell) .. " blocks the turn" end
		end
	end
	local last = cells[#cells]
	if math.abs(last.x - target.x) > 1 or math.abs(last.z - target.z) > 1 or last.y ~= target.y then
		return false, "ends at " .. cell_string(last) .. ", away from the target"
	end
	return true
end

-- Sends a villager standing at `start` (a position, as an entity's is) to
-- `target`, which it claims as `field` says. Returns the cells of its route, or
-- nil and the reason it had none.
local function route(world, def, start, target, field, route_field, timeofday)
	world.timeofday = timeofday
	local entity = {
		_id = "v1", state = "stand",
		object = {
			get_pos = function() return {x = start.x, y = start.y, z = start.z} end,
			set_velocity = function() end,
		},
	}
	entity[field] = target
	world.claim(target, "v1")
	if not def.gopath(entity, target, nil, true) then
		return nil, (entity[route_field] or {}).reason or "gopath refused"
	end
	local cells = {}
	if entity.current_target then table.insert(cells, entity.current_target.pos) end
	for _, waypoint in ipairs(entity.waypoints or {}) do table.insert(cells, waypoint.pos) end
	return cells
end

local function test_building(name, rotation, doors_open)
	local fixture = dofile("tests/fixtures/buildings/" .. name .. ".lua")
	local world = stock_world.new()
	stock_world.install(world)
	local common = dofile("common.lua")
	local furnish = {}
	for module, file in pairs(FURNISHERS) do
		local handle = io.open(file, "r")
		if handle then
			handle:close()
			furnish[module] = dofile(file)
		end
	end
	local size = world.place(fixture, ORIGIN, ORIGIN, furnish, rotation)
	if doors_open then world.open_doors() end
	local prefix = ("%s r%d%s"):format(name, rotation * 90, doors_open and "o" or "")

	local def = {on_activate = function() end, do_custom = function() end, gopath = function() return false end}
	dofile("navigation.lua")(def)

	-- Outdoor beds, one beyond each side, for a route out to end at; a villager
	-- stands two cells from each, as it would after walking up.
	local mid_x, mid_z = ORIGIN + math.floor(size.x / 2), ORIGIN + math.floor(size.z / 2)
	local beds = {
		north = world.add_bed(mid_x, ORIGIN - MARGIN),
		south = world.add_bed(mid_x, ORIGIN + size.z + MARGIN),
		west = world.add_bed(ORIGIN - MARGIN - 1, mid_z),
		east = world.add_bed(ORIGIN + size.x + MARGIN, mid_z),
	}
	local function outdoors(direction)
		local bed = beds[direction]
		return {x = bed.x, y = bed.y - 0.49, z = bed.z + 2}
	end
	local function nearest_bed(pos)
		local best, best_distance
		for _, direction in ipairs(DIRECTIONS) do
			local bed = beds[direction]
			local distance = math.abs(bed.x - pos.x) + math.abs(bed.z - pos.z)
			if not best_distance or distance < best_distance then best, best_distance = bed, distance end
		end
		return best
	end
	local function in_footprint(pos)
		return pos.x >= ORIGIN and pos.x < ORIGIN + size.x and pos.z >= ORIGIN and pos.z < ORIGIN + size.z
	end

	-- Everything a villager has a reason to walk to.
	local targets, seats = {}, {}
	for x = ORIGIN, ORIGIN + size.x - 1 do
		for y = 1, size.y - 1 do
			for z = ORIGIN, ORIGIN + size.z - 1 do
				local pos = {x = x, y = y, z = z}
				local node_name = world.get(pos).name
				if stock_world.defs[node_name].groups.bed == 1 then
					table.insert(targets, {
						kind = "bed", pos = pos, field = "_bed", route_field = "_villages_bed_route", timeofday = HOME,
					})
				elseif node_name == "mcl_jukebox:jukebox" then
					table.insert(targets, {
						kind = "jukebox", pos = pos, field = "_villages_tavern_target",
						route_field = "_villages_tavern_route", timeofday = TAVERN,
					})
				elseif common.is_workstation_node(node_name) or node_name == "living_villages:pulpit" then
					table.insert(targets, {
						kind = "jobsite " .. node_name:match(":(.*)$"), pos = pos, field = "_jobsite",
						route_field = "_villages_job_route", timeofday = WORK,
					})
				elseif node_name:find("chair") then
					table.insert(seats, pos)
				end
			end
		end
	end

	-- From outside to each target, from every side.
	for _, target in ipairs(targets) do
		for _, direction in ipairs(DIRECTIONS) do
			local id = ("%s %s %s from %s"):format(prefix, target.kind, cell_string(world.fixture_pos(target.pos)), direction)
			local cells, reason = route(world, def, outdoors(direction), target.pos, target.field, target.route_field,
				target.timeofday)
			if cells then
				record(id, check_route(world, cells, target.pos))
			else
				record(id, false, reason)
			end
		end
	end

	-- From the open floor that matters inside to the nearest outdoor bed: every
	-- room a target is in (an attic under the roof is sealed by design and no
	-- villager has a reason to be in it) and the ground level of the footprint.
	local starts, seen = {}, {}
	local function add_start(pos)
		local id = cell_string(pos)
		if seen[id] or not in_footprint(pos) then return false end
		seen[id] = true
		table.insert(starts, pos)
		return true
	end
	local steps = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	local corners = {{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}
	for _, target in ipairs(targets) do
		local queue = {}
		for _, d in ipairs({steps[1], steps[2], steps[3], steps[4], corners[1], corners[2], corners[3], corners[4]}) do
			local pos = {x = target.pos.x + d[1], y = target.pos.y, z = target.pos.z + d[2]}
			if world.is_plain_floor(pos) and add_start(pos) then table.insert(queue, pos) end
		end
		while #queue > 0 do
			local pos = table.remove(queue)
			for _, d in ipairs(steps) do
				local next_pos = {x = pos.x + d[1], y = pos.y, z = pos.z + d[2]}
				if world.is_plain_floor(next_pos) and add_start(next_pos) then table.insert(queue, next_pos) end
			end
		end
	end
	for x = ORIGIN, ORIGIN + size.x - 1 do
		for z = ORIGIN, ORIGIN + size.z - 1 do
			local pos = {x = x, y = 1, z = z}
			if world.is_plain_floor(pos) then add_start(pos) end
		end
	end
	table.sort(starts, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		if a.z ~= b.z then return a.z < b.z end
		return a.x < b.x
	end)
	for _, pos in ipairs(starts) do
		local bed = nearest_bed(pos)
		local id = ("%s leave from %s"):format(prefix, cell_string(world.fixture_pos(pos)))
		local cells, reason = route(world, def, {x = pos.x, y = pos.y - 0.49, z = pos.z}, bed, "_bed",
			"_villages_bed_route", HOME)
		if cells then
			record(id, check_route(world, cells, bed))
		else
			record(id, false, reason)
		end
	end

	-- From a chair. A villager sitting in one is at the chair's node, half a
	-- node up (#156), so its feet are not over a floor cell and the planner has
	-- to find its own way down.
	for _, pos in ipairs(seats) do
		local bed = nearest_bed(pos)
		local id = ("%s leave from the chair at %s"):format(prefix, cell_string(world.fixture_pos(pos)))
		local cells, reason = route(world, def, {x = pos.x, y = pos.y + 0.5, z = pos.z}, bed, "_bed",
			"_villages_bed_route", HOME)
		if cells then
			record(id, check_route(world, cells, bed))
		else
			record(id, false, reason)
		end
	end
end

for _, name in ipairs(BUILDINGS) do
	if not only or only == name then
		-- Every rotation, with the doors shut and then left open.
		for variant = 0, 7 do test_building(name, variant % 4, variant >= 4) end
	end
end

for index, rule in ipairs(known) do
	if not known_hits[index] and (not only or rule.match:find("^%^" .. only)) then
		table.insert(unexpected, "known failure " .. rule.match .. " matched no case; remove it")
	end
end
if #unexpected > 0 then
	print(#unexpected .. " unexpected result(s):")
	for _, line in ipairs(unexpected) do print("  " .. line) end
	os.exit(1)
end
print(("stock buildings: %d routes passed, %d known failures"):format(passes, failures))
