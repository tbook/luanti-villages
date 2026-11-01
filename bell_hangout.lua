-- Morning at the bell (#329): in the Putter stage some adults with nothing to do
-- walk to the nearest village bell, stand about it for a while in short anchored
-- wander legs (wander.lua, as the holiday gathering does, bell.lua), and leave.
-- It is well.lua's morning at the bell: the same roll, cap, stay and walk, with
-- the spots about the bell that bell.lua picks, so villagers spread about it as
-- they do at the gathering. A villager goes to the well or the bell on a given
-- morning, not both (common.lua's morning claim). Atmosphere only: nothing is
-- fetched or changed, and no node is added, so removing the mod leaves the world
-- as it was.
--
-- A bell is looked for within SEARCH_RADIUS of the villager's bed, and skipped
-- when none is in reach. A villager drifting about it may be pushed a few nodes
-- further, so it may be farther from its bed than vanilla's 50 nodes;
-- far_trips.lua hides the bed from vanilla's test while it has this errand.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local BELL = "mcl_bells:bell"

-- Bells are looked for this far from the villager's bed (bell.lua's gathering
-- looks 48 out; the morning's search is nearer).
local SEARCH_RADIUS = 42
local SEARCH_HEIGHT = 16
-- How often a villager that found no bell, or a full one, looks again.
local SEARCH_SECONDS = 10
-- Far enough out of the radius to be pushed there and walk back.
local STRAY = 2
-- A reserved spot or a place at the bell lapses unless its villager renews it
-- (bell.lua, well.lua).
local HOLD_SECONDS = 10
-- Villagers using one bell at once.
local CAP = 3
-- The share of villagers that go to a bell on a given morning.
local PROBABILITY = 0.4
-- How long one stays once there, in game seconds (as at the well).
local STAY_MIN = 25
local STAY_MAX = 50
local WALK_BASE = 40
local WALK_PER_NODE = 2
local WALK_MAX = 300
local UNREACHABLE_SECONDS = 600
local FIELDS = {
	"_villages_bell_hangout", "_villages_bell_hangout_skipped", "_villages_bell_hangout_checked",
	"_villages_wander_anchor",
}
-- _villages_bell_hangout_day and _villages_bell_hangout_going are saved with the
-- villager: a reloaded one does not roll again for the same day.

-- bell.lua, as installed: its spots and where villagers stand about a bell.
local gathering
local holds = {}

local function key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function now()
	return core.get_gametime()
end

local function enabled()
	return not core.settings or core.settings:get_bool("living_villages_bell_hangout", true)
end

-- Whether the bell is still there. One in a part of the map that is not loaded
-- is left alone, and not used.
local function standing(pos)
	local node = core.get_node_or_nil(pos)
	return node ~= nil and node.name == BELL
end

local function skipped(self, pos)
	local until_time = self._villages_bell_hangout_skipped and self._villages_bell_hangout_skipped[key(pos)]
	return until_time and until_time > now()
end

local function skip(self, pos, why)
	core.log("action", string.format("[living_villages] villager %s gave up the morning bell at (%d,%d,%d): %s",
		tostring(self._id), pos.x, pos.y, pos.z, why))
	self._villages_bell_hangout_skipped = self._villages_bell_hangout_skipped or {}
	self._villages_bell_hangout_skipped[key(pos)] = now() + UNREACHABLE_SECONDS
end

-- The villagers using a bell, other than id.
local function users(pos, id)
	local count, list = 0, holds[key(pos)]
	if not list then return 0 end
	for holder, until_time in pairs(list) do
		if until_time < now() then
			list[holder] = nil
		elseif holder ~= id then
			count = count + 1
		end
	end
	return count
end

local function occupy(pos, id)
	holds[key(pos)] = holds[key(pos)] or {}
	holds[key(pos)][id] = now() + HOLD_SECONDS
end

local function vacate(pos, id)
	if holds[key(pos)] then holds[key(pos)][id] = nil end
end

-- The nearest bell within reach of origin, one this villager has not given up
-- and that is not full.
local function nearest_bell(self, origin)
	local sites = core.find_nodes_in_area(
		{x = origin.x - SEARCH_RADIUS, y = origin.y - SEARCH_HEIGHT, z = origin.z - SEARCH_RADIUS},
		{x = origin.x + SEARCH_RADIUS, y = origin.y + SEARCH_HEIGHT, z = origin.z + SEARCH_RADIUS},
		{BELL})
	local best, best_distance
	for _, site in ipairs(sites) do
		local distance = vector.distance(origin, site)
		if distance <= SEARCH_RADIUS and (not best or distance < best_distance)
			and not skipped(self, site) and users(site, self._id) < CAP then
			best, best_distance = site, distance
		end
	end
	return best
end

local function hold_spot(self, hangout)
	if hangout.spot then
		gathering.spots[key(hangout.spot)] = {id = self._id, cell = hangout.spot, until_time = now() + HOLD_SECONDS}
	end
end

local function release_spot(hangout)
	if not hangout or not hangout.spot then return end
	gathering.spots[key(hangout.spot)] = nil
	hangout.spot = nil
end

-- Let the visit go: free the place and the spot, stop walking to it or about it.
local function leave(self, reason)
	local hangout = self._villages_bell_hangout
	if hangout then
		release_spot(hangout)
		vacate(hangout.pos, self._id)
		common.stop_walk(self)
		-- A route still being planned would start a walk to the old spot later.
		local walk = self._villages_goto_route
		if walk and walk.status == "planning" and hangout.goal and walk.goal
			and walk.goal.x == hangout.goal.x and walk.goal.y == hangout.goal.y and walk.goal.z == hangout.goal.z then
			self._villages_goto_route = nil
		end
		core.log("action", string.format("[living_villages] villager %s left the morning bell after %s s (%s)",
			tostring(self._id), hangout.arrived_at and (now() - hangout.arrived_at) or "-", reason or "ended"))
	end
	self._villages_bell_hangout = nil
	self._villages_wander_anchor = nil
end

-- The Putter stage for an adult with nothing else holding it.
local function free(self)
	return not self.child and self._id and not self.following and not self._villages_keeper
		and not self._villages_sleeping and common.schedule_stage(nil, self) == "putter"
end

-- Something else of this mod's has the villager on an errand of its own, the
-- well's included.
local function busy(self)
	return self._villages_well or self._villages_bell or self._villages_church or self._villages_seat
		or self._villages_tavern_target or self._villages_fish_session or self._villages_fish_target
		or self._villages_farm_target or self._villages_keeper_target
end

local function wants(self)
	local day = core.get_day_count and core.get_day_count() or 0
	if self._villages_bell_hangout_day ~= day then
		self._villages_bell_hangout_day = day
		self._villages_bell_hangout_going = math.random() < PROBABILITY
	end
	return self._villages_bell_hangout_going
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
local function start_walk(self, hangout, spot)
	if self.ready_to_path and not self:ready_to_path(true) then return true end
	hangout.goal = spot
	if self:gopath(spot, function() end, true) then return true end
	hangout.failures = (hangout.failures or 0) + 1
	return hangout.failures < 2
end

local function walk_limit(self, center)
	local pos = self.object:get_pos()
	local distance = pos and vector.distance(pos, center) or 0
	return math.min(WALK_MAX, WALK_BASE + WALK_PER_NODE * distance)
end

-- Done for the day: leave, and do not come back this morning.
local function finish(self)
	leave(self, "stay over")
	self._villages_bell_hangout_going = false
end

local function join(self, pos)
	local hangout = self._villages_bell_hangout
	if hangout and (skipped(self, hangout.pos) or not standing(hangout.pos)) then
		leave(self, "bell gone or passed over")
		hangout = nil
	end
	if not hangout then
		if not wants(self) or now() < (self._villages_bell_hangout_checked or 0) then return end
		-- Went to the well this morning instead (well.lua, #329).
		if common.morning_claimed_by_other(self, "bell") then return end
		-- A trip of someone else's, begun this tick or before.
		if self.state == "gowp" or busy(self) then return end
		local site = nearest_bell(self, self._bed or vector.round(pos))
		if not site then
			self._villages_bell_hangout_checked = now() + SEARCH_SECONDS
			return
		end
		local center = gathering.center_of(site)
		hangout = {pos = site, center = center, since = now(), limit = walk_limit(self, center)}
		self._villages_bell_hangout = hangout
		common.claim_morning(self, "bell")
		core.log("action", string.format("[living_villages] villager %s sets off for the morning bell at (%d,%d,%d) (day %s)",
			tostring(self._id), site.x, site.y, site.z, tostring(self._villages_bell_hangout_day)))
	end
	local center = hangout.center
	-- The stay is over wherever the villager has got to: not another walk back.
	if hangout.leave_at and now() >= hangout.leave_at then return finish(self) end
	occupy(hangout.pos, self._id)
	if self.state == "gowp" then
		hold_spot(self, hangout)
		if now() - hangout.since > hangout.limit then
			skip(self, hangout.pos, "the walk took too long")
			leave(self, "walk took too long")
		end
		return
	end
	local reach = hangout.arrived and gathering.GATHER_RADIUS + STRAY or gathering.GATHER_RADIUS + 1
	if about_bell(pos, center, reach) then
		if not hangout.arrived then
			hangout.arrived, hangout.failures = true, nil
			hangout.arrived_at = hangout.arrived_at or now()
			-- Set once: being pushed out and walking back does not extend the stay.
			hangout.leave_at = hangout.leave_at or now() + STAY_MIN + math.random() * (STAY_MAX - STAY_MIN)
			release_spot(hangout)
		end
		self._villages_wander_anchor = {pos = center, radius = gathering.GATHER_RADIUS}
		return
	end
	if hangout.arrived then
		hangout.since, hangout.limit = now(), walk_limit(self, center)
	end
	hangout.arrived = nil
	self._villages_wander_anchor = nil
	if now() - hangout.since > hangout.limit then
		skip(self, hangout.pos, "the walk took too long")
		return leave(self, "walk took too long")
	end
	if not hangout.spot then
		hangout.spot = gathering.pick_spot(center, self._id)
		if not hangout.spot then return end
	end
	hold_spot(self, hangout)
	if not start_walk(self, hangout, hangout.spot) then
		skip(self, hangout.pos, "no route")
		return leave(self, "no route")
	end
end

local function trading(self)
	return self._trading_players and next(self._trading_players) ~= nil
end

local function install(def, bell)
	gathering = bell
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_staticdata = def.get_staticdata
	local original_die = def.on_die

	-- The visit is this session's: a reloaded villager starts it over, without a new roll.
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
		leave(self, "died")
		return original_die(self, pos, cmi_cause)
	end

	def.do_custom = function(self, dtime)
		-- Before the other wrappers, so that a route they start as the stage
		-- ends is not mistaken for the visit's and stopped.
		if self._villages_bell_hangout and (not free(self) or not enabled()) then
			leave(self, "stage over or setting off")
		end
		local result = original_custom(self, dtime)
		if result == false then return result end
		if not enabled() or not free(self) then return result end
		-- Someone is trading with it: vanilla has stopped it, and the time
		-- spent does not count against its walk.
		if trading(self) then
			local hangout = self._villages_bell_hangout
			if hangout then hangout.since = hangout.since + dtime end
			return result
		end
		local pos = self.object:get_pos()
		if pos then join(self, pos) end
		-- Vanilla's player scan turns jumping off near a player (see bell.lua).
		if self._villages_bell_hangout and self.state == "gowp" then self.jump = true end
		return result
	end
end

return {
	install = install,
	-- Exposed for tests.
	nearest_bell = nearest_bell,
	holds = holds,
	CAP = CAP,
	SEARCH_RADIUS = SEARCH_RADIUS,
	STAY_MIN = STAY_MIN,
	STAY_MAX = STAY_MAX,
	PROBABILITY = PROBABILITY,
}
