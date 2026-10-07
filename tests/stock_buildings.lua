-- Can a villager get into and out of every stock village building (#159)? Each
-- fixture in tests/fixtures/buildings/ is placed on flat ground with this mod's
-- furnishing applied, at every rotation and with its doors shut and open. Then
-- villagers are sent to every bed, jobsite and the tavern's jukebox from outside,
-- and from the rooms inside to the outdoors.
-- The routes come from navigation.lua's real gopath with the engine's own
-- pathfinder stubbed out, so this exercises the planner and the passability
-- checks it uses. Whatever route comes back is then checked here, by rules that
-- are not the planner's own; the validator has cases of its own, below, and a
-- corner door that only a correct door rule gets past.
--
--   lua tests/stock_buildings.lua
--   STOCK_ONLY=tavern STOCK_VERBOSE=1 lua tests/stock_buildings.lua
local stock_world = dofile("tests/support/stock_world.lua")
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

-- Facts about mcl_doors (api_doors.lua), verified for #121 and kept here rather
-- than taken from doors.lua so that a regression there cannot excuse itself: every
-- variant's leaf lies on one edge of its node, which for facedir p is north, west,
-- south or east for p 0..3; toggling a door turns it a quarter, forward when it is
-- closed and not mirrored or open and mirrored, back otherwise. The variants are
-- named _b_ or _t_ then 1 closed, 2 open, 3 closed mirrored, 4 open mirrored.
local LEAF_EDGE = {[0] = "n", "w", "s", "e"}

local function door_blocks(node, entry_edge, exit_edge)
	local variant = tonumber(node.name:match("_[bt]_(%d)$"))
	local open, mirrored = variant % 2 == 0, variant > 2
	local forward = open == mirrored
	local toggled = (node.param2 + (forward and 1 or -1)) % 4
	for _, leaf in ipairs({LEAF_EDGE[node.param2 % 4], LEAF_EDGE[toggled]}) do
		if leaf ~= entry_edge and leaf ~= exit_edge then return false end
	end
	return true
end

local function edge_toward(from, to)
	if to.x > from.x then return "e" elseif to.x < from.x then return "w" end
	return to.z > from.z and "s" or "n"
end

-- How high a node's collision reaches above the node's center: 0.5 for a full
-- cube, less for a slab or carpet, more for a fence.
local function collision_top(def)
	local box = def.collision_box or (def.drawtype == "nodebox" and def.node_box)
	if not box or box.type ~= "fixed" then return 0.5 end
	local fixed = box.fixed
	if type(fixed[1]) == "number" then return fixed[5] end
	local top = -0.5
	for _, part in ipairs(fixed) do top = math.max(top, part[5]) end
	return top
end

-- The rules a route is held to, none of them the planner's own: each step is to
-- a neighboring cell at most a level up or down; every cell has floor to stand on
-- (a full-height solid that is not a fence, wall or trapdoor); no feet cell is
-- inside something solid, and the head cell over each is free, carpet at the feet
-- being the one thing a villager stands in; a step up has the cell above the
-- departure head free, since the jump swings the head through it (#56); a door
-- is crossed by an entry and exit its leaf lets through in one state or the other;
-- and the route ends beside the target.
local function check_route(world, cells, target)
	local defs = stock_world.defs
	local function group(pos, name)
		local found = defs[world.get(pos).name].groups[name]
		return found and found > 0
	end
	local function solid(pos, feet)
		local def = defs[world.get(pos).name]
		if group(pos, "door") then return false end
		if feet and group(pos, "carpet") then return false end
		return def.walkable or (def.collision_box and def.collision_box.type ~= "none")
	end
	local function floor_under(cell)
		local below = {x = cell.x, y = cell.y - 1, z = cell.z}
		local def = defs[world.get(below).name]
		-- A full block, or the sixteenth or two short of one that a grass path or
		-- farmland is.
		if not def.walkable or collision_top(def) < 0.4 or (def.damage_per_second or 0) > 0 then return false end
		return not (group(below, "fence") or group(below, "fence_gate") or group(below, "wall") or group(below, "trapdoor"))
	end
	for i, cell in ipairs(cells) do
		local previous = cells[i - 1]
		if previous then
			local dx, dz, dy = math.abs(cell.x - previous.x), math.abs(cell.z - previous.z), cell.y - previous.y
			if dx + dz ~= 1 or math.abs(dy) > 1 then
				return false, "steps from " .. cell_string(previous) .. " to " .. cell_string(cell)
			end
			local over = {x = previous.x, y = previous.y + 2, z = previous.z}
			if dy == 1 and solid(over) then
				return false, ("jumps from %s into %s at %s"):format(cell_string(previous), world.get(over).name, cell_string(over))
			end
		end
		local head = {x = cell.x, y = cell.y + 1, z = cell.z}
		if not floor_under(cell) then
			return false, ("no floor under %s, which is %s"):format(cell_string(cell),
				world.get({x = cell.x, y = cell.y - 1, z = cell.z}).name)
		end
		if solid(cell, true) then
			return false, ("feet inside %s at %s"):format(world.get(cell).name, cell_string(cell))
		end
		if solid(head) then
			return false, ("head inside %s at %s"):format(world.get(head).name, cell_string(head))
		end
		if group(cell, "door") and previous and cells[i + 1] then
			if door_blocks(world.get(cell), edge_toward(cell, previous), edge_toward(cell, cells[i + 1])) then
				return false, "the leaf of the door at " .. cell_string(cell) .. " blocks the turn"
			end
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
	local started = def.gopath(entity, target, nil, true)
	-- Planning runs from the route queue's globalstep (#162).
	for _ = 1, 100000 do
		if (entity[route_field] or {}).status ~= "planning" then break end
		for _, step in ipairs(world.globalsteps) do step(0.1) end
	end
	if not started or (entity[route_field] or {}).status == "retry" then
		return nil, (entity[route_field] or {}).reason or "gopath refused"
	end
	local cells = {}
	if entity.current_target then table.insert(cells, entity.current_target.pos) end
	for _, waypoint in ipairs(entity.waypoints or {}) do table.insert(cells, waypoint.pos) end
	return cells
end

local function test_building(name, rotation, doors_open, roads)
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
	if roads then
		-- Village roads are grass path, a sixteenth lower than a full block: the
		-- ground all round the building, as a generated village lays it (#156).
		for x = ORIGIN - MARGIN - 4, ORIGIN + size.x + MARGIN + 4 do
			for z = ORIGIN - MARGIN - 4, ORIGIN + size.z + MARGIN + 4 do
				local inside = x >= ORIGIN and x < ORIGIN + size.x and z >= ORIGIN and z < ORIGIN + size.z
				if not inside then world.set({x = x, y = world.ground_y, z = z}, "mcl_core:grass_path") end
			end
		end
	end
	local prefix = ("%s r%d%s%s"):format(name, rotation * 90, doors_open and "o" or "", roads and " roads" or "")

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

-- The validator against routes it must reject, each with a control it must accept.
-- Not touched by STOCK_ONLY, so a weakened validator cannot hide in a narrowed run.
local function expect_valid(world, cells, target, wanted, why)
	local ok, reason = check_route(world, cells, target)
	if ok ~= wanted then
		table.insert(unexpected, ("validator: %s (%s)"):format(why, ok and "accepted" or reason))
	elseif not wanted and verbose then
		print("rejected as it should: " .. why .. ": " .. reason)
	end
end

do
	local function c(x, y, z) return {x = x, y = y, z = z} end
	-- A step up under a ceiling: the head is clear at both cells, but the jump
	-- from (0,1,0) swings it through (0,3,0).
	local world = stock_world.new()
	world.set(c(1, 1, 0), "mcl_core:stone")
	expect_valid(world, {c(0, 1, 0), c(1, 2, 0)}, c(2, 2, 0), true, "a step up in the open")
	world.set(c(0, 3, 0), "mcl_core:stone")
	expect_valid(world, {c(0, 1, 0), c(1, 2, 0)}, c(2, 2, 0), false, "a step up under a ceiling")
	-- Carpet is something to stand in, not to walk into.
	world = stock_world.new()
	world.set(c(0, 1, 0), "mcl_wool:white_carpet")
	expect_valid(world, {c(0, 1, 0)}, c(1, 1, 0), true, "standing in carpet")
	world = stock_world.new()
	world.set(c(0, 2, 0), "mcl_wool:white_carpet")
	expect_valid(world, {c(0, 1, 0)}, c(1, 1, 0), false, "carpet at head height")
	-- A cell with nothing under it, and one over a slab too low to count.
	world = stock_world.new()
	expect_valid(world, {c(0, 1, 0)}, c(1, 1, 0), true, "standing on the ground")
	expect_valid(world, {c(0, 5, 0)}, c(1, 5, 0), false, "standing in mid-air")
	world.set(c(0, 0, 0), "mcl_stairs:slab_wood")
	expect_valid(world, {c(0, 1, 0)}, c(1, 1, 0), false, "standing over a bottom slab")
	-- A closed door with its leaf on the north edge, which toggling moves to the west.
	local function door(name, param2)
		local door_world = stock_world.new()
		door_world.set(c(0, 1, 0), "mcl_doors:wooden_door_b_" .. name, param2)
		door_world.set(c(0, 2, 0), "mcl_doors:wooden_door_t_" .. name, param2)
		return door_world
	end
	local north, south, west, east = c(0, 1, -1), c(0, 1, 1), c(-1, 1, 0), c(1, 1, 0)
	world = door("1", 0)
	expect_valid(world, {north, c(0, 1, 0), south}, south, true, "a closed door crossed straight")
	expect_valid(world, {north, c(0, 1, 0), east}, east, true, "a closed door, north to east")
	expect_valid(world, {north, c(0, 1, 0), west}, west, false, "a closed door, north to west")
	-- Open, it is at facedir 1 with the leaf on the west and toggles back to the north.
	world = door("2", 1)
	expect_valid(world, {north, c(0, 1, 0), east}, east, true, "an open door, north to east")
	expect_valid(world, {north, c(0, 1, 0), west}, west, false, "an open door, north to west")
end

-- A corner door (#121): a closed door whose leaf blocks north and, toggled, west,
-- between a north room and a room to its west or east. Walking from the north room
-- into the west one has to turn inside the door cell, which neither state allows;
-- into the east one, opening the door lets the villager turn. Everything else is
-- stone, so the door is the only way, and a planner that ignores the leaf
-- finds the way through.
local function corner_door(side)
	local world = stock_world.new()
	stock_world.install(world)
	local def = {on_activate = function() end, do_custom = function() end, gopath = function() return false end}
	dofile("navigation.lua")(def)
	for x = -4, 4 do for y = 1, 4 do for z = -4, 4 do world.set({x = x, y = y, z = z}, "mcl_core:stone") end end end
	local function carve(x, z) for y = 1, 2 do world.set({x = x, y = y, z = z}, "air") end end
	for z = -1, -3, -1 do carve(0, z) end
	local dx = side == "west" and -1 or 1
	carve(dx, 0)
	carve(dx * 2, 0)
	world.set({x = 0, y = 1, z = 0}, "mcl_doors:wooden_door_b_1", 0)
	world.set({x = 0, y = 2, z = 0}, "mcl_doors:wooden_door_t_1", 0)
	local bed = {x = dx * 3, y = 1, z = 0}
	world.set(bed, "mcl_beds:bed_red_bottom")
	world.set({x = dx * 4, y = 1, z = 0}, "mcl_beds:bed_red_top")
	local cells, reason = route(world, def, {x = 0, y = 0.51, z = -3}, bed, "_bed", "_villages_bed_route", HOME)
	return world, cells, reason, bed
end

do
	local world, cells = corner_door("west")
	if cells then
		local ok, reason = check_route(world, cells, {x = -3, y = 1, z = 0})
		table.insert(unexpected, "corner door: the planner routed through a door it cannot turn in" ..
			(ok and "" or " (" .. reason .. ")"))
	end
	local east_world, east_cells, reason, bed = corner_door("east")
	if not east_cells then
		table.insert(unexpected, "corner door: no route through a door that opens onto the turn: " .. tostring(reason))
	else
		local ok, why = check_route(east_world, east_cells, bed)
		if not ok then table.insert(unexpected, "corner door: " .. why) end
	end
end

for _, name in ipairs(BUILDINGS) do
	if not only or only == name then
		-- Every rotation, with the doors shut and then left open.
		for variant = 0, 7 do test_building(name, variant % 4, variant >= 4) end
		-- And with the ground a road of grass path.
		for rotation = 0, 3 do test_building(name, rotation, false, true) end
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
