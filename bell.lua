-- Bell gathering on holidays (#127): in the Bell stage (#124) every adult
-- walks to the nearest village bell, as vanilla's old lunch gathering did
-- (mobs_mc/villager.lua go_to_town_bell), and drifts about it in short wander
-- legs (wander.lua) kept within a few nodes of it. Each takes its own spot
-- near the bell rather than piling onto one node. A villager with no bell
-- within reach, or none it can walk to, putters as on any other afternoon.
-- Keepers have no Bell stage, and the cleric's starts when the service ends
-- (common.lua).
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local BELL = "mcl_bells:bell"
-- How far from its bed a villager looks for a bell: its own village, as for
-- the tavern (tavern.lua).
local SEARCH_RADIUS = 48
local SEARCH_HEIGHT = 16
-- How often a villager with no bell looks again.
local SEARCH_SECONDS = 5
-- Villagers drift within this many nodes of the bell, and take a spot at least
-- SPOT_MIN from it and SPOT_SPACING from each other's.
local GATHER_RADIUS = 4
local SPOT_MIN = 1.5
local SPOT_SPACING = 1.5
local SPOT_TRIES = 24
-- Far enough out of the radius to be pushed there and walk back, rather than
-- standing on the edge of it.
local STRAY = 2
-- A reserved spot lapses unless its villager renews it, as a standing place
-- does at the church (church.lua).
local HOLD_SECONDS = 10
-- A villager that cannot get to the bell in this long passes it over for
-- UNREACHABLE_SECONDS, the rest of the 3 hour stage at 100 s of game time per
-- in-game hour. The walk may start anywhere in the village.
local WALK_BASE = 40
local WALK_PER_NODE = 2
local WALK_MAX = 300
local UNREACHABLE_SECONDS = 200
local FIELDS = {"_villages_bell", "_villages_bell_skipped", "_villages_bell_checked", "_villages_wander_anchor"}

local spots = {}

local function key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function now()
	return core.get_gametime()
end

-- Where villagers stand about a bell, which hangs from its frame: the floor
-- below it, found as vanilla's get_ground_below_floating_object does, so the
-- cell is the one above that floor.
local function center_of(bell)
	for drop = 1, SEARCH_HEIGHT do
		local node = core.get_node_or_nil({x = bell.x, y = bell.y - drop, z = bell.z})
		if not node then break end
		if node.name ~= "air" then return {x = bell.x, y = bell.y - drop + 1, z = bell.z} end
	end
	return {x = bell.x, y = bell.y, z = bell.z}
end

local function skipped(self, bell)
	local until_time = self._villages_bell_skipped and self._villages_bell_skipped[key(bell)]
	return until_time and until_time > now()
end

local function skip(self, bell, why)
	core.log("action", string.format("[living_villages] villager %s gave up the bell at (%d,%d,%d): %s",
		tostring(self._id), bell.x, bell.y, bell.z, why))
	self._villages_bell_skipped = self._villages_bell_skipped or {}
	self._villages_bell_skipped[key(bell)] = now() + UNREACHABLE_SECONDS
end

local function nearest_bell(self, origin)
	local sites = core.find_nodes_in_area(
		{x = origin.x - SEARCH_RADIUS, y = origin.y - SEARCH_HEIGHT, z = origin.z - SEARCH_RADIUS},
		{x = origin.x + SEARCH_RADIUS, y = origin.y + SEARCH_HEIGHT, z = origin.z + SEARCH_RADIUS},
		{BELL})
	local best, best_distance
	for _, site in ipairs(sites) do
		local distance = vector.distance(origin, site)
		if distance <= SEARCH_RADIUS and not skipped(self, site) and (not best or distance < best_distance) then
			best, best_distance = site, distance
		end
	end
	return best
end

local function held_near(cell, id)
	for held_key, hold in pairs(spots) do
		if hold.until_time < now() then
			spots[held_key] = nil
		elseif hold.id ~= id then
			local dx, dz = hold.cell.x - cell.x, hold.cell.z - cell.z
			if dx * dx + dz * dz < SPOT_SPACING * SPOT_SPACING and math.abs(hold.cell.y - cell.y) < 2 then
				return true
			end
		end
	end
	return false
end

-- A free place to stand about the bell, away from the other villagers' spots,
-- or nil if a few random tries find none. center is the cell below the bell.
local function pick_spot(center, id)
	for _ = 1, SPOT_TRIES do
		local angle = math.random() * 2 * math.pi
		local distance = SPOT_MIN + math.random() * (GATHER_RADIUS - SPOT_MIN)
		local x = math.floor(center.x + math.cos(angle) * distance + 0.5)
		local z = math.floor(center.z + math.sin(angle) * distance + 0.5)
		for y = center.y + 1, center.y - 1, -1 do
			local cell = {x = x, y = y, z = z}
			if common.is_standing_space(cell) then
				if not held_near(cell, id) then return cell end
				break
			end
		end
	end
end

local function hold_spot(self, bell)
	if bell.spot then spots[key(bell.spot)] = {id = self._id, cell = bell.spot, until_time = now() + HOLD_SECONDS} end
end

local function release_spot(bell)
	if not bell or not bell.spot then return end
	spots[key(bell.spot)] = nil
	bell.spot = nil
end

local function stop_walking(self)
	common.stop_walk(self)
end

-- The Bell stage for an adult with nothing else holding it.
local function gathering(self)
	return not self.child and self._id and not self.following and common.schedule_stage(nil, self) == "bell"
end

-- Let the gathering go: free the spot, and stop walking to it or about it.
local function leave(self)
	local bell = self._villages_bell
	if bell then
		release_spot(bell)
		stop_walking(self)
	end
	self._villages_bell = nil
	self._villages_wander_anchor = nil
end

local function distance_from(pos, center)
	local dx, dz = pos.x - center.x, pos.z - center.z
	return math.sqrt(dx * dx + dz * dz)
end

local function about_bell(pos, center, reach)
	return distance_from(pos, center) <= reach and math.abs(pos.y - center.y) <= 3
end

-- VoxeLibre's gopath answers nothing while it waits out an earlier failure
-- (ready_to_path, mcl_mobs/pathfinding.lua), so wait that out without asking.
-- Any other non-answer is a failure, and two give the bell up.
local function start_walk(self, bell, spot)
	if self.ready_to_path and not self:ready_to_path(true) then return true end
	if self:gopath(spot, function() end, true) then return true end
	bell.failures = (bell.failures or 0) + 1
	return bell.failures < 2
end

local function walk_limit(self, center)
	local pos = self.object:get_pos()
	local distance = pos and vector.distance(pos, center) or 0
	return math.min(WALK_MAX, WALK_BASE + WALK_PER_NODE * distance)
end

local function join(self, pos)
	local bell = self._villages_bell
	-- A bell that has been taken down is no longer a place to gather: look for
	-- another.
	local node = bell and core.get_node_or_nil(bell.pos)
	if bell and (skipped(self, bell.pos) or (node and node.name ~= BELL)) then
		leave(self)
		bell = nil
	end
	if not bell then
		if now() < (self._villages_bell_checked or 0) then return end
		local site = nearest_bell(self, self._bed or vector.round(pos))
		if not site then
			self._villages_bell_checked = now() + SEARCH_SECONDS
			return
		end
		local center = center_of(site)
		bell = {pos = site, center = center, since = now(), limit = walk_limit(self, center)}
		self._villages_bell = bell
	end
	local center = bell.center
	if self.state == "gowp" then
		-- On the way to its spot: keep it held, and let the walk finish.
		hold_spot(self, bell)
		if now() - bell.since > bell.limit then
			skip(self, bell.pos, "the walk took too long")
			leave(self)
		end
		return
	end
	-- Not walking: at the bell, or yet to start, or let down by a failed walk.
	local reach = bell.arrived and GATHER_RADIUS + STRAY or GATHER_RADIUS + 1
	if about_bell(pos, center, reach) then
		if not bell.arrived then
			bell.arrived, bell.failures = true, nil
			release_spot(bell)
		end
		self._villages_wander_anchor = {pos = center, radius = GATHER_RADIUS}
		return
	end
	-- Not there: pushed out of it, or not yet arrived. A villager that was
	-- pushed out has a walk of its own to time, not the one it began with.
	if bell.arrived then
		bell.since, bell.limit = now(), walk_limit(self, center)
	end
	bell.arrived = nil
	self._villages_wander_anchor = nil
	if now() - bell.since > bell.limit then
		skip(self, bell.pos, "the walk took too long")
		return leave(self)
	end
	if not bell.spot then
		bell.spot = pick_spot(center, self._id)
		if not bell.spot then
			-- No room found this time: try again next tick.
			return
		end
	end
	hold_spot(self, bell)
	if not start_walk(self, bell, bell.spot) then
		skip(self, bell.pos, "no route")
		return leave(self)
	end
end

local function trading(self)
	return self._trading_players and next(self._trading_players) ~= nil
end

local function install(def)
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_staticdata = def.get_staticdata
	local original_die = def.on_die

	-- The gathering is this session's: a reloaded villager looks for the bell
	-- again.
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		for _, field in ipairs(FIELDS) do self[field] = nil end
		return result
	end

	def.get_staticdata = function(self)
		local kept = {}
		for _, field in ipairs(FIELDS) do kept[field], self[field] = self[field], nil end
		local saved = original_staticdata(self)
		for _, field in ipairs(FIELDS) do self[field] = kept[field] end
		return saved
	end

	def.on_die = function(self, pos, cmi_cause)
		leave(self)
		return original_die(self, pos, cmi_cause)
	end

	def.do_custom = function(self, dtime)
		-- Before the other wrappers, so that a route they start as the stage
		-- ends (the tavern's) is not mistaken for the gathering's and stopped.
		if self._villages_bell and not gathering(self) then leave(self) end
		local result = original_custom(self, dtime)
		if result == false then return result end
		if not gathering(self) then return result end
		-- Someone is trading with it: vanilla has stopped it, and the time
		-- spent does not count against its walk.
		if trading(self) then
			local bell = self._villages_bell
			if bell then bell.since = bell.since + dtime end
			return result
		end
		local pos = self.object:get_pos()
		if pos then join(self, pos) end
		-- Vanilla's player scan turns jumping off near a player, which would
		-- leave a villager someone is watching unable to climb a step on its
		-- way (as at the church, church.lua).
		if self._villages_bell and self.state == "gowp" then self.jump = true end
		return result
	end
end

return {
	install = install,
	-- Exposed for tests.
	center_of = center_of,
	nearest_bell = nearest_bell,
	pick_spot = pick_spot,
	spots = spots,
	GATHER_RADIUS = GATHER_RADIUS,
}
