-- Trip probe (#160). Runs villager trips on a copy of a real world and logs,
-- per trip, what the engine's pathfinder found, what the planner found, and
-- whether the villager arrived. It separates route failures from follower
-- failures, which is the number #164 (our own follower) is judged against.
--
-- It changes nothing about how a trip is chosen or followed. It wraps three
-- calls to look: the villager's `gopath` (the start and end of a trip),
-- `core.find_path` (to time the engine and check its routes for headroom the
-- way navigation.lua does), and the route fields navigation.lua keeps on the
-- villager (mode and planner report). In variant B it makes `core.find_path`
-- find nothing, so every managed trip (bed, jobsite, tavern) takes the planner
-- and the follower is given the planner's route.
--
-- Settings (the server config, written by tools/lv_trips/run.sh):
--   lv_trips_center  "x,y,z" of the village; lv_trips_radius how far around it to load
--   lv_trips_mode    "trials" (teleported starts, frozen time, A and B rounds) or
--                    "day" (natural schedule at lv_trips_speed, observed only)
--   lv_trips_rounds  rounds per stage and variant; lv_trips_stages the stages to run
--   lv_trips_label   names the run in the result lines
--   lv_trips_spot    "sx,sy,sz;bx,by,bz": mode "spot" teleports the villager that owns the bed at
--                    b to the start s at the `home` hour and logs it every step (see README)
--   lv_trips_goto    "gx;gy;gz": spot mode sends that villager to g instead of letting it choose
--   lv_trips_far     SECONDS villagers stay suspended (vanilla's player-in-range test, no player near)
--                    after the spot run starts; negative: always (see README)
local core = minetest
local modpath = core.get_modpath("lv_trips")
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")

local settings = core.settings
local function setting(name, default)
	local value = settings:get("lv_trips_" .. name)
	if value == nil or value == "" then return default end
	return value
end

local LABEL = setting("label", "run")
local MODE = setting("mode", "trials")
local CENTER -- set below, from the settings
local RADIUS = tonumber(setting("radius", 64))
local ROUNDS = tonumber(setting("rounds", 3))
local ROUND_LIMIT = tonumber(setting("round_limit", 150)) -- real seconds
local ROUND_MIN = 25 -- villagers decide on a trip within VoxeLibre's five second poll
local DAY_SPEED = tonumber(setting("speed", 72))
local RESULT_FILE = core.get_worldpath() .. "/lv_trips.jsonl"
local VILLAGER = "mobs_mc:villager"
local ROUTE_FIELDS = {
	bed = "_villages_bed_route", jobsite = "_villages_job_route", farm = "_villages_farm_route",
	fishing = "_villages_fish_route", tavern = "_villages_tavern_route",
	search = "_villages_job_search_route",
}

-- tod is the time of day to hold; managed stages are the ones navigation.lua
-- routes itself, so variant B (planner only) means something there. Normal
-- evenings and holiday evenings differ in the tavern's hours.
local STAGES = {
	{name = "home", tod = 0.745, managed = true},
	{name = "work", tod = 0.40, managed = true},
	{name = "tavern", tod = 0.68, managed = true},
	{name = "church", tod = 0.35, holiday = true},
	{name = "bell", tod = 0.50, holiday = true},
	{name = "holiday_tavern", tod = 0.62, holiday = true, managed = true},
	-- Only for --spot: late evening, when every villager's schedule says home.
	{name = "night", tod = 0.79, managed = true},
}

local round_info = {} -- the stage, variant and round being run
local spot_owner -- the villager a spot run follows: its gopath calls are logged (#216)

local function log(message) core.log("action", "[lv_trips] " .. message) end
-- Which checkout of the mod this run measures (run.sh --mod-dir).
log("living_villages loaded from " .. tostring(core.get_modpath("living_villages")))

local out = io.open(RESULT_FILE, "a")
local function emit(record)
	record.label = LABEL
	out:write(core.write_json(record), "\n")
	out:flush()
end

local function now_ms() return core.get_us_time() / 1000 end
local function wall() return core.get_us_time() / 1000000 end

local function villager_id(self) return self._id or tostring(self.object) end
local function vec(pos) return pos and {x = pos.x, y = pos.y, z = pos.z} or nil end
local function round1(n) return n and math.floor(n * 10 + 0.5) / 10 or nil end

-- Holidays: common.is_holiday reads the moon phase, so answer for it.
local holiday = false
if mcl_moon and mcl_moon.get_moon_phase then
	mcl_moon.get_moon_phase = function()
		if not holiday then return 1 end
		-- mcl_moon turns the phase at midday; is_holiday adds one before it.
		return core.get_timeofday() <= 0.5 and 3 or 0
	end
end

-- No player is near the headless server, so vanilla would freeze the villagers.
-- `lv_trips_far` SECONDS leaves that as it is until SECONDS after the spot run starts (a
-- negative number: for good): villagers more than mcl_mob_active_range (48) nodes from every
-- player, as most of a village is for a player at one end of it (#201), then a player arrives.
local FAR = {secs = tonumber(core.settings:get("lv_trips_far")) or 0}
core.register_on_mods_loaded(function()
	local class = mcl_mobs.mob_class
	local original = class.player_in_active_range
	class.player_in_active_range = function(self, ...)
		if self.name == VILLAGER and (FAR.secs == 0 or (FAR.until_us and core.get_us_time() >= FAR.until_us)) then
			return true
		end
		return original(self, ...)
	end
	-- A villager that dies mid-run is not a trip result; say why it died.
	local damage_mob = class.damage_mob
	class.damage_mob = function(self, reason, damage, ...)
		if self.name == VILLAGER and self.object:get_pos() then
			emit({
				type = "damage", village = LABEL, villager = villager_id(self), reason = reason, damage = damage,
				health = self.health, pos = vec(self.object:get_pos()), stage = round_info.stage and round_info.stage.name,
			})
		end
		return damage_mob(self, reason, damage, ...)
	end
end)

----------------------------------------------------------------------
-- The engine's pathfinder, observed (and in variant B, silenced).
----------------------------------------------------------------------

-- Mirrors navigation.lua's has_headroom: the node above every waypoint must
-- be open (a wooden door counts as open).
local function open_node(pos)
	local node = core.get_node_or_nil(pos)
	if not node then return false end
	if core.get_item_group(node.name, "door") > 0 then return core.get_item_group(node.name, "door_iron") == 0 end
	local def = core.registered_nodes[node.name]
	return def ~= nil and not def.walkable and (not def.collision_box or def.collision_box.type == "none")
		and (def.liquidtype == nil or def.liquidtype == "none")
end

local function path_has_headroom(path)
	for _, pos in ipairs(path) do
		if not open_node(vector.round({x = pos.x, y = pos.y + 1, z = pos.z})) then return false end
	end
	return true
end

local real_find_path = core.find_path
local collector, silence_engine
core.find_path = function(...)
	if silence_engine then
		if collector then table.insert(collector, {silenced = true}) end
		return nil
	end
	local started = now_ms()
	local path = real_find_path(...)
	if collector then
		table.insert(collector, {
			ms = now_ms() - started, found = path ~= nil, length = path and #path or nil,
			headroom = path and path_has_headroom(path) or nil,
		})
	end
	return path
end

----------------------------------------------------------------------
-- Trips
----------------------------------------------------------------------

local trips = {} -- open trips by villager id
local closed_this_round = 0


local function current_route(self)
	local id = self._villages_route_id
	for kind, field in pairs(ROUTE_FIELDS) do
		local route = self[field]
		if route and route.id == id then return kind, route end
	end
end

local function route_snapshot(self)
	local kind, route = current_route(self)
	if not route then return nil end
	local planner = route.planner
	return {
		-- navigation.lua no longer names a route mode (#165): every route is the
		-- planner's unless it never got going.
		route = kind, status = route.status, mode = route.status ~= "retry" and "planner" or nil,
		reason = route.reason,
		planner_status = planner and planner.status, planner_searched = planner and planner.searched,
		planner_closest = planner and planner.closest_distance,
	}
end

local function kind_of_target(self, target, stage)
	local function same(a) return a and a.x == target.x and a.y == target.y and a.z == target.z end
	if same(self._bed) then return "bed" end
	if same(self._jobsite) then return "jobsite" end
	if same(self._villages_tavern_target) then return "tavern" end
	if same(self._villages_farm_target) then return "farm" end
	if same(self._villages_fish_target) then return "fishing" end
	return stage and stage.name or "other"
end

local function begin_trip(self, target)
	local pos = self.object:get_pos()
	local trip = {
		villager = villager_id(self), entity = self, target = vec(target), start = vec(pos),
		kind = kind_of_target(self, target, round_info.stage), started_at = wall(), calls = {}, events = {},
		last_pos = vec(pos), last_progress = wall(), stage = round_info.stage and round_info.stage.name,
		variant = round_info.variant, round = round_info.round,
		origin = round_info.origins and round_info.origins[villager_id(self)] or nil,
	}
	trip.distance = pos and round1(vector.distance(pos, target)) or nil
	trip.rise = pos and round1(target.y - pos.y) or nil
	trips[trip.villager] = trip
	return trip
end

local function note_event(trip)
	local snapshot = route_snapshot(trip.entity)
	local state = trip.entity.state
	local last = trip.events[#trip.events]
	local signature = (snapshot and (snapshot.status .. "/" .. tostring(snapshot.mode) .. "/" .. tostring(snapshot.reason)) or "-")
		.. "|" .. tostring(state)
	if not last or last.signature ~= signature then
		table.insert(trip.events, {
			t = round1(wall() - trip.started_at), signature = signature, state = state, route = snapshot,
		})
	end
end

-- What the villager is standing in and near when a trip ends without arriving.
local function stuck_report(trip)
	local self = trip.entity
	local pos = self.object:get_pos()
	if not pos then return nil end
	local cell = vector.round(pos)
	local function name_at(p) local node = core.get_node_or_nil(p) return node and node.name or "ignore" end
	local report = {
		pos = vec(pos), state = self.state, stalled_s = round1(wall() - trip.last_progress),
		feet = name_at(cell), head = name_at({x = cell.x, y = cell.y + 1, z = cell.z}),
		below = name_at({x = cell.x, y = cell.y - 1, z = cell.z}),
		to_target = round1(vector.distance(pos, trip.target)),
		current_target = self.current_target and self.current_target.pos and vec(self.current_target.pos) or nil,
		waypoints_left = self.waypoints and #self.waypoints or 0,
		doors = {}, neighbors = 0,
	}
	for _, found in ipairs(core.find_nodes_in_area(
			{x = cell.x - 2, y = cell.y - 1, z = cell.z - 2}, {x = cell.x + 2, y = cell.y + 2, z = cell.z + 2},
			{"group:door"})) do
		local node = core.get_node(found)
		table.insert(report.doors, {pos = vec(found), name = node.name, param2 = node.param2})
	end
	for _, object in ipairs(core.get_objects_inside_radius(pos, 1.5)) do
		local entity = object:get_luaentity()
		if entity and entity.name == VILLAGER and entity ~= self then report.neighbors = report.neighbors + 1 end
	end
	return report
end

local function close_trip(trip, reason)
	if trips[trip.villager] ~= trip then return end
	trips[trip.villager] = nil
	closed_this_round = closed_this_round + 1
	note_event(trip)
	local record = {
		type = "trip", village = round_info.village, stage = trip.stage, variant = trip.variant, round = trip.round,
		villager = trip.villager, kind = trip.kind, start = trip.start, target = trip.target,
		origin = trip.origin, distance = trip.distance, rise = trip.rise, calls = trip.calls, events = trip.events,
		duration_s = round1(wall() - trip.started_at), holiday = holiday,
	}
	record.final_route = route_snapshot(trip.entity)
	for _, event in ipairs(trip.events) do
		if event.route and event.route.status == "travelling" then
			record.mode = event.route.mode
			record.route_kind = event.route.route
		end
	end
	if trip.arrived_at then
		record.outcome = "arrived"
		record.arrive_s = round1(trip.arrived_at - trip.started_at)
	else
		local started = false
		for _, call in ipairs(trip.calls) do if call.started then started = true end end
		local recovered = false
		for _, event in ipairs(trip.events) do
			if event.route and event.route.mode == "planner" and event.route.status == "travelling" then recovered = true end
		end
		record.started = started
		record.recovered_by_planner = recovered
		if reason == "superseded" then
			record.outcome = "superseded"
		elseif started or trip.entity.state == "gowp" then
			record.outcome = "stuck"
			record.stuck = stuck_report(trip)
		else
			record.outcome = "no_route"
		end
	end
	emit(record)
end

core.register_on_mods_loaded(function()
	local def = core.registered_entities[VILLAGER]
	local original = def.gopath
	def.gopath = function(self, target, callback, prioritised)
		if not self.object:get_pos() then return original(self, target, callback, prioritised) end
		if self == spot_owner then
			local pos, bed, site = self.object:get_pos(), self._bed, self._jobsite
			local what = "elsewhere"
			if bed and vector.equals(vector.round(target), vector.round(bed)) then what = "BED"
			elseif site and vector.equals(vector.round(target), vector.round(site)) then what = "JOBSITE" end
			core.log("action", string.format(
				"[lv_trips] gopath t=%.2f target=%s (%s) from=%s bed_dist=%.1f order=%s state=%s caller=%s",
				wall(), core.pos_to_string(vector.round(target)), what, core.pos_to_string(vector.round(pos)),
				bed and vector.distance(pos, bed) or -1, tostring(self.order), tostring(self.state),
				(debug.traceback("", 2):gsub("%s+", " "):sub(1, 260))))
		end
		local trip = trips[villager_id(self)]
		if trip and not (trip.target.x == target.x and trip.target.y == target.y and trip.target.z == target.z) then
			close_trip(trip, "superseded")
			trip = nil
		end
		trip = trip or begin_trip(self, target)
		local wrapped = function(entity, ...)
			trip.arrived_at = wall()
			local result = callback and callback(entity, ...)
			close_trip(trip, "arrived")
			return result
		end
		local engine = {}
		collector = engine
		local started_at = now_ms()
		local started = original(self, target, wrapped, prioritised)
		local elapsed = now_ms() - started_at
		collector = nil
		local call = {
			t = round1(wall() - trip.started_at), started = started and true or false, ms = round1(elapsed),
			engine_calls = #engine, engine_ms = 0, engine_found = 0, engine_headroom = 0, route = route_snapshot(self),
		}
		for _, item in ipairs(engine) do
			call.engine_ms = call.engine_ms + (item.ms or 0)
			if item.found then call.engine_found = call.engine_found + 1 end
			if item.headroom then call.engine_headroom = call.engine_headroom + 1 end
		end
		call.engine_ms = round1(call.engine_ms)
		table.insert(trip.calls, call)
		note_event(trip)
		return started
	end
end)

-- Follow every open trip once a second: progress, and the route's changes.
local poll_timer = 0
core.register_globalstep(function(dtime)
	poll_timer = poll_timer + dtime
	if poll_timer < 1 then return end
	poll_timer = 0
	for _, trip in pairs(trips) do
		local self = trip.entity
		local pos = self.object and self.object:get_pos()
		if not pos then
			close_trip(trip, "gone")
		else
			if not trip.last_pos or vector.distance(pos, trip.last_pos) >= 0.35 then
				trip.last_pos, trip.last_progress = vec(pos), wall()
			end
			note_event(trip)
		end
	end
end)

----------------------------------------------------------------------
-- The villagers and the village
----------------------------------------------------------------------

local function villagers()
	local list = {}
	for _, entity in pairs(core.luaentities) do
		if entity.name == VILLAGER and entity.object and entity.object:get_pos() then
			local pos = entity.object:get_pos()
			if math.abs(pos.x - CENTER.x) <= RADIUS + 20 and math.abs(pos.z - CENTER.z) <= RADIUS + 20 then
				table.insert(list, entity)
			end
		end
	end
	table.sort(list, function(a, b) return villager_id(a) < villager_id(b) end)
	return list
end

-- A cell near `base` a villager can stand in, not in `used`.
local function stand_near(base, used)
	local best, best_distance
	for dx = -3, 3 do for dz = -3, 3 do for dy = -1, 1 do
		local cell = {x = base.x + dx, y = base.y + dy, z = base.z + dz}
		local key = core.hash_node_position(cell)
		if not used[key] and common.is_standing_space(cell, true) then
			local distance = dx * dx + dz * dz + dy * dy * 4
			if distance > 0 and (not best_distance or distance < best_distance) then best, best_distance = cell, distance end
		end
	end end end
	if best then used[core.hash_node_position(best)] = true end
	return best
end

-- Stand up a villager that is sitting or eating, as seat.stand and meal.finish
-- do (they are not reachable from here), but where it is: it is about to be
-- moved. Left seated, seat.hold_seat would put it back in its chair after the
-- teleport, and the reduced collision box would stay.
local LEGS = {"leg.right", "leg.left"}
local function release_seat(self)
	if self._villages_seated then
		for _, bone in ipairs(LEGS) do self.object:set_bone_override(bone, nil) end
		if self._villages_seat_box then
			self.collisionbox = self._villages_seat_box
			self.object:set_properties({collisionbox = self.collisionbox})
		end
	end
	local meal = self._villages_meal
	if meal and meal.object then meal.object:remove() end
	self._villages_meal, self._villages_seated_at = nil, nil
	self._villages_seated, self._villages_seat, self._villages_seat_box = nil, nil, nil
	self._villages_seat_exit, self._villages_seat_chair = nil, nil
	self._villages_seat_searched_at, self._villages_seat_unreachable = nil, nil
end

local function reset_villager(self)
	for _, field in pairs(ROUTE_FIELDS) do self[field] = nil end
	self.state, self.waypoints, self.current_target, self.callback_arrived = "stand", nil, nil, nil
	self._target, self._pf_last_failed, self.order = nil, nil, nil
	self._villages_blocked_door, self._villages_door_entry = nil, nil
	self._villages_skip_tavern = nil
	self.object:set_velocity(vector.zero())
end

local function summarize(list)
	local beds, jobs, keepers = 0, 0, 0
	for _, v in ipairs(list) do
		if v._bed then beds = beds + 1 end
		if v._jobsite then jobs = jobs + 1 end
		if v._villages_keeper then keepers = keepers + 1 end
	end
	return {villagers = #list, beds = beds, jobsites = jobs, keepers = keepers}
end

----------------------------------------------------------------------
-- The driver: one coroutine, resumed every server step
----------------------------------------------------------------------

local driver
local elapsed_real = 0
local function wait(seconds)
	local until_time = elapsed_real + seconds
	while elapsed_real < until_time do coroutine.yield() end
end

local function run_round(list, stage, variant, round)
	holiday = stage.holiday and true or false
	silence_engine = variant == "B"
	round_info = {stage = stage, variant = variant, round = round, village = LABEL}
	closed_this_round = 0
	trips = {}
	local living = {}
	for _, v in ipairs(list) do
		if v.object:get_pos() and (v.health or 1) > 0 and v.state ~= "die" then table.insert(living, v) end
	end
	list = living
	local was_seated = false
	for _, v in ipairs(list) do
		if v._villages_seated or v._villages_meal then was_seated = true end
		release_seat(v)
	end
	-- The chairs and plates they held are released when the hold runs out
	-- (seat.lua's HOLD_SECONDS is 10).
	if was_seated then wait(11) end
	for _, v in ipairs(list) do reset_villager(v) end
	core.set_timeofday(stage.tod)
	-- Start each villager beside another one's home (to go to work) or
	-- workplace (to go anywhere else), a different one each round.
	local used = {}
	round_info.origins = {}
	for index, v in ipairs(list) do
		local source = list[(index + round * 3) % #list + 1]
		local base = (stage.name == "work" and source._bed) or source._jobsite or source._bed
		local cell = base and stand_near(base, used)
		if cell then
			v.object:set_pos({x = cell.x, y = cell.y - 0.45, z = cell.z})
			round_info.origins[villager_id(v)] = vec(cell)
		end
	end
	local began = elapsed_real
	wait(2)
	while elapsed_real - began < ROUND_LIMIT do
		wait(1)
		if elapsed_real - began >= ROUND_MIN and next(trips) == nil then break end
	end
	local open = 0
	for _, trip in pairs(trips) do open = open + 1; close_trip(trip, "round_end") end
	emit({
		type = "round", village = LABEL, stage = stage.name, variant = variant, round = round,
		seconds = round1(elapsed_real - began), trips_closed = closed_this_round, open_at_end = open,
	})
	log(string.format("round %s %s #%d: %d trips, %d still open at the end", stage.name, variant, round, closed_this_round, open))
end

local function run_trials(list)
	local wanted = {}
	for name in setting("stages", "home,work,tavern,church,bell,holiday_tavern"):gmatch("[^,]+") do wanted[name] = true end
	for _, stage in ipairs(STAGES) do
		if wanted[stage.name] then
			-- Variant B (engine silenced) meant something while navigation.lua asked
			-- the engine first; since #165 it would repeat A.
			local variants = {"A"}
			for _, variant in ipairs(variants) do
				for round = 1, ROUNDS do run_round(list, stage, variant, round) end
			end
		end
	end
end

-- Natural days at DAY_SPEED, observed only: a normal day, then a holiday.
local function run_days(list)
	for _, day in ipairs({{holiday = false}, {holiday = true}}) do
		holiday = day.holiday
		silence_engine = false
		round_info = {stage = {name = day.holiday and "holiday_day" or "day"}, variant = "A", round = 1, village = LABEL}
		for _, v in ipairs(list) do reset_villager(v) end
		core.set_timeofday(0.21)
		local began = elapsed_real
		-- A full day at DAY_SPEED, and the evening after it.
		local length = 86400 / DAY_SPEED -- real seconds per day
		while elapsed_real - began < length do wait(5) end
		for _, trip in pairs(trips) do close_trip(trip, "round_end") end
		log("day finished, holiday=" .. tostring(day.holiday))
	end
end

-- One villager, one start, one bed: the owner of the bed at the spot's bed is
-- teleported to its start in the evening and left to walk home. Every quarter
-- second it logs `[lv_trips] spot t=... ` with position, velocity, state, the
-- follower's current waypoint, the waypoints left and the planned final cell,
-- until the trip ends (150 s at most). The trip is recorded like any other.
local function parse_spot()
	local spec = setting("spot", "")
	local a, b, c, d, e, f = spec:match("^(-?[%d.]+),(-?[%d.]+),(-?[%d.]+);(-?[%d.]+),(-?[%d.]+),(-?[%d.]+)$")
	if not a then return nil end
	return {x = tonumber(a), y = tonumber(b), z = tonumber(c)}, {x = tonumber(d), y = tonumber(e), z = tonumber(f)}
end

local function run_spot(list)
	local start, bed = parse_spot()
	if not start then error("lv_trips_spot must be sx,sy,sz;bx,by,bz") end
	-- The beds in the village, to choose a spot's bed from.
	for _, v in ipairs(list) do
		core.log("action", string.format("[lv_trips] villager %s bed=%s jobsite=%s", villager_id(v),
			v._bed and core.pos_to_string(v._bed) or "-", v._jobsite and core.pos_to_string(v._jobsite) or "-"))
	end
	local owner
	for _, v in ipairs(list) do
		if v._bed and v._bed.x == bed.x and v._bed.y == bed.y and v._bed.z == bed.z then owner = v end
	end
	if not owner then error("no villager owns the bed at " .. core.pos_to_string(bed)) end
	-- The stage is the first of lv_trips_stages that names one (home by default).
	local stage, problem = dofile(modpath .. "/stages.lua")(setting("stages", ""), STAGES)
	if not stage then error("lv_trips_stages: " .. problem) end
	holiday = stage.holiday and true or false
	silence_engine = false
	round_info = {stage = stage, variant = "A", round = 1, village = LABEL}
	trips = {}
	spot_owner = owner
	release_seat(owner)
	reset_villager(owner)
	-- A sleeper wakes on its next step and is put back at the bed exit; let it, so
	-- the teleport below is the last word.
	local woke_by = elapsed_real + 5
	while owner._villages_sleeping and elapsed_real < woke_by do coroutine.yield() end
	core.set_timeofday(stage.tod)
	-- --build FILE: a Lua file that edits the clone's map (a test staircase) first.
	local build = io.open(modpath .. "/build.lua", "r")
	if build then build:close(); dofile(modpath .. "/build.lua"); wait(1) end
	owner.object:set_pos(start)
	-- --goto: walk to this position instead of what the schedule says.
	local gx, gy, gz = setting("goto", ""):match("^(-?[%d.]+);(-?[%d.]+);(-?[%d.]+)$")
	if gx then
		wait(1)
		local goal = {x = tonumber(gx), y = tonumber(gy), z = tonumber(gz)}
		local started = owner:gopath(goal, nil, true)
		-- The schedule can have a trip of its own under way (a bed trip at the home hour):
		-- say so when the walk is not to the goal.
		wait(1)
		local final = owner._villages_follow and owner._villages_follow.final
		if not final or vector.distance(final, goal) > 3 then
			core.log("warning", string.format("[lv_trips] --goto %s is not being walked (gopath returned %s, walking to %s)",
				core.pos_to_string(goal), tostring(started), final and core.pos_to_string(final) or "nowhere"))
		end
	end
	local began = elapsed_real
	if FAR.secs > 0 then FAR.until_us = core.get_us_time() + FAR.secs * 1e6 end
	local last_logged = -1
	local idle_since
	local function snapshot()
		local pos, v = owner.object:get_pos(), owner.object:get_velocity() or {x = 0, y = 0, z = 0}
		local follow = owner._villages_follow
		local route = route_snapshot(owner)
		core.log("action", string.format(
			"[lv_trips] spot t=%.2f pos=(%.2f,%.2f,%.2f) bed_dist=%.1f job_dist=%.1f prof=%s child=%s tod=%.3f weather=%s v=(%.2f,%.2f,%.2f) state=%s order=%s route=%s target=%s wp_left=%d follow=%s final=%s",
			elapsed_real - began, pos.x, pos.y, pos.z,
			owner._bed and vector.distance(pos, owner._bed) or -1,
			owner._jobsite and vector.distance(pos, owner._jobsite) or -1,
			tostring(owner._profession), tostring(owner.child), core.get_timeofday(),
			tostring(mcl_weather and mcl_weather.get_weather and mcl_weather.get_weather()),
			v.x, v.y, v.z, tostring(owner.state), tostring(owner.order),
			route and (route.status .. "/" .. tostring(route.reason)) or "-",
			owner.current_target and owner.current_target.pos and core.pos_to_string(owner.current_target.pos, 1) or "-",
			owner.waypoints and #owner.waypoints or 0, tostring(follow ~= nil),
			follow and follow.final and core.pos_to_string(follow.final, 1) or "-"))
	end
	while elapsed_real - began < ROUND_LIMIT do
		coroutine.yield()
		if elapsed_real - last_logged >= 0.25 then last_logged = elapsed_real; snapshot() end
		-- Keep watching 20 s after the last trip ends: a villager that arrives and is
		-- then sent away again (#216) shows up as a new trip.
		if next(trips) ~= nil then idle_since = nil
		elseif elapsed_real - began > 5 then
			idle_since = idle_since or elapsed_real
			if elapsed_real - idle_since > 20 then break end
		end
	end
	for _, trip in pairs(trips) do close_trip(trip, "round_end") end
	snapshot()
end

local function finish()
	emit({type = "done", village = LABEL})
	out:close()
	local done = io.open(core.get_worldpath() .. "/lv_trips.done", "w")
	if done then done:write("done\n") done:close() end
	core.request_shutdown("lv_trips finished", false, 0)
end

local function parse_center()
	local x, y, z = (setting("center", "0,0,0")):match("^(-?[%d.]+),(-?[%d.]+),(-?[%d.]+)$")
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end
CENTER = parse_center()

local function main()
	local minp = {x = CENTER.x - RADIUS, y = CENTER.y - 40, z = CENTER.z - RADIUS}
	local maxp = {x = CENTER.x + RADIUS, y = CENTER.y + 40, z = CENTER.z + RADIUS}
	local emerged = false
	core.emerge_area(minp, maxp, function(_, _, remaining) if remaining == 0 then emerged = true end end)
	while not emerged do coroutine.yield() end
	local function block_of(pos) return {x = math.floor(pos.x / 16), y = math.floor(pos.y / 16), z = math.floor(pos.z / 16)} end
	local first, last = block_of(minp), block_of(maxp)
	for bx = first.x, last.x do for by = first.y, last.y do for bz = first.z, last.z do
		core.forceload_block({x = bx * 16, y = by * 16, z = bz * 16}, true)
	end end end
	wait(15)
	local list = villagers()
	local previous = -1
	while #list ~= previous do previous = #list; wait(10); list = villagers() end
	local summary = summarize(list)
	summary.type, summary.village, summary.mode, summary.center = "village", LABEL, MODE, CENTER
	emit(summary)
	log("village " .. core.write_json(summary))
	if #list > 0 then
		if MODE == "day" then run_days(list)
		elseif MODE == "spot" then run_spot(list)
		else run_trials(list) end
	end
	finish()
end

core.register_globalstep(function(dtime)
	elapsed_real = elapsed_real + dtime
	if not driver then
		-- Wait for the world to be up before starting.
		if elapsed_real < 3 then return end
		driver = coroutine.create(main)
	end
	if coroutine.status(driver) == "suspended" then
		local ok, err = coroutine.resume(driver)
		if not ok then
			core.log("error", "[lv_trips] driver failed: " .. tostring(err))
			emit({type = "error", message = tostring(err)})
			out:close()
			core.request_shutdown("lv_trips failed", false, 0)
			driver = nil
		end
	end
end)
