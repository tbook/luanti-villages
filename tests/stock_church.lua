-- The stock church's own service walks (#159), the ones church.lua makes inside:
-- through its do_custom, with the real planner and route queue, on the stock church
-- at every rotation, with doors shut and open, on road ground and with a one-block
-- step in the ground all round (tests/support/stock_scene.lua).
--   - a member from the door to each of the 12 pews, then to the standing places at
--     the back, which back_places chooses, and every one of those from the door and
--     from one side outdoors;
--   - the cleric from the door, and from every cell of the church floor, to its
--     place behind the pulpit, and from outdoors to the floor in front of the dais.
-- Every route is held to check_route (the planner's cells against rules of our own).
-- The follower is then given the route (follower.lua) and, each tick, put on the
-- cell it heads for: that checks that it takes the route, pops its waypoints and
-- arrives, not that it can walk it. Turning, doors and jumps are not exercised;
-- tests/follower.lua and tests/church.lua have the rest.
--
--   lua tests/stock_church.lua
--   STOCK_VERBOSE=1 lua tests/stock_church.lua
local scene = dofile("tests/support/stock_scene.lua")
local check = dofile("tests/support/stock_check.lua")
local known = dofile("tests/support/stock_church_known.lua")
local verbose = os.getenv("STOCK_VERBOSE")
local recorder = check.recorder(known, verbose)
local record, unexpected = recorder.record, recorder.unexpected
local cell_string, check_route = check.cell_string, check.check_route
local DIRECTIONS, ORIGIN = scene.DIRECTIONS, scene.ORIGIN

local function church_service(world, prefix, pulpit, stand, door, outdoors, seat, church_module)
	local follower = dofile("follower.lua")
	local cdef = {
		on_activate = function() end, do_custom = function() end, get_staticdata = function() return {} end,
		set_animation = function() end, turn_in_direction = function() end, set_velocity = function() end,
		gopath = function() return false end,
	}
	dofile("navigation.lua")(cdef)
	church_module.install(cdef, seat)
	minetest.get_day_count = function() return 4 end
	minetest.get_us_time = minetest.get_us_time or function() return 0 end
	table.copy = table.copy or function(value)
		local copy = {}
		for k, v in pairs(value) do copy[k] = v end
		return copy
	end
	world.timeofday = 8000 / 24000
	local function villager(id, pos, profession)
		local self = {
			_id = id, _profession = profession or "farmer", state = "stand",
			collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}, bones = {}, walk_velocity = 1, run_velocity = 2,
		}
		self.set_yaw = function(entity, yaw) entity.target_yaw = yaw end
		local velocity = {x = 0, y = 0, z = 0}
		self.object = {
			get_pos = function() return pos end,
			set_pos = function(_, p) pos = p end,
			get_velocity = function() return velocity end,
			get_yaw = function() return 0 end,
			set_velocity = function(_, v) velocity = v end,
			set_acceleration = function() end,
			set_properties = function() end,
			set_bone_override = function() end,
		}
		return setmetatable(self, {__index = cdef})
	end
	local function at(cell) return {x = cell.x, y = cell.y - 0.49, z = cell.z} end
	-- Lets the route queue finish the villager's search, then returns its route.
	local function planned(v)
		for _ = 1, 100000 do
			if (v._villages_goto_route or {}).status ~= "planning" then break end
			for _, step in ipairs(world.globalsteps) do step(0.1) end
		end
		if (v._villages_goto_route or {}).status == "retry" then return nil, v._villages_goto_route.reason end
		if not v.current_target then return nil, "no route" end
		local cells = {v.current_target.pos}
		for _, waypoint in ipairs(v.waypoints or {}) do table.insert(cells, waypoint.pos) end
		return cells
	end
	-- Gives the follower the route and puts the villager on the cell it heads for
	-- each tick, as when it is on time. Returns whether it arrived.
	local function drive(v)
		for _ = 1, 400 do
			if not v._villages_follow then return true end
			v.object:set_pos(at(v.current_target.pos))
			follower.follow(v, 0.1)
		end
		return false
	end
	local function cell_key(cell) return cell.x .. "," .. cell.y .. "," .. cell.z end
	local function shown(cell) return cell_string(world.fixture_pos(cell) or cell) end
	local function settle(id, cells, reason, target, v)
		if not cells then return record(id, false, reason) end
		local ok, detail = check_route(world, cells, target)
		if ok and not drive(v) then ok, detail = false, "the follower never arrived" end
		record(id, ok, detail)
	end
	local function walking(v)
		local cells = {v.current_target.pos}
		for _, waypoint in ipairs(v.waypoints) do table.insert(cells, waypoint.pos) end
		return cells
	end

	-- The member's walks. Each takes a pew in turn from the door, then, with the
	-- pews full, the next standing place at the back.
	for n = 1, 12 do
		local v = villager("member" .. n, at(door))
		cdef.do_custom(v, 0.1)
		local held = v._villages_seat
		if not held then
			record(("%s church member %d to a pew from the door"):format(prefix, n), false, "no pew reserved")
		else
			settle(("%s church member to pew %s from the door"):format(prefix, shown(held.chair)),
				planned(v), nil, held.approach, v)
		end
	end
	local back = church_module.back_places(pulpit, "anyone")
	if #back == 0 then table.insert(unexpected, prefix .. ": the church has no standing place at the back") end
	for n = 1, math.min(#back, 6) do
		local v = villager("standee" .. n, at(door))
		cdef.do_custom(v, 0.1)
		local place = v._villages_church and v._villages_church.place
		if not place then
			record(("%s church member %d to a standing place from the door"):format(prefix, n), false, "no standing place")
		elseif not world.fixture_pos(place) then
			record(("%s church member to standing place %s outside the church from the door"):format(prefix, shown(place)),
				false, "a standing place outside the building")
		else
			settle(("%s church member to standing place %s from the door"):format(prefix, shown(place)),
				planned(v), nil, place, v)
		end
	end
	-- And every place at the back from the door and, turn about, from one side
	-- outdoors (the planner costs most of this suite's time).
	for index, found in ipairs(back) do
		local direction = DIRECTIONS[index % #DIRECTIONS + 1]
		local starts = {{"door", at(door)}, {direction, outdoors(direction)}}
		for _, from in ipairs(starts) do
			local v = villager("walker", from[2])
			local id = ("%s church back place %s from %s"):format(prefix, shown(found.cell), from[1])
			if not world.fixture_pos(found.cell) then
				record(("%s church back place %s outside the church from %s"):format(prefix, shown(found.cell), from[1]),
					false, "a standing place outside the building")
			elseif cdef.gopath(v, found.cell, nil, true) then
				local cells, reason = planned(v)
				if cells then record(id, check_route(world, cells, found.cell)) else record(id, false, reason) end
			else
				record(id, false, "gopath refused")
			end
		end
	end

	-- The cleric: from the door through the whole walk, then from every cell of
	-- the floor, and from each side of the building.
	local function cleric(pos)
		local v = villager("cleric", pos, "cleric")
		v._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
		world.claim(pulpit, "cleric")
		return v
	end
	local first = cleric(at(door))
	cdef.do_custom(first, 0.1)
	local state = first._villages_church
	if not (state and state.floor_cells and first.current_target) then
		return record(prefix .. " cleric walk from the door", false, "no route up onto the dais")
	end
	settle(prefix .. " cleric walk from the door", walking(first), nil, stand, first)
	local there = first.object:get_pos()
	record(prefix .. " cleric ends behind the pulpit", there.x == stand.x and there.z == stand.z
		and there.y == stand.y - 0.49, cell_string(there))
	local floor = {}
	for k in pairs(state.floor_cells) do
		local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
		table.insert(floor, {x = tonumber(x), y = tonumber(y), z = tonumber(z)})
	end
	table.sort(floor, function(a, b) if a.z ~= b.z then return a.z < b.z end return a.x < b.x end)
	for _, cell in ipairs(floor) do
		local v = cleric(at(cell))
		cdef.do_custom(v, 0.1)
		local id = ("%s cleric walk from the floor at %s"):format(prefix, shown(cell))
		if v.state ~= "gowp" or not v.current_target then
			record(id, false, "no walk")
		else
			settle(id, walking(v), nil, stand, v)
		end
	end
	for _, direction in ipairs(DIRECTIONS) do
		local v = cleric(outdoors(direction))
		cdef.do_custom(v, 0.1)
		local id = ("%s cleric walk to the dais front from %s"):format(prefix, direction)
		local cells, reason = planned(v)
		local front = v._villages_church and v._villages_church.floor
		if not front then
			record(id, false, "no dais front")
		elseif not cells then
			record(id, false, reason)
		else
			record(id, check_route(world, cells, front))
		end
	end
end


local function test_church(rotation, doors_open, roads, slope)
	local built = scene.build("church", rotation, doors_open, roads, slope)
	local world, size = built.world, built.size
	local seat = dofile("seat.lua")
	local church_module = dofile("church.lua")
	local pulpit
	for x = ORIGIN, ORIGIN + size.x - 1 do for y = 1, size.y - 1 do for z = ORIGIN, ORIGIN + size.z - 1 do
		if world.get({x = x, y = y, z = z}).name == "living_villages:pulpit" then pulpit = {x = x, y = y, z = z} end
	end end end
	assert(pulpit, built.prefix .. ": no pulpit")
	minetest.find_nodes_in_area = function(minp, maxp, names)
		local found = {}
		for x = minp.x, maxp.x do for y = minp.y, maxp.y do for z = minp.z, maxp.z do
			local pos = {x = x, y = y, z = z}
			local node_name = world.get(pos).name
			for _, name in ipairs(names) do
				local group_name = name:match("^group:(.*)$")
				if (group_name and minetest.get_item_group(node_name, group_name) > 0) or node_name == name then
					table.insert(found, pos)
					break
				end
			end
		end end end
		return found
	end
	-- Just inside the stock church's door: (1,2,6) in the fixture.
	local door
	for x = ORIGIN, ORIGIN + size.x - 1 do
		for z = ORIGIN, ORIGIN + size.z - 1 do
			local from = world.fixture_pos({x = x, y = 2, z = z})
			if from and from.x == 1 and from.z == 6 then door = {x = x, y = 2, z = z} end
		end
	end
	local stand = church_module.cleric_stand(pulpit, "cleric")
	assert(door and stand, built.prefix .. ": no door cell or cleric place to walk the service from")
	church_service(world, built.prefix, pulpit, stand, door, built.outdoors, seat, church_module)
end

-- Every rotation, doors shut and then open; road ground; a step up and down.
for variant = 0, 7 do test_church(variant % 4, variant >= 4) end
for rotation = 0, 3 do test_church(rotation, false, true) end
for rotation = 0, 1 do
	test_church(rotation, false, false, 1)
	test_church(rotation, false, false, -1)
end

-- back_places must find the standing places inside whatever the roof's height, and
-- never outdoors under foliage (#189). Built on the slope-up variant, where the
-- ground outside the back wall is as high as the floor.
local function test_roofs()
	local function build()
		local built = scene.build("church", 0, false, false, 1)
		local world, size = built.world, built.size
		local pulpit
		for x = ORIGIN, ORIGIN + size.x - 1 do for y = 1, size.y - 1 do for z = ORIGIN, ORIGIN + size.z - 1 do
			if world.get({x = x, y = y, z = z}).name == "living_villages:pulpit" then pulpit = {x = x, y = y, z = z} end
		end end end
		return world, size, pulpit, dofile("church.lua")
	end
	local function places(world, pulpit, church_module)
		local found = church_module.back_places(pulpit, "anyone")
		for _, place in ipairs(found) do
			if not world.fixture_pos(place.cell) then
				table.insert(unexpected, "roofs: standing place " .. cell_string(place.cell) .. " is outdoors")
			end
		end
		return found
	end
	local world, size, pulpit, church_module = build()
	local normal = #places(world, pulpit, church_module)
	if normal == 0 then table.insert(unexpected, "roofs: the stock church has no standing place") end
	-- A taller church: the whole roof one flat slab 18 above the pulpit.
	world, size, pulpit, church_module = build()
	for x = ORIGIN, ORIGIN + size.x - 1 do for z = ORIGIN, ORIGIN + size.z - 1 do
		for y = pulpit.y + 3, pulpit.y + 30 do world.set({x = x, y = y, z = z}, "air") end
		world.set({x = x, y = pulpit.y + 18, z = z}, "mcl_core:stone")
	end end
	local tall = #places(world, pulpit, church_module)
	if tall ~= normal then
		table.insert(unexpected, ("roofs: %d standing places under a tall roof, %d under the stock one"):format(tall, normal))
	end
	-- Leaves over the raised ground outside, within reach: not a roof.
	world, size, pulpit, church_module = build()
	minetest.registered_nodes["mcl_core:leaves"] = {groups = {leaves = 1}, walkable = true, drawtype = "allfaces_optional", liquidtype = "none"}
	for x = ORIGIN - 12, ORIGIN + size.x + 12 do for z = ORIGIN - 12, ORIGIN + size.z + 12 do
		local inside = x >= ORIGIN and x < ORIGIN + size.x and z >= ORIGIN and z < ORIGIN + size.z
		if not inside then world.set({x = x, y = pulpit.y + 5, z = z}, "mcl_core:leaves") end
	end end
	local shaded = #places(world, pulpit, church_module)
	if shaded ~= normal then
		table.insert(unexpected, ("roofs: %d standing places with a canopy outside, %d without"):format(shaded, normal))
	end
end
test_roofs()
recorder.finish("stock church")
