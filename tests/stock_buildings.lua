-- Can a villager get into and out of every stock village building (#159)? Each
-- fixture in tests/fixtures/buildings/ is placed on flat ground with this mod's
-- furnishing applied, at every rotation and with its doors shut and open. Then
-- villagers are sent to every bed, jobsite and the tavern's jukebox from outside,
-- to each dinner chair and church pew (the cell seat.lua has a guest stand at) and
-- the cleric's place at the pulpit, and from the rooms inside to the outdoors.
-- The church's own service walks are in tests/stock_church.lua.
-- The stub world is flat ground, a road, or flat but for a one-block step all round,
-- up or down, two cells out from the building (tests/support/stock_scene.lua).
-- The routes come from navigation.lua's real gopath with the engine's own
-- pathfinder stubbed out, so this exercises the planner and the passability
-- checks it uses. Whatever route comes back is then checked here, by rules that
-- are not the planner's own; the validator has cases of its own, below, and a
-- corner door that only a correct door rule gets past.
--
--   lua tests/stock_buildings.lua
--   STOCK_ONLY=tavern STOCK_VERBOSE=1 lua tests/stock_buildings.lua
local stock_world = dofile("tests/support/stock_world.lua")
local scene = dofile("tests/support/stock_scene.lua")
local check = dofile("tests/support/stock_check.lua")
-- The cases that do not pass yet, as patterns over the case names printed below.
-- A case that starts passing fails the test until its pattern is removed, and so
-- does a pattern that matches nothing, so the list only ever shrinks.
local known = dofile("tests/support/stock_buildings_known.lua")
local verbose = os.getenv("STOCK_VERBOSE")
local only = os.getenv("STOCK_ONLY")
local recorder = check.recorder(known, verbose)
local record, unexpected = recorder.record, recorder.unexpected
local cell_string, check_route = check.cell_string, check.check_route

local BUILDINGS = {
	"belltower", "blacksmith", "butcher", "church", "farm", "lamp", "large_house",
	"library", "medium_house", "small_house", "small_house_loomless", "tavern", "well",
}
local DIRECTIONS, ORIGIN, MARGIN = scene.DIRECTIONS, scene.ORIGIN, scene.MARGIN
-- The time of day each kind of trip is scheduled for (common.lua's SCHEDULE).
local HOME, WORK, TAVERN = 0.8, 0.3, 0.7

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
	-- A trip with no field of its own (a guest to its seat, a cleric to its place)
	-- is the generic destination walk.
	if field then
		entity[field] = target
		world.claim(target, "v1")
	end
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

local function test_building(name, rotation, doors_open, roads, slope)
	local built = scene.build(name, rotation, doors_open, roads, slope)
	local world, size, prefix, beds, outdoors = built.world, built.size, built.prefix, built.beds, built.outdoors
	local common = dofile("common.lua")

	local def = {on_activate = function() end, do_custom = function() end, gopath = function() return false end}
	dofile("navigation.lua")(def)
	local seat_def = def

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

	-- The raised belltower (#150) has no bed or jobsite, so the exits from its
	-- floor are its only routes: none means the furnisher (belltower_schematic.lua)
	-- is gone and the interior is a pit with no floor to stand on at y 1.
	if name == "belltower" then
		if #starts == 0 then
			table.insert(unexpected, prefix .. ": no floor to stand on inside the belltower")
		end
		for _, pos in ipairs(starts) do world.set({x = pos.x, y = pos.y - 1, z = pos.z}, "air") end
		for _, pos in ipairs(starts) do
			if world.is_plain_floor(pos) then
				table.insert(unexpected, prefix .. ": floor turned to air still counts as floor at " .. cell_string(pos))
			end
		end
	end

	-- To the seats and the pulpit's place, as the modules that send villagers there
	-- choose them (#159). seat.lua picks a reachable chair by what is beside it,
	-- and the cell to stand at to sit down from; the cleric stands where
	-- church.lua's cleric_stand puts it. Both are walks to a cell, not to a node.
	do
		local seat = dofile("seat.lua")
		local church_module = dofile("church.lua")
		local original_find = minetest.find_nodes_in_area
		minetest.find_nodes_in_area = function(minp, maxp, names)
			local found = {}
			for x = minp.x, maxp.x do for y = minp.y, maxp.y do for z = minp.z, maxp.z do
				local pos = {x = x, y = y, z = z}
				for _, name in ipairs(names) do
					local group_name = name:match("^group:(.*)$")
					local node_name = world.get(pos).name
					if (group_name and minetest.get_item_group(node_name, group_name) > 0) or node_name == name then
						table.insert(found, pos)
						break
					end
				end
			end end end
			return found
		end
		local seat_counts = {}
		local centers = {}
		for _, target in ipairs(targets) do
			if target.kind == "jukebox" then table.insert(centers, {pos = target.pos, kind = "table"}) end
			if target.kind == "jobsite pulpit" then table.insert(centers, {pos = target.pos, kind = "pulpit"}) end
		end
		local ok_centers, problem = pcall(function() for _, center in ipairs(centers) do
			-- Reserve until the chairs run out: each guest holds its own.
			local guests = {}
			for n = 1, 100 do
				local guest = {_id = "guest" .. n, object = {get_pos = function() return outdoors("north") end}}
				if not seat.reserve(guest, center.pos, center.kind) then break end
				table.insert(guests, guest._villages_seat)
			end
			seat_counts[center.kind] = #guests
			for _, held in ipairs(guests) do
				for _, direction in ipairs(DIRECTIONS) do
					local id = ("%s %s seat %s from %s"):format(prefix, center.kind == "pulpit" and "pew" or "dinner",
						cell_string(world.fixture_pos(held.chair)), direction)
					local cells, reason = route(world, seat_def, outdoors(direction), held.approach, nil,
						"_villages_goto_route", TAVERN)
					if cells then
						record(id, check_route(world, cells, held.approach))
					else
						record(id, false, reason)
					end
				end
			end
			for held_key in pairs(seat.reservations) do seat.reservations[held_key] = nil end
			if center.kind == "pulpit" then
				local stand = church_module.cleric_stand(center.pos, "cleric")
				if not stand then
					record(prefix .. " cleric place", false, "no place to stand beside the pulpit")
				else
					for _, direction in ipairs(DIRECTIONS) do
						local id = ("%s cleric place %s from %s"):format(prefix, cell_string(world.fixture_pos(stand)), direction)
						local cells, reason = route(world, seat_def, outdoors(direction), stand, nil,
							"_villages_goto_route", TAVERN)
						if cells then
							record(id, check_route(world, cells, stand))
						else
							record(id, false, reason)
						end
					end
				end
			end
		end end)
		minetest.find_nodes_in_area = original_find
		if not ok_centers then error(problem, 0) end
		-- The stock tavern has 6 dinner seats, the stock church 12 pews: fewer
		-- means seats went unfound, and their routes were not tried.
		local wanted = {tavern = {table = 6}, church = {pulpit = 12}}
		for kind, count in pairs(wanted[name] or {}) do
			if seat_counts[kind] ~= count then
				table.insert(unexpected, ("%s: %s seats found %s, wanted %d"):format(prefix, kind, tostring(seat_counts[kind]), count))
			end
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
		-- And with a step in the ground beyond the building, up and down.
		for rotation = 0, 1 do
			test_building(name, rotation, false, false, 1)
			test_building(name, rotation, false, false, -1)
		end
	end
end

recorder.finish("stock buildings", only)
