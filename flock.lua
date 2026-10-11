-- Shepherds herd sheep (#215). A shepherd with a claimed loom keeps up to
-- living_villages_flock_size ordinary mobs_mc:sheep, marked with its villager id in
-- _villages_shepherd (saved on the sheep; the shepherd re-finds them by scanning, so
-- an unload loses nothing, and without this mod the field is inert). While the
-- shepherd is out of doors in the putter and work stages its sheep follow it
-- loosely, running if they are far behind; in every other stage, and while it is
-- under a roof, they are left to graze where they stand, and come running when it
-- is out again. In the work stage the shepherd spends most of its time walking from
-- one grazing stop to the next about the village bell (or, with no bell, its loom),
-- with a minute at the loom now and then, which is where vanilla restocks its trades.
--
-- Vanilla would walk it back to the loom every few seconds (do_work in
-- mobs_mc/villager.lua), so while it herds get_activity answers "herd", which
-- vanilla does nothing about, as for the bell (#127). Cost: the shepherd does one
-- cheap tick a second, and only while a player is within mob range; a sheep drives
-- itself only while it is being pulled.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")

local SHEEP = "mobs_mc:sheep"
local SETTING = "living_villages_flock_size"
local DEFAULT_SIZE, MAX_SIZE = 5, 5
-- Sheep one village keeps in all, over the shepherds within VILLAGE_RADIUS of each other.
local VILLAGE_CAP = 15
local VILLAGE_RADIUS = 64
local SPAWN_GAP = 8
local SCAN_RADIUS = 64
local SCAN_SECONDS = 10
-- Seconds a lost claim or profession may last before the flock is let go: vanilla
-- re-validates a jobsite now and then, and a loom claim may be missing for a moment.
local GRACE = 30
local FOLLOW_STAGES = {putter = true, work = true}
-- A sheep farther than FAR (flat) from the shepherd is pulled to within NEAR of it,
-- running from RUN_DISTANCE out. It is pulled for PULL_SECONDS at a time, renewed
-- every shepherd tick, so a flock whose shepherd stops being loaded stops too.
local FAR, NEAR, RUN_DISTANCE = 6, 3.5, 10
local PULL_SECONDS = 2.5
local MAX_RISE = 8
-- A pulled sheep that moves less than STUCK_DISTANCE in STUCK_SECONDS is against
-- something: it rests that long, and vanilla's wander takes over.
local STUCK_SECONDS, STUCK_DISTANCE, REST_SECONDS = 2, 0.25, 6
-- Past LEASH from the shepherd, or stuck twice, a sheep no player is near is set down
-- beside it.
local LEASH, UNSEEN = 56, 24
-- The work stage: this many seconds out among the grazing stops, then this many at
-- the loom. A stop is a spot in the open, STOP_MIN_RADIUS or more from the centre,
-- where the shepherd lingers a while.
local HERD_OUT, HERD_LOOM = 240, 60
local AREA_RADIUS, AREA_MIN_RADIUS = 20, 8
local LOOM_RADIUS = 12
local STOP_MIN_RADIUS = 5
local STOP_TRIES = 20
local LINGER_MIN, LINGER_MAX, LINGER_RADIUS = 15, 40, 3
local ARRIVE = 2.5
local STOP_BASE, STOP_PER_NODE = 30, 3
local MAX_FAILURES = 3
-- Vanilla sends a villager home past 50 nodes from its bed (do_activity).
local BED_REACH = 46
local AREA_RETRY = 120
-- Solid within ROOF_HEIGHT above the shepherd's feet (past its own head) is a roof; a tree
-- canopy is higher. A change of roof must hold for ROOF_TICKS ticks to count.
local ROOF_HEIGHT = 4
local ROOF_TICKS = 2
-- Sheep made and not seen again are forgotten after this many game days (flock record).
local UNSEEN_DAYS = 5
-- Stops stay this far from the loom: vanilla drops a jobsite 100 away (RESETTLE_DISTANCE).
local LOOM_REACH = 90
local AREA_TTL = 600
-- How far ahead of a pulled sheep the ground is checked, every step.
local AHEAD = 1.0
local deaths = {}

local sessions = setmetatable({}, {__mode = "k"})
local states = setmetatable({}, {__mode = "k"})
-- Shepherd id -> {pos, count, seen}: who is keeping how many sheep, for the cap.
local registry = {}

local function flat(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

local function flock_size()
	local value = core.settings and tonumber(core.settings:get(SETTING))
	if value == nil then return DEFAULT_SIZE end
	return math.max(0, math.min(MAX_SIZE, math.floor(value)))
end

local function valid_sheep(ent)
	return ent.object and ent.object:get_pos() ~= nil
end

local function trading(self)
	return self._trading_players and next(self._trading_players) ~= nil
end

-- Something solid within ROOF_HEIGHT above: indoors, or under a tree.
local function roofed(pos)
	local x, y, z = math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5)
	for dy = 2, ROOF_HEIGHT do
		local node = core.get_node_or_nil({x = x, y = y + dy, z = z})
		local def = node and core.registered_nodes[node.name]
		if def and def.walkable then return true end
	end
	return false
end

-- An open place to stand between min_d and max_d of center, found by random tries.
local function find_spot(center, min_d, max_d, tries)
	for _ = 1, tries or 10 do
		local angle = math.random() * 2 * math.pi
		local distance = min_d + math.random() * (max_d - min_d)
		local x = math.floor(center.x + math.cos(angle) * distance + 0.5)
		local z = math.floor(center.z + math.sin(angle) * distance + 0.5)
		local top = math.floor(center.y + 0.5)
		for y = top + 3, top - 4, -1 do
			local cell = {x = x, y = y, z = z}
			if common.is_standing_space(cell) then
				if not roofed(cell) then return cell end
				break
			end
		end
	end
end

local function session_of(self)
	local session = sessions[self]
	if not session then
		session = {sheep = {}, clock = 0, tick = 0, scan_at = 0, spawn_at = 0}
		sessions[self] = session
	end
	return session
end

local function free(ent)
	ent._villages_shepherd = nil
	states[ent] = nil
end

local function scan(self, pos)
	local found = {}
	for _, obj in ipairs(core.get_objects_inside_radius(pos, SCAN_RADIUS)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == SHEEP and ent._villages_shepherd == self._id then
			table.insert(found, ent)
		end
	end
	return found
end

local function release(self, session, pos)
	for _, ent in ipairs(session.sheep) do free(ent) end
	session.sheep = {}
	self._villages_flock_total, self._villages_flock_unseen = nil, nil
	if pos then
		for _, ent in ipairs(scan(self, pos)) do free(ent) end
	end
	if self._id then registry[self._id] = nil end
end

-- Whether this is a shepherd that may keep a flock: an adult with a loom it holds.
local function keeps_flock(self)
	if self.child or self._profession ~= "shepherd" or not self._id then return false end
	local node = self._jobsite and core.get_node_or_nil(self._jobsite)
	return node ~= nil and node.name == "mcl_loom:loom" and common.has_claimed_jobsite(self)
end

local function refresh(self, session, pos, size)
	local kept = {}
	for _, ent in ipairs(session.sheep) do
		if valid_sheep(ent) and ent._villages_shepherd == self._id then table.insert(kept, ent) end
	end
	session.sheep = kept
	if session.clock >= session.scan_at then
		session.scan_at = session.clock + SCAN_SECONDS
		local known = {}
		for _, ent in ipairs(kept) do known[ent] = true end
		for _, ent in ipairs(scan(self, pos)) do
			if not known[ent] then table.insert(session.sheep, ent) end
		end
	end
	-- A flock grown past the setting (it was lowered, or sheep came back from an
	-- unload) lets its extras go.
	while #session.sheep > size do free(table.remove(session.sheep)) end
	-- The record of sheep made and not known dead, which the scan cannot see when a sheep
	-- is unloaded or stranded: replacements wait for it, so stranded sheep are not doubled.
	-- Deaths seen (on_die) lower it; so does five days without sighting the full record.
	local count = #session.sheep
	local total = self._villages_flock_total or 0
	local dead = deaths[self._id]
	if dead then total, deaths[self._id] = math.max(0, total - dead), nil end
	if count >= total then
		total, self._villages_flock_unseen = count, nil
	else
		local day = core.get_day_count and core.get_day_count() or 0
		self._villages_flock_unseen = self._villages_flock_unseen or day
		if day - self._villages_flock_unseen >= UNSEEN_DAYS then total, self._villages_flock_unseen = count, nil end
	end
	self._villages_flock_total = total
end

local function village_count(self, pos, own)
	local total = own
	local now = core.get_gametime()
	for id, entry in pairs(registry) do
		if now - entry.seen > 30 then
			registry[id] = nil
		elseif id ~= self._id and flat(entry.pos, pos) <= VILLAGE_RADIUS then
			total = total + entry.count
		end
	end
	return total
end

local function unseen(pos)
	for _, player in ipairs(core.get_connected_players()) do
		if vector.distance(player:get_pos(), pos) < UNSEEN then return false end
	end
	return true
end

local function pull_started(st, sheep_pos, shepherd, run)
	st.pull = {x = shepherd.x, y = shepherd.y, z = shepherd.z, left = PULL_SECONDS, run = run,
		check_at = 0, last = {x = sheep_pos.x, z = sheep_pos.z}}
end

local function solid_at(x, y, z)
	local node = core.get_node_or_nil({x = x, y = y, z = z})
	local def = node and core.registered_nodes[node.name]
	return def and def.walkable or false, def, node and node.name
end

-- Whether a wall, door or fence stands across the straight line from a to b at head
-- height: pulled sheep walk straight, so they are not pulled through one.
local function line_blocked(a, b)
	local head = math.floor(a.y + 0.5) + 1
	local length = flat(a, b)
	local steps = math.floor(length)
	for i = 1, steps do
		local t = i / (steps + 1)
		if solid_at(math.floor(a.x + (b.x - a.x) * t + 0.5), head, math.floor(a.z + (b.z - a.z) * t + 0.5)) then
			return true
		end
	end
	return false
end

-- Called each shepherd tick for each sheep: starts, renews, or gives up a pull.
local function steer(ent, shepherd_pos)
	local sheep_pos = ent.object:get_pos()
	local st = states[ent]
	if not st then st = {blocked = 0}; states[ent] = st end
	local distance = flat(sheep_pos, shepherd_pos)
	if math.abs(shepherd_pos.y - sheep_pos.y) > MAX_RISE then return end
	if distance > FAR and line_blocked(sheep_pos, shepherd_pos) then
		-- Left where it stands; vanilla's wander takes over.
		if st.pull then st.pull = nil; if ent.stand then ent:stand() end end
		return
	end
	if st.pull then
		local pull = st.pull
		pull.x, pull.y, pull.z, pull.left = shepherd_pos.x, shepherd_pos.y, shepherd_pos.z, PULL_SECONDS
		if distance > RUN_DISTANCE then pull.run = true end
	elseif distance > FAR and (st.rest_until or 0) <= core.get_gametime() then
		pull_started(st, sheep_pos, shepherd_pos, distance > RUN_DISTANCE)
	end
	-- Far behind, or stuck, and out of every player's sight: set down beside the shepherd.
	if distance > LEASH or (st.blocked >= 2 and distance > 16) then
		if unseen(sheep_pos) then
			local cell = find_spot(shepherd_pos, 2, 5)
			if cell then
				ent.object:set_pos({x = cell.x, y = cell.y - 0.49, z = cell.z})
				st.pull, st.blocked = nil, 0
			end
		end
	end
end

local function spawn_sheep(self, session, pos, size, count)
	if (self._villages_flock_total or count) >= size or session.clock < session.spawn_at then return end
	local day = core.get_day_count and core.get_day_count() or 0
	if self._villages_flock_day ~= day then
		self._villages_flock_day, self._villages_flock_made = day, 0
	end
	if (self._villages_flock_made or 0) >= size then return end
	if village_count(self, pos, count) >= VILLAGE_CAP then return end
	session.spawn_at = session.clock + SPAWN_GAP
	local cell = find_spot(pos, 2, 6)
	if not cell or not (mcl_mobs and mcl_mobs.spawn) then return end
	local obj = mcl_mobs.spawn({x = cell.x, y = cell.y, z = cell.z}, SHEEP)
	local ent = obj and obj.get_luaentity and obj:get_luaentity()
	if not ent then return end
	ent._villages_shepherd = self._id
	self._villages_flock_made = (self._villages_flock_made or 0) + 1
	table.insert(session.sheep, ent)
	self._villages_flock_total = (self._villages_flock_total or 0) + 1
	if registry[self._id] then registry[self._id].count = #session.sheep end
	core.log("action", string.format("[living_villages] shepherd %s has a new sheep at (%d,%d,%d) (%d of %d)",
		tostring(self._id), cell.x, cell.y, cell.z, #session.sheep, size))
end

local function in_open(herd)
	return not (herd and herd.phase == "loom")
end

-- Whether the flock is to follow right now.
local function follows(self, session, pos)
	if not FOLLOW_STAGES[common.schedule_stage(nil, self)] then return false end
	if trading(self) or self._villages_sleeping or not in_open(session.herd) then return false end
	-- Indoors or out changes only when the new reading has held for ROOF_TICKS ticks.
	local roof = roofed(pos)
	if roof == (session.roof or false) then
		session.roof_ticks = 0
	else
		session.roof_ticks = (session.roof_ticks or 0) + 1
		if session.roof_ticks >= ROOF_TICKS then session.roof, session.roof_ticks = roof, 0 end
	end
	return not session.roof
end

---------------------------------------------------------------------------
-- The work stage: grazing stops about the bell

local function herding_stage(self)
	return common.schedule_stage(nil, self) == "work"
end

-- Where the shepherd grazes: about the nearest bell, or else about its loom, with a
-- radius that keeps it within vanilla's 50 nodes of its bed and 100 of its loom
-- (validate_jobsite drops a jobsite farther than that). nil if there is no room.
local function find_area(self, bell)
	local bed = self._bed
	if not bed or not self._jobsite then return nil end
	local site = bell and bell.nearest_bell(self, bed)
	if site then
		local center = bell.center_of(site)
		local radius = math.min(AREA_RADIUS, BED_REACH - vector.distance(center, bed),
			LOOM_REACH - vector.distance(center, self._jobsite))
		if radius >= AREA_MIN_RADIUS then return {center = center, radius = radius} end
	end
	local radius = math.min(LOOM_RADIUS, BED_REACH - vector.distance(self._jobsite, bed))
	if radius >= STOP_MIN_RADIUS + 1 then return {center = vector.new(self._jobsite), radius = radius} end
end

local function pick_stop(area, pos)
	for _ = 1, STOP_TRIES do
		local cell = find_spot(area.center, STOP_MIN_RADIUS, area.radius, 1)
		if cell and flat(cell, pos) > STOP_MIN_RADIUS then return cell end
	end
end

local function end_herd(self, session)
	local herd = session.herd
	if not herd then return end
	if herd.walking and self.state == "gowp" then common.stop_walk(self) end
	if herd.anchor and self._villages_wander_anchor == herd.anchor then self._villages_wander_anchor = nil end
	session.herd = nil
end

local function begin_loom(self, session, herd)
	if herd.walking and self.state == "gowp" then common.stop_walk(self) end
	herd.walking, herd.stop, herd.linger_until = false, nil, nil
	if herd.anchor and self._villages_wander_anchor == herd.anchor then self._villages_wander_anchor = nil end
	herd.anchor = nil
	herd.phase, herd.since = "loom", session.clock
end

local function fail_stop(self, session, herd)
	herd.stop, herd.walking, herd.linger_until = nil, false, nil
	herd.failures = herd.failures + 1
	if herd.failures >= MAX_FAILURES then begin_loom(self, session, herd) end
end

local function herd_tick(self, session, pos, bell)
	if not herding_stage(self) or trading(self) then
		if session.herd and not herding_stage(self) then end_herd(self, session) end
		return
	end
	local now = session.clock
	local herd = session.herd
	if not herd then
		if now < (session.area_check or 0) then return end
		-- Looked up again every AREA_TTL seconds: a bell may be built or taken down.
		local area = session.area
		if area and now - area.at > AREA_TTL then area = nil end
		area = area or find_area(self, bell)
		if area then area.at = area.at or now end
		session.area = area
		if not area then
			session.area_check = now + AREA_RETRY
			return
		end
		herd = {phase = "out", since = now, area = area, failures = 0}
		session.herd = herd
		if self.order == "work" then self.order = nil end
	end
	if herd.phase == "loom" then
		if now - herd.since < HERD_LOOM then return end
		herd.phase, herd.since, herd.failures = "out", now, 0
		if self.order == "work" then self.order = nil end
	elseif now - herd.since > HERD_OUT then
		return begin_loom(self, session, herd)
	end
	if self.state == "gowp" and not herd.walking then return end
	if herd.stop then
		if self.state == "gowp" then
			if now - herd.started > herd.limit then
				common.stop_walk(self)
				fail_stop(self, session, herd)
			end
			return
		end
		herd.walking = false
		if flat(pos, herd.stop) > ARRIVE then
			fail_stop(self, session, herd)
			if herd.phase ~= "out" then return end
		else
			herd.linger_until = herd.linger_until or now + LINGER_MIN + math.random() * (LINGER_MAX - LINGER_MIN)
			if now < herd.linger_until then
				herd.anchor = herd.anchor or {pos = herd.stop, radius = LINGER_RADIUS}
				self._villages_wander_anchor = herd.anchor
				return
			end
			herd.stop, herd.linger_until, herd.anchor = nil, nil, nil
			self._villages_wander_anchor = nil
		end
	end
	local stop = pick_stop(herd.area, pos)
	if not stop then
		herd.failures = herd.failures + 1
		if herd.failures >= MAX_FAILURES then begin_loom(self, session, herd) end
		return
	end
	if self.ready_to_path and not self:ready_to_path(true) then return end
	if self:gopath(stop, function() end, true) then
		herd.stop, herd.started, herd.walking = stop, now, true
		herd.limit = STOP_BASE + STOP_PER_NODE * flat(pos, stop)
		if herd.anchor and self._villages_wander_anchor == herd.anchor then self._villages_wander_anchor = nil end
		herd.anchor = nil
	else
		herd.failures = herd.failures + 1
		if herd.failures >= MAX_FAILURES then begin_loom(self, session, herd) end
	end
end

---------------------------------------------------------------------------

local function tick(self, session, bell)
	local pos = self.object:get_pos()
	if not pos then return end
	local size = flock_size()
	if size == 0 or not keeps_flock(self) then
		session.invalid = session.invalid or session.clock
		if session.herd then end_herd(self, session) end
		if size == 0 or session.clock - session.invalid >= GRACE then
			if not session.released then release(self, session, pos) end
			session.released = true
		end
		return
	end
	session.invalid, session.released = nil, nil
	-- No player near: the villager and its sheep are frozen anyway (mcl_mobs).
	if self.player_in_active_range and not self:player_in_active_range() then return end
	refresh(self, session, pos, size)
	local count = #session.sheep
	registry[self._id] = {pos = pos, count = count, seen = core.get_gametime()}
	if follows(self, session, pos) then
		for _, ent in ipairs(session.sheep) do steer(ent, pos) end
		spawn_sheep(self, session, pos, size, count)
	end
	herd_tick(self, session, pos, bell)
end

local function install_shepherd(def, bell)
	local original_custom = def.do_custom
	local original_die = def.on_die

	def.on_die = function(self, pos, cmi_cause)
		local session = sessions[self]
		if session then
			end_herd(self, session)
			release(self, session, self.object:get_pos())
		end
		return original_die(self, pos, cmi_cause)
	end

	def.do_custom = function(self, dtime)
		local session = sessions[self]
		if not session and self._profession ~= "shepherd" then return original_custom(self, dtime) end
		session = session or session_of(self)
		-- Before the other wrappers, as for the bell (bell.lua): a route they start as the
		-- stage ends is not mistaken for ours and stopped.
		if session.herd and not herding_stage(self) then end_herd(self, session) end
		local result = original_custom(self, dtime)
		if result == false then return result end
		session.clock = session.clock + dtime
		session.tick = session.tick + dtime
		if session.tick >= 1 then
			session.tick = 0
			tick(self, session, bell)
		end
		return result
	end
end

---------------------------------------------------------------------------
-- The sheep: while pulled, walk at the shepherd; otherwise vanilla's.

local function stop_pull(self, st)
	st.pull = nil
	self:stand()
end

local function rest(self, st)
	st.rest_until = core.get_gametime() + REST_SECONDS
	st.blocked = st.blocked + 1
	stop_pull(self, st)
end

local function is_liquid(def)
	return def ~= nil and ((def.liquidtype or "none") ~= "none" or (def.groups ~= nil and (def.groups.water or def.groups.lava)) and true or false)
end

-- Whether the ground a pulled sheep is about to step onto, AHEAD nodes on toward (dx, dz)
-- (a unit vector), is a drop of two or more, water, lava, or what vanilla calls
-- dangerous (is_node_dangerous, is_node_waterhazard in mcl_mobs/movement.lua).
local function unsafe_ahead(self, pos, dx, dz)
	local x, z = math.floor(pos.x + dx * AHEAD + 0.5), math.floor(pos.z + dz * AHEAD + 0.5)
	local body = math.floor(pos.y + 0.5)
	local stand
	if solid_at(x, body, z) then stand = body + 1
	elseif solid_at(x, body - 1, z) then stand = body
	elseif solid_at(x, body - 2, z) then stand = body - 1
	else return "drop" end
	for _, y in ipairs({stand - 1, stand, stand + 1}) do
		local node = core.get_node_or_nil({x = x, y = y, z = z})
		local def = node and core.registered_nodes[node.name]
		if is_liquid(def) then return "liquid" end
		if node and ((self.is_node_dangerous and self:is_node_dangerous(node.name))
			or (self.is_node_waterhazard and self:is_node_waterhazard(node.name))) then
			return "danger"
		end
	end
	return false
end

local function pull_step(self, st, dtime)
	local pull = st.pull
	local pos = self.object:get_pos()
	if not pos then return false end
	if self.following or (self.pause_timer or 0) > 0 or self.state == "die" or self.state == "runaway"
		or self.state == "eat" or not self._villages_shepherd then
		st.pull = nil
		return false
	end
	local dx, dz = pull.x - pos.x, pull.z - pos.z
	local distance = math.sqrt(dx * dx + dz * dz)
	pull.left = pull.left - dtime
	if distance <= NEAR then
		st.blocked = 0
		stop_pull(self, st)
		return true
	end
	if pull.left <= 0 then
		-- The shepherd has not renewed it: it is gone, or no longer wants the flock.
		stop_pull(self, st)
		return true
	end
	pull.check_at = pull.check_at - dtime
	if pull.check_at <= 0 then
		-- Not too often: a cliff check is a line of sight.
		pull.check_at = STUCK_SECONDS
		if self.is_at_cliff_or_danger and self:is_at_cliff_or_danger() then
			rest(self, st)
			return true
		end
		if flat(pos, pull.last) < STUCK_DISTANCE and pull.started then
			rest(self, st)
			return true
		end
		pull.last.x, pull.last.z, pull.started = pos.x, pos.z, true
	end
	if unsafe_ahead(self, pos, dx / distance, dz / distance) then
		rest(self, st)
		return true
	end
	self:turn_in_direction(dx, dz, 0)
	self.state = "walk"
	if pull.run then
		self:set_velocity(self.run_velocity or self.walk_velocity)
		self:set_animation("run")
	else
		self:set_velocity(self.walk_velocity)
		self:set_animation("walk")
	end
	return true
end

local function install_sheep(def)
	local original_custom = def.do_custom
	local original_die = def.on_die
	-- A death lowers its shepherd's record of sheep made (the shepherd may be unloaded, in
	-- which case five days without a sighting forgets it instead).
	def.on_die = function(self, pos, cmi_cause)
		local id = self._villages_shepherd
		if id then deaths[id] = (deaths[id] or 0) + 1 end
		if original_die then return original_die(self, pos, cmi_cause) end
	end
	def.do_custom = function(self, dtime)
		local result
		if original_custom then result = original_custom(self, dtime) end
		local st = states[self]
		if not st or not st.pull or result == false then return result end
		-- Skip do_states: its wander would turn the sheep off the shepherd.
		if pull_step(self, st, dtime) then return false end
		return result
	end
end

return {
	install = function(villager_def, sheep_def, bell)
		install_shepherd(villager_def, bell)
		if sheep_def then install_sheep(sheep_def) end
	end,
	-- common.activity_override: a shepherd out among its stops is not sent to the loom.
	activity_override = function(villager, stage)
		if stage ~= "work" then return nil end
		local session = sessions[villager]
		local herd = session and session.herd
		if herd and herd.phase == "out" then return "herd" end
	end,
	-- Exposed for tests.
	sessions = sessions, states = states, registry = registry,
	roofed = roofed, find_spot = find_spot,
	FAR = FAR, NEAR = NEAR, RUN_DISTANCE = RUN_DISTANCE, VILLAGE_CAP = VILLAGE_CAP,
	HERD_OUT = HERD_OUT, HERD_LOOM = HERD_LOOM, GRACE = GRACE, LEASH = LEASH,
}
