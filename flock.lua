-- Shepherds herd sheep (#215). A shepherd with a claimed loom keeps up to
-- living_villages_flock_size ordinary mobs_mc:sheep, marked with its villager id in
-- _villages_shepherd (saved on the sheep; the shepherd re-finds them by scanning, so
-- an unload loses nothing, and without this mod the field is inert). While the
-- shepherd is out of doors in the putter and work stages its sheep follow it
-- loosely, running if they are far behind; in every other stage, and while it is
-- under a roof, they are left to graze where they stand, and come running when it
-- is out again. In the work stage the shepherd spends most of its time walking from
-- one grazing stop to the next about the village bell (or, with no bell, its loom),
-- through ordinary workdays. On the day before a holiday it works at the loom all
-- day; visits back there during grazing are for route failures or the end of work.
--
-- Vanilla would walk it back to the loom every few seconds (do_work in
-- mobs_mc/villager.lua), so while it herds get_activity answers "herd", which
-- vanilla does nothing about, as for the bell (#127). Cost: the shepherd does one
-- cheap tick a second, and only while a player is within mob range; a sheep drives
-- itself only while it is being pulled.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local cells = dofile(core.get_modpath("living_villages") .. "/cells.lua")

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
-- A stop is a spot in the open, STOP_MIN_RADIUS or more from the centre, where
-- the shepherd lingers a while.
local HERD_LOOM = 60 -- time at the loom, including after a periodic return
local HERD_LOOM_INTERVAL = 240
local HERD_LOOM_MAX = 180 -- do not stall the work loop forever on an unreachable loom
local AREA_RADIUS, AREA_MIN_RADIUS = 20, 8
-- In the work stage (#253) the shepherd searches outward for a green pasture, then drifts
-- between nearby pasture stops. The search starts 15 nodes from the bell (or loom) and is capped
-- by the range setting and the loom's 90-node bound. Each stop lasts 20-30 s.
local RANGE_SETTING, DEFAULT_RANGE = "living_villages_flock_range", 30
local FIELD_STEP_MIN, FIELD_STEP_MAX = 8, 12
local FIELD_LINGER_MIN, FIELD_LINGER_MAX = 20, 30
local PASTURE_MIN_RADIUS = 15
local PASTURE_RADIUS, PASTURE_BATCH, PASTURE_RETRY = 5, 16, 60
local PASTURE_TILE, PASTURE_MAX_SECONDS, PASTURE_MAX_CANDIDATES = 16, 30, 256
local pasture_cache = {}
local pasture_cache_count = 0
local tune = {field = true}
local navigation_api
-- The return margin: a shepherd out in the field goes back to the loom, and starts no new stop,
-- once the work stage ends within 1.5 walks home plus RETURN_SLACK real seconds (at least
-- RETURN_MIN, at most RETURN_MAX), so it is in the village when the tavern, home and sleep stages
-- begin (a trip home from 60-75 out is not one the planner always finds, #252). A herd is not
-- started in the last RETURN_MIN seconds at all. Game ticks go by time_speed (ticks per real
-- second = time_speed / 3.6; default 72).
local RETURN_SLACK, RETURN_MIN, RETURN_MAX, WALK_SPEED = 20, 60, 180, 1.2
local DEFAULT_TIME_SPEED = 72
local LOOM_RADIUS = 12
local STOP_MIN_RADIUS = 5
local STOP_TRIES = 20
local LINGER_MIN, LINGER_MAX, LINGER_RADIUS = 15, 40, 3
-- A walk ends on the route's final cell, which can be a node or two from the stop itself (the
-- stop was not standable, or the follower stops short): within this, or "arrived", is arrived.
local ARRIVE = 4
local STOP_BASE, STOP_PER_NODE = 30, 3
local MAX_FAILURES = 3
-- Vanilla sends a villager home past 50 nodes from its bed (do_activity), but far_trips.lua
-- (#216) hides the bed from that test in daylight while a villager has an errand, and a
-- herding shepherd (it has a claimed loom) always has: the bed bounds nothing here.
local AREA_RETRY = 30
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

local function flock_range()
	local value = core.settings and tonumber(core.settings:get(RANGE_SETTING))
	return math.max(0, math.min(60, value and math.floor(value) or DEFAULT_RANGE))
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
				-- mcl_mobs measures fall damage from old_y, the height it last stood
				-- still at: carried over a hill's drop it would hurt the sheep (#248).
				ent.old_y = cell.y - 0.49
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

-- Where the shepherd grazes: about the nearest bell, or else about its loom. The radius
-- keeps it within 100 nodes of its loom (validate_jobsite drops a jobsite farther than
-- that); the bed does not bound it (far_trips.lua, above). Returns the area, or nil and
-- the reason there is none.
local function find_area(self, bell)
	local loom, bed = self._jobsite, self._bed
	if not loom then return nil, "no loom" end
	local function room(center)
		local radius = LOOM_REACH - vector.distance(center, loom)
		return radius
	end
	local why
	local site = bell and bell.nearest_bell(self, bed or loom)
	if site then
		local center = bell.center_of(site)
		local radius = math.min(AREA_RADIUS, room(center))
		if radius >= AREA_MIN_RADIUS then
			return {center = center, radius = radius, bed_known = bed ~= nil, room = room(center)}
		end
		why = string.format("the bell at (%d,%d,%d) leaves radius %d", site.x, site.y, site.z, radius)
	else
		why = "no bell within reach"
	end
	local reach = room(loom)
	local radius = math.min(LOOM_RADIUS, reach)
	if radius >= STOP_MIN_RADIUS + 1 then
		return {center = vector.new(loom), radius = radius, room = reach, bed_known = bed ~= nil}
	end
	return nil, why .. ", and the loom leaves radius " .. radius
end

-- A far stop (over untouched terrain) is not on a tree canopy, and not on a ledge: at least two
-- of its four neighbours are places a villager can stand too (cells.lua).
local function solid_ground(cell)
	local floor = core.get_node_or_nil({x = cell.x, y = cell.y - 1, z = cell.z})
	if not floor or core.get_item_group(floor.name, "leaves") > 0 then return false end
	local open = 0
	for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
		if cells.can_stand({x = cell.x + d[1], y = cell.y, z = cell.z + d[2]}) then open = open + 1 end
	end
	return open >= 2
end

local function pick_stop(area, pos)
	for _ = 1, STOP_TRIES do
		local cell = find_spot(area.center, STOP_MIN_RADIUS, area.radius, 1)
		-- On the level of the centre (+-2): a roof, a terrace or a pit is often not reachable.
		if cell and flat(cell, pos) > STOP_MIN_RADIUS and math.abs(cell.y - area.center.y) <= 2 then
			return cell
		end
	end
end

local NATURAL_GROUND = {
	["mcl_core:dirt"] = true, ["mcl_core:dirt_with_grass"] = true,
	["mcl_core:coarse_dirt"] = true, ["mcl_core:podzol"] = true, ["mcl_core:mycelium"] = true,
}

local function box_loaded(minp, maxp)
	local function samples(a, b)
		local out = {}
		for block = math.floor(a / 16), math.floor(b / 16) do
			out[#out + 1] = math.max(a, math.min(b, block * 16 + 8))
		end
		return out
	end
	for _, x in ipairs(samples(minp.x, maxp.x)) do
		for _, y in ipairs(samples(minp.y, maxp.y)) do
			for _, z in ipairs(samples(minp.z, maxp.z)) do
				if not core.get_node_or_nil({x = x, y = y, z = z}) then return false end
			end
		end
	end
	return true
end

local function pasture_ground(cell)
	local now = core.get_gametime()
	local key = cell.x .. "," .. cell.y .. "," .. cell.z
	local cached = pasture_cache[key]
	if cached and now - cached.at < PASTURE_RETRY then return cached.ok end
	local function remember(ok)
		if not cached then
			if pasture_cache_count >= 2048 then pasture_cache, pasture_cache_count = {}, 0 end
			pasture_cache_count = pasture_cache_count + 1
		end
		pasture_cache[key] = {ok = ok, at = now}
	end
	local minp = {x = cell.x - PASTURE_RADIUS, y = cell.y - 2, z = cell.z - PASTURE_RADIUS}
	local maxp = {x = cell.x + PASTURE_RADIUS, y = cell.y + 2, z = cell.z + PASTURE_RADIUS}
	if not box_loaded(minp, maxp) then return false end
	local floor = core.get_node_or_nil({x = cell.x, y = cell.y - 1, z = cell.z})
	if not floor or floor.name ~= "mcl_core:dirt_with_grass" then return false end
	local found = core.find_nodes_in_area(minp, maxp,
		{"group:path", "group:material_stone", "group:material_sand", "group:material_wood",
			"group:building_block", "group:door", "mcl_core:grass_path", "mcl_farming:soil", "mcl_farming:soil_wet"})
	if found == nil then return false end
	for _, p in ipairs(found) do
		local node = core.get_node_or_nil(p)
		if not node then return false end
		if not NATURAL_GROUND[node.name] then
			remember(false)
			return false
		end
	end
	local grass = 0
	for dx = -PASTURE_RADIUS, PASTURE_RADIUS, 2 do
		for dz = -PASTURE_RADIUS, PASTURE_RADIUS, 2 do
			local p = {x = cell.x + dx, y = cell.y - 1, z = cell.z + dz}
			local node = core.get_node_or_nil(p)
			if not node then return false end
			if node.name == "mcl_core:dirt_with_grass"
				and cells.can_stand({x = p.x, y = cell.y, z = p.z}) then grass = grass + 1 end
		end
	end
	local ok = grass >= 5
	remember(ok)
	return ok
end

local function field_tiles(center, radius)
	local min_x, max_x = math.floor((center.x - radius) / PASTURE_TILE), math.floor((center.x + radius) / PASTURE_TILE)
	local min_z, max_z = math.floor((center.z - radius) / PASTURE_TILE), math.floor((center.z + radius) / PASTURE_TILE)
	local tiles = {}
	local function axis_gap(index, value)
		local low, high = index * PASTURE_TILE, (index + 1) * PASTURE_TILE - 1
		if value < low then return low - value end
		if value > high then return value - high end
		return 0
	end
	for ix = min_x, max_x do
		for iz = min_z, max_z do
			local dx, dz = axis_gap(ix, center.x), axis_gap(iz, center.z)
			local lower = math.sqrt(dx * dx + dz * dz)
			if lower <= radius then tiles[#tiles + 1] = {x = ix, z = iz, lower = lower} end
		end
	end
	table.sort(tiles, function(a, b)
		if a.lower == b.lower then
			if a.x == b.x then return a.z < b.z end
			return a.x < b.x
		end
		return a.lower < b.lower
	end)
	return tiles
end

-- Scan one 16x16 floor tile at a time, closest tile first. Candidate checks are sliced across
-- herd ticks; the 30s/256-candidate cap returns the best validated stop found so far.
local function pick_field(area, pos, herd)
	local now = core.get_gametime()
	if herd.pasture_retry_at and now < herd.pasture_retry_at then return nil, false end
	local max_d = math.min(area.room or area.radius, PASTURE_MIN_RADIUS + flock_range())
	local here = flat(pos, area.center)
	local drift = herd.pasture_started and here >= PASTURE_MIN_RADIUS - 3 and here <= max_d + 3
	local center = drift and pos or area.center
	local min_d, end_d = drift and FIELD_STEP_MIN or PASTURE_MIN_RADIUS, drift and FIELD_STEP_MAX or max_d
	local search = herd.pasture_search
	if not search or search.drift ~= drift or (drift and flat(pos, search.center) > 2) then
		local tiles = field_tiles(center, end_d)
		search = {drift = drift, center = vector.new(center), min_d = min_d, end_d = end_d,
			tiles = tiles, tile = 1, started = now, checked = 0}
		herd.pasture_search = search
	end
	if now - search.started >= PASTURE_MAX_SECONDS or search.checked >= PASTURE_MAX_CANDIDATES then
		herd.pasture_search = nil
		if search.best then herd.pasture_retry_at = nil else herd.pasture_retry_at = now + PASTURE_RETRY end
		return search.best, false
	end
	local tile = search.tiles[search.tile]
	if not tile then
		herd.pasture_search = nil
		if search.best then herd.pasture_retry_at = nil else herd.pasture_retry_at = now + PASTURE_RETRY end
		return search.best, false
	end
	if search.candidates == nil then
		local scan_center = search.center
		local minp = {x = math.max(math.floor(scan_center.x - search.end_d), tile.x * PASTURE_TILE),
			y = math.floor(area.center.y - 3), z = math.max(math.floor(scan_center.z - search.end_d), tile.z * PASTURE_TILE)}
		local maxp = {x = math.min(math.ceil(scan_center.x + search.end_d), (tile.x + 1) * PASTURE_TILE - 1),
			y = math.ceil(area.center.y + 2), z = math.min(math.ceil(scan_center.z + search.end_d), (tile.z + 1) * PASTURE_TILE - 1)}
		local grass = core.find_nodes_in_area(minp, maxp, {"mcl_core:dirt_with_grass"}) or {}
		local candidates = {}
		for _, floor in ipairs(grass) do
			local cell = {x = floor.x, y = floor.y + 1, z = floor.z}
			local distance = flat(cell, scan_center)
			if distance >= search.min_d and distance <= search.end_d and math.abs(cell.y - area.center.y) <= 2
				and flat(cell, area.center) >= PASTURE_MIN_RADIUS and flat(cell, area.center) <= max_d
				and flat(cell, pos) > STOP_MIN_RADIUS then
				candidates[#candidates + 1] = {cell = cell, distance = distance}
			end
		end
		table.sort(candidates, function(a, b) return a.distance < b.distance end)
		if search.best_distance then
			local closer = {}
			for _, candidate in ipairs(candidates) do
				if candidate.distance < search.best_distance then closer[#closer + 1] = candidate end
			end
			candidates = closer
		end
		local remaining = PASTURE_MAX_CANDIDATES - search.checked
		if #candidates > remaining then
			if remaining <= 0 then
				herd.pasture_search = nil
				if search.best then herd.pasture_retry_at = nil else herd.pasture_retry_at = now + PASTURE_RETRY end
				return search.best, false
			end
			for i = #candidates, remaining + 1, -1 do candidates[i] = nil end
			search.budget_cut = true
		end
		search.candidates, search.next = candidates, 1
	end
	local checked = 0
	while search.next <= #search.candidates and checked < PASTURE_BATCH do
		local candidate = search.candidates[search.next]
		local cell = candidate.cell
		search.next, search.checked, checked = search.next + 1, search.checked + 1, checked + 1
		if common.is_standing_space(cell) and not roofed(cell) and solid_ground(cell) and pasture_ground(cell) then
			if not search.best_distance or candidate.distance < search.best_distance then
				search.best, search.best_distance = cell, candidate.distance
			end
			search.candidates = nil
			search.tile = search.tile + 1
			local next_tile = search.tiles[search.tile]
			if not next_tile or next_tile.lower > search.best_distance then
				herd.pasture_search, herd.pasture_retry_at = nil, nil
				return search.best, false
			end
			return nil, true
		end
	end
	if search.next <= #search.candidates then return nil, true end
	search.candidates = nil
	search.tile = search.tile + 1
	if search.tiles[search.tile] and search.tiles[search.tile].lower <= (search.best_distance or end_d) then return nil, true end
	herd.pasture_search = nil
	if search.best then herd.pasture_retry_at = nil else herd.pasture_retry_at = now + PASTURE_RETRY end
	return search.best, false
end

local function cancel_herd_route(self, herd)
	local route = self._villages_goto_route
	local owned = route and herd.route_token and route.market_token == herd.route_token
	if owned and navigation_api and navigation_api.cancel_goto then
		navigation_api.cancel_goto(self, herd.route_token)
	elseif owned and herd.walking and self.state == "gowp" then
		common.stop_walk(self)
	end
	herd.walking = false
end

local function end_herd(self, session)
	local herd = session.herd
	if not herd then return end
	self._villages_herding = nil
	cancel_herd_route(self, herd)
	if herd.anchor and self._villages_wander_anchor == herd.anchor then self._villages_wander_anchor = nil end
	session.herd = nil
end

-- Whether the work stage ends within the return margin from pos (by the villager's own
-- timetable). With `starting` only the shortest margin counts (a herd about to begin).
local function winding_down(self, pos, starting)
	local seconds = RETURN_MIN
	local loom = self._jobsite
	if not starting and loom and pos then
		local speed = tonumber(self.walk_velocity) or WALK_SPEED
		seconds = math.max(RETURN_MIN, math.min(RETURN_MAX, 1.5 * flat(pos, loom) / speed + RETURN_SLACK))
	end
	local time_speed = core.settings and tonumber(core.settings:get("time_speed")) or DEFAULT_TIME_SPEED
	local tod = (core.get_timeofday() + seconds * time_speed / 3.6 / 24000) % 1
	return common.schedule_stage(tod, self) ~= "work"
end

local function begin_loom(self, session, herd)
	cancel_herd_route(self, herd)
	herd.walking, herd.stop, herd.linger_until, herd.field_stop = false, nil, nil, nil
	herd.pasture_search = nil
	if herd.anchor and self._villages_wander_anchor == herd.anchor then self._villages_wander_anchor = nil end
	herd.anchor = nil
	herd.phase, herd.since = "loom", session.clock
	herd.last_loom = session.clock
end

local function fail_stop(self, session, herd, why)
	local route = self._villages_goto_route
	local report = route and route.planner
	core.log("action", string.format("[living_villages] shepherd %s: grazing stop failed (%d): %s, route %s/%s, planner %s after %s nodes",
		tostring(self._id), herd.failures + 1, why or "?", route and tostring(route.status) or "-", route and tostring(route.reason) or "-",
		report and tostring(report.status) or "-", report and tostring(report.searched) or "-"))
	herd.stop, herd.walking, herd.linger_until = nil, false, nil
	herd.skip_far = herd.field_stop
	herd.failures = herd.failures + 1
	if herd.failures >= MAX_FAILURES then begin_loom(self, session, herd) end
end

local function herd_tick(self, session, pos, bell)
	if not herding_stage(self) or trading(self) then
		if session.herd and not herding_stage(self) then end_herd(self, session) end
		return
	end
	-- A loom day lets vanilla work the shepherd all day to restock its trades.
	if common.is_holiday(1) then
		if session.herd then end_herd(self, session) end
		return
	end
	local now = session.clock
	local herd = session.herd
	if not herd then
		if now < (session.area_check or 0) or winding_down(self, pos, true) then return end
		-- Looked up again every AREA_TTL seconds (a bell may be built or taken down) and when
		-- a bed turns up (it bounds the radius); a shepherd with none grazes without one.
		local area = session.area
		if area and (now - area.at > AREA_TTL or area.bed_known ~= (self._bed ~= nil)) then area = nil end
		local why
		if not area then area, why = find_area(self, bell) end
		if area then area.at = area.at or now end
		session.area = area
		if not area then
			session.area_check = now + AREA_RETRY
			-- Logged once per change of reason, not per attempt.
			if session.no_area_logged ~= why then
				session.no_area_logged = why
				core.log("action", string.format("[living_villages] shepherd %s has no grazing area: %s (bed %s, loom %s)",
					tostring(self._id), tostring(why), tostring(self._bed and core.pos_to_string(self._bed)),
					tostring(self._jobsite and core.pos_to_string(self._jobsite))))
			end
			return
		end
		session.no_area_logged = nil
		core.log("action", string.format("[living_villages] shepherd %s grazes about (%d,%d,%d), radius %d%s",
			tostring(self._id), area.center.x, area.center.y, area.center.z, area.radius,
			self._bed and "" or " (no bed yet)"))
		herd = {phase = "out", since = now, area = area, failures = 0}
		session.herd = herd
		if self.order == "work" then self.order = nil end
	end
	if winding_down(self, pos) then
		if herd.phase == "out" then
			local loom = self._jobsite
			core.log("action", string.format("[living_villages] shepherd %s heads for its loom at the end of the work stage, %s from it",
				tostring(self._id), loom and string.format("%.0f", flat(pos, loom)) or "?"))
			begin_loom(self, session, herd)
		end
		return
	end
	if herd.phase == "out" and now - (herd.last_loom or herd.since) >= HERD_LOOM_INTERVAL then
		core.log("action", string.format("[living_villages] shepherd %s returns to its loom for a rest", tostring(self._id)))
		begin_loom(self, session, herd)
		return
	end
	if herd.phase == "loom" then
		if now - herd.since < HERD_LOOM then return end
		if self._jobsite and flat(pos, self._jobsite) > 5 then
			if now - herd.since < HERD_LOOM_MAX then return end
			core.log("action", string.format("[living_villages] shepherd %s could not reach its loom for a periodic rest; resuming grazing",
				tostring(self._id)))
		end
		herd.phase, herd.since, herd.failures = "out", now, 0
		herd.last_loom = now
		if self.order == "work" then self.order = nil end
	end
	if self.state == "gowp" and not herd.walking then return end
	if herd.stop then
		if self.state == "gowp" then
			if now - herd.started > herd.limit then
				common.stop_walk(self)
				fail_stop(self, session, herd, "walk took too long")
			end
			return
		end
		-- The route queue (#162) plans a few milliseconds a step, and the villager stands in
		-- route status "planning" until its search is done: not a failed stop.
		local route = self._villages_goto_route
		if route and route.status == "planning" and now - herd.started <= herd.limit then return end
		herd.walking = false
		local arrived = route and route.status == "arrived" and flat(pos, herd.stop) <= 2 * ARRIVE
		if not arrived and flat(pos, herd.stop) > ARRIVE then
			fail_stop(self, session, herd, string.format("ended %.1f from the stop", flat(pos, herd.stop)))
			if herd.phase ~= "out" then return end
		else
			herd.failures = 0 -- only failures in a row count against the stops
			local lo, hi = LINGER_MIN, LINGER_MAX
			if herd.field_stop then lo, hi = FIELD_LINGER_MIN, FIELD_LINGER_MAX end
			herd.linger_until = herd.linger_until or now + lo + math.random() * (hi - lo)
			if now < herd.linger_until then
				herd.anchor = herd.anchor or {pos = vector.new(pos), radius = LINGER_RADIUS}
				self._villages_wander_anchor = herd.anchor
				return
			end
			herd.stop, herd.linger_until, herd.anchor = nil, nil, nil
			self._villages_wander_anchor = nil
		end
	end
	-- After a route fails, navigation.lua refuses every goto for its retry time (30 s), and
	-- each refusal would count against the stops: wait it out, then try another stop.
	local route = self._villages_goto_route
	if route and route.status == "retry" and route.retry_at and core.get_gametime() < route.retry_at then return end
	local field_search = tune.field and flock_range() > 0 and not herd.skip_far
	herd.skip_far = nil
	local stop, searching
	if field_search then stop, searching = pick_field(herd.area, pos, herd) end
	if searching then return end
	local field = field_search and stop ~= nil
	if not stop then
		if field_search and not herd.no_pasture_logged then
			herd.no_pasture_logged = true
			core.log("action", string.format("[living_villages] shepherd %s finds no green pasture within the bounded search about (%d,%d,%d); using the usual grazing stops",
				tostring(self._id), herd.area.center.x, herd.area.center.y, herd.area.center.z))
		end
		stop = pick_stop(herd.area, pos)
	end
	if not stop then
		if not herd.pick_logged then
			herd.pick_logged = true
			core.log("action", string.format("[living_villages] shepherd %s finds no open place to graze about (%d,%d,%d), radius %d",
				tostring(self._id), herd.area.center.x, herd.area.center.y, herd.area.center.z, herd.area.radius))
		end
		herd.failures = herd.failures + 1
		if herd.failures >= MAX_FAILURES then begin_loom(self, session, herd) end
		return
	end
	if self.ready_to_path and not self:ready_to_path(true) then return end
	herd.route_token = herd.route_token or {}
	if self:gopath(stop, function() end, true, herd.route_token) then
		herd.stop, herd.started, herd.walking = stop, now, true
		herd.field_stop = field
	if field then herd.pasture_started = true end
		if field then
			core.log("info", string.format("[living_villages] shepherd %s pasture stop: %.0f from the grazing centre, %.0f from the shepherd",
				tostring(self._id), flat(stop, herd.area.center), flat(pos, stop)))
		end
		herd.limit = STOP_BASE + STOP_PER_NODE * flat(pos, stop)
		if herd.anchor and self._villages_wander_anchor == herd.anchor then self._villages_wander_anchor = nil end
		herd.anchor = nil
	else
		herd.skip_far = field
		herd.failures = herd.failures + 1
		if herd.failures >= MAX_FAILURES then begin_loom(self, session, herd) end
	end
end

---------------------------------------------------------------------------

local function tick(self, session, bell)
	local pos = self.object:get_pos()
	if not pos then return end
	self._villages_herding = nil
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
	local herding = follows(self, session, pos)
	self._villages_herding = herding or nil
	if herding then
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

-- A flock sheep wandering by vanilla's rules: vanilla only looks for a drop as a stand
-- turns into a walk, one node ahead, and a walk never checks again, so a sheep left on a
-- platform (the pull rests at its edge) steps off it later (#255). Stand it instead.
local function stop_at_ledge(self)
	local v = self.object:get_velocity()
	-- Standing on ground reads about -0.9 (gravity each step); a fall is faster.
	if not v or v.y < -2.5 or v.y > 2.5 then return end
	-- Swimming, or not on the ground: water is not walkable, so every cell ahead would
	-- read as a drop and pin the sheep.
	local function def_of(name) return name and core.registered_nodes[name] end
	if is_liquid(def_of(self.standing_in)) then return end
	local on = def_of(self.standing_on)
	if self.standing_on and not (on and on.walkable) then return end
	local pos = self.object:get_pos()
	if not pos then return end
	-- The direction it is moving, not the one it faces: vanilla turns over several steps
	-- after it sets the velocity.
	local speed = math.sqrt(v.x * v.x + v.z * v.z)
	if speed < 0.1 then return end
	if unsafe_ahead(self, pos, v.x / speed, v.z / speed) == "drop" then
		self:stand()
	end
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
		if result ~= false and self._villages_shepherd and self.state == "walk"
			and not (st and st.pull) then
			stop_at_ledge(self)
		end
		if not st or not st.pull or result == false then return result end
		-- Skip do_states: its wander would turn the sheep off the shepherd.
		if pull_step(self, st, dtime) then return false end
		return result
	end
end

return {
	install = function(villager_def, sheep_def, bell, navigation)
		navigation_api = navigation
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
	-- One line for the Lookup Tool inspector (diagnostic.lua): why a shepherd does or does not graze.
	status = function(villager)
		if villager._profession ~= "shepherd" then return "not a shepherd" end
		if flock_size() == 0 then return "off (living_villages_flock_size = 0)" end
		local session = sessions[villager]
		if not session then return "not ticked yet" end
		local herd = session.herd
		local text = string.format("%d sheep (record %s)", #session.sheep, tostring(villager._villages_flock_total))
		if not keeps_flock(villager) then text = text .. ", no claimed loom" end
		if herd then
			text = text .. string.format(", grazing %s %ds about (%d,%d,%d) r%d", herd.phase, session.clock - herd.since,
				herd.area.center.x, herd.area.center.y, herd.area.center.z, herd.area.radius)
			if herd.stop then text = text .. string.format(", stop (%d,%d,%d)", herd.stop.x, herd.stop.y, herd.stop.z) end
			if herd.failures > 0 then text = text .. ", failed stops " .. herd.failures end
		elseif herding_stage(villager) then
			text = text .. (session.area == nil and ", no grazing area: " .. tostring(session.no_area_logged) .. " (retried every 30 s)" or ", not started")
		else
			text = text .. ", not the work stage"
		end
		return text
	end,
	-- Exposed for tests.
	sessions = sessions, states = states, registry = registry,
	roofed = roofed, find_spot = find_spot,
	FAR = FAR, NEAR = NEAR, RUN_DISTANCE = RUN_DISTANCE, VILLAGE_CAP = VILLAGE_CAP,
	tune = tune, HERD_LOOM = HERD_LOOM, GRACE = GRACE, LEASH = LEASH,
}
