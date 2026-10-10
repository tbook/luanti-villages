-- Morning at the well (#11): in the Putter stage some adults with nothing to do
-- walk to the village well, stand about it for a while in short anchored wander
-- legs (wander.lua, as at the bell, bell.lua), and leave. Atmosphere only:
-- nothing is fetched or changed, and no node is added, so removing the mod
-- leaves the world as it was.
--
-- A well is found by its shape, not by water alone, since a fisherman's pond
-- may hold a 2x2 patch of source (fisherman.lua): four water sources in a
-- square, nothing wet beside, below or above them, a solid wall or stair on
-- every side, and standing cells outside the wall ring on the level below the
-- water (the stock well's water sits on a plinth above the ground). Wells are
-- looked for once per area, not per tick: a scan of the surroundings of a
-- villager's bed is remembered for SCAN_SECONDS, and the wells found stay
-- cached and are checked again, cheaply, whenever one is used.
--
-- Who goes: any adult in the Putter stage, on ordinary days and holidays
-- alike, that is not a keeper, not busy (following a player, asleep, on a trip
-- of the church's, the bell's, the fisherman's or anyone else's) and that
-- rolls under PROBABILITY once that day. A thunderstorm and the night are not
-- the Putter stage (common.lua). At most CAP villagers use one well at a time;
-- a villager that finds it full tries again later. One that cannot get to a
-- well passes it over for UNREACHABLE_SECONDS, as at the church. Wells are
-- looked for within SEARCH_RADIUS of the bed, so that a villager drifting about
-- one stays inside the 50 nodes from its bed that vanilla tolerates
-- (far_trips.lua) and the walk needs no errand there.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local WATER = "mcl_core:water_source"

-- Wells are looked for this far from the villager's bed, and a villager's
-- drift about one adds GATHER_RADIUS to it.
local SEARCH_RADIUS = 44
-- A scan covers a grid cell of the map and what a villager standing anywhere in
-- it could reach: SEARCH_RADIUS plus half a cell. Vertically a well is within a
-- few nodes of the ground by the bed, so a cell and SCAN_Y more.
local GRID = 16
local SCAN_HALF = SEARCH_RADIUS + GRID / 2
local SCAN_Y = GRID / 2 + 8
-- A body of water this big is not scanned for wells: a village on an ocean
-- shore has a well on land, but not worth a pass over this many nodes.
local MAX_WATER = 20000
-- How long a scan stands before the area is looked at again. Short enough that
-- a well beyond what was loaded is found when it is.
local SCAN_SECONDS = 600
-- A well needs at least this many places to stand about it.
local MIN_SPOTS = 4

-- Spots to stand: between SPOT_MIN and SPOT_MAX from the water's center and
-- SPOT_SPACING from each other's. The stock well's ground cells are 2.9 and
-- more from the center, behind a 4x4 plinth and its steps.
local SPOT_MIN = 2.5
local SPOT_MAX = 4.5
local SPOT_SPACING = 1.5
local SPOT_TRIES = 24
local GATHER_RADIUS = 5
-- Far enough out of the radius to be pushed there and walk back.
local STRAY = 2
-- A reserved spot or a place at the well lapses unless its villager renews it
-- (bell.lua, church.lua).
local HOLD_SECONDS = 10
-- Villagers using one well at once.
local CAP = 3
-- The share of villagers that go to a well on a given morning.
local PROBABILITY = 0.4
-- How long one stays once there, in game seconds. The Putter stage is an hour
-- and a half of the game's day, about 150 s at 100 s to the hour.
local STAY_MIN = 25
local STAY_MAX = 50
-- How often a villager that found no well, or a full one, looks again.
local SEARCH_SECONDS = 10
local WALK_BASE = 40
local WALK_PER_NODE = 2
local WALK_MAX = 300
local UNREACHABLE_SECONDS = 600
local FIELDS = {
	"_villages_well", "_villages_well_skipped", "_villages_well_checked", "_villages_well_day",
	"_villages_well_going", "_villages_wander_anchor",
}

local wells = {}
local scans = {}
local holds = {}
local spots = {}

local function key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function now()
	return core.get_gametime()
end

local function enabled()
	return not core.settings or core.settings:get_bool("living_villages_well_hangout", true)
end

local function node_def(pos)
	local node = core.get_node_or_nil(pos)
	return node and core.registered_nodes[node.name], node
end

local function liquid(def)
	return def and def.liquidtype and def.liquidtype ~= "none"
end

-- A node a wall may be made of: something solid, and not wet.
local function solid(pos)
	local def = node_def(pos)
	return def ~= nil and def.walkable == true and not liquid(def)
end

local function dry(pos)
	local def = node_def(pos)
	return def ~= nil and not liquid(def)
end

-- Everything in a candidate's way of being a well: whether the 2x2 of source
-- with its lowest x and z at corner is walled in and standable around. Returns
-- the well or nil.
local function examine(corner)
	local x, y, z = corner.x, corner.y, corner.z
	for dx = 0, 1 do
		for dz = 0, 1 do
			-- Below solid and above dry: not the top of a deeper or taller body.
			if not solid({x = x + dx, y = y - 1, z = z + dz}) then return nil end
			if not dry({x = x + dx, y = y + 1, z = z + dz}) then return nil end
		end
	end
	for i = 0, 1 do
		for _, wall in ipairs({
			{x - 1, z + i}, {x + 2, z + i}, {x + i, z - 1}, {x + i, z + 2},
		}) do
			if not solid({x = wall[1], y = y, z = wall[2]}) then return nil end
		end
	end
	local well = {
		water = {x = x, y = y, z = z},
		center = {x = x + 0.5, y = y, z = z + 0.5},
		stand_y = y - 1,
	}
	well.key = key(well.water)
	-- The cells to stand in, a level below the water, outside the wall ring.
	-- Water level with the ground round it is a pond, not a well.
	local count = 0
	local reach = math.ceil(SPOT_MAX)
	for cx = math.floor(well.center.x) - reach, math.floor(well.center.x) + reach + 1 do
		for cz = math.floor(well.center.z) - reach, math.floor(well.center.z) + reach + 1 do
			local distance = math.sqrt((cx - well.center.x) ^ 2 + (cz - well.center.z) ^ 2)
			if distance >= SPOT_MIN and distance <= SPOT_MAX
				and common.is_standing_space({x = cx, y = well.stand_y, z = cz}) then
				count = count + 1
			end
		end
	end
	if count < MIN_SPOTS then return nil end
	return well
end

-- Looks for wells in the area a villager at origin could want one in.
local function scan(origin)
	local cx = math.floor(origin.x / GRID) * GRID + GRID / 2
	local cz = math.floor(origin.z / GRID) * GRID + GRID / 2
	local cy = math.floor(origin.y / GRID) * GRID + GRID / 2
	local grid = math.floor(origin.x / GRID) .. "," .. math.floor(origin.y / GRID) .. "," .. math.floor(origin.z / GRID)
	if (scans[grid] or 0) > now() then return end
	scans[grid] = now() + SCAN_SECONDS
	local sources = core.find_nodes_in_area(
		{x = cx - SCAN_HALF, y = cy - SCAN_Y, z = cz - SCAN_HALF},
		{x = cx + SCAN_HALF, y = cy + SCAN_Y, z = cz + SCAN_HALF}, {WATER})
	if #sources > MAX_WATER then
		core.log("action", string.format("[living_villages] no well scan near (%d,%d,%d): %d water sources",
			origin.x, origin.y, origin.z, #sources))
		return
	end
	local set = {}
	for _, pos in ipairs(sources) do set[key(pos)] = true end
	for _, pos in ipairs(sources) do
		if set[key({x = pos.x + 1, y = pos.y, z = pos.z})] and set[key({x = pos.x, y = pos.y, z = pos.z + 1})]
			and set[key({x = pos.x + 1, y = pos.y, z = pos.z + 1})] and not wells[key(pos)] then
			local well = examine(pos)
			if well then
				wells[well.key] = well
				core.log("action", string.format("[living_villages] well found at (%d,%d,%d)", pos.x, pos.y, pos.z))
			end
		end
	end
end

-- Whether the well is still there: its four sources are. A well in a part of
-- the map that is not loaded is left alone, and not used.
local function standing(well)
	for dx = 0, 1 do
		for dz = 0, 1 do
			local node = core.get_node_or_nil({x = well.water.x + dx, y = well.water.y, z = well.water.z + dz})
			if not node then return false end
			if node.name ~= WATER then
				wells[well.key] = nil
				return false
			end
		end
	end
	return true
end

local function skipped(self, well)
	local until_time = self._villages_well_skipped and self._villages_well_skipped[well.key]
	return until_time and until_time > now()
end

local function skip(self, well, why)
	core.log("action", string.format("[living_villages] villager %s gave up the well at (%d,%d,%d): %s",
		tostring(self._id), well.water.x, well.water.y, well.water.z, why))
	self._villages_well_skipped = self._villages_well_skipped or {}
	self._villages_well_skipped[well.key] = now() + UNREACHABLE_SECONDS
end

-- The villagers using a well, other than id.
local function users(well, id)
	local count, list = 0, holds[well.key]
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

local function occupy(well, id)
	holds[well.key] = holds[well.key] or {}
	holds[well.key][id] = now() + HOLD_SECONDS
end

local function vacate(well, id)
	if holds[well.key] then holds[well.key][id] = nil end
end

-- The nearest well within reach of origin, one this villager has not given up
-- and that is not full.
local function nearest_well(self, origin)
	scan(origin)
	local best, best_distance
	for _, well in pairs(wells) do
		local distance = vector.distance(origin, well.center)
		if distance <= SEARCH_RADIUS and (not best or distance < best_distance)
			and not skipped(self, well) and standing(well) and users(well, self._id) < CAP then
			best, best_distance = well, distance
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

-- A free place to stand about the well, on the level of the ground and away
-- from the other villagers' spots, or nil if a few random tries find none.
local function pick_spot(well, id)
	for _ = 1, SPOT_TRIES do
		local angle = math.random() * 2 * math.pi
		local distance = SPOT_MIN + math.random() * (SPOT_MAX - SPOT_MIN)
		local cell = {
			x = math.floor(well.center.x + math.cos(angle) * distance + 0.5),
			y = well.stand_y,
			z = math.floor(well.center.z + math.sin(angle) * distance + 0.5),
		}
		if common.is_standing_space(cell) and not held_near(cell, id) then return cell end
	end
end

local function hold_spot(self, state)
	if state.spot then spots[key(state.spot)] = {id = self._id, cell = state.spot, until_time = now() + HOLD_SECONDS} end
end

local function release_spot(state)
	if not state or not state.spot then return end
	spots[key(state.spot)] = nil
	state.spot = nil
end

-- Let the well go: free the place and the spot, stop walking to it or about it.
local function leave(self)
	local state = self._villages_well
	if state then
		release_spot(state)
		vacate(state.well, self._id)
		common.stop_walk(self)
	end
	self._villages_well = nil
	self._villages_wander_anchor = nil
end

-- The Putter stage for an adult with nothing else holding it.
local function free(self)
	return not self.child and self._id and not self.following and not self._villages_keeper
		and not self._villages_sleeping and common.schedule_stage(nil, self) == "putter"
end

-- Something else of this mod's has the villager on an errand of its own.
local function busy(self)
	return self._villages_bell or self._villages_church or self._villages_seat
		or self._villages_tavern_target or self._villages_fish_session or self._villages_fish_target
		or self._villages_farm_target or self._villages_keeper_target
end

local function wants(self)
	local day = core.get_day_count and core.get_day_count() or 0
	if self._villages_well_day ~= day then
		self._villages_well_day = day
		self._villages_well_going = math.random() < PROBABILITY
	end
	return self._villages_well_going
end

local function distance_from(pos, center)
	local dx, dz = pos.x - center.x, pos.z - center.z
	return math.sqrt(dx * dx + dz * dz)
end

local function about_well(pos, well, reach)
	return distance_from(pos, well.center) <= reach and math.abs(pos.y - well.center.y) <= 3
end

-- VoxeLibre's gopath answers nothing while it waits out an earlier failure
-- (ready_to_path, mcl_mobs/pathfinding.lua), so wait that out without asking.
-- Any other non-answer is a failure, and two give the well up.
local function start_walk(self, state, spot)
	if self.ready_to_path and not self:ready_to_path(true) then return true end
	if self:gopath(spot, function() end, true) then return true end
	state.failures = (state.failures or 0) + 1
	return state.failures < 2
end

local function walk_limit(self, center)
	local pos = self.object:get_pos()
	local distance = pos and vector.distance(pos, center) or 0
	return math.min(WALK_MAX, WALK_BASE + WALK_PER_NODE * distance)
end

-- Done for the day: leave, and do not come back this morning.
local function finish(self)
	leave(self)
	self._villages_well_going = false
end

local function join(self, pos)
	local state = self._villages_well
	if state and (skipped(self, state.well) or not standing(state.well)) then
		leave(self)
		state = nil
	end
	if not state then
		if not wants(self) or now() < (self._villages_well_checked or 0) then return end
		-- A trip of someone else's, begun this tick or before.
		if self.state == "gowp" or busy(self) then return end
		local well = nearest_well(self, self._bed or vector.round(pos))
		if not well then
			self._villages_well_checked = now() + SEARCH_SECONDS
			return
		end
		state = {well = well, since = now(), limit = walk_limit(self, well.center)}
		self._villages_well = state
	end
	local well = state.well
	-- The stay is over wherever the villager has got to: not another walk back.
	if state.leave_at and now() >= state.leave_at then return finish(self) end
	occupy(well, self._id)
	if self.state == "gowp" then
		hold_spot(self, state)
		if now() - state.since > state.limit then
			skip(self, well, "the walk took too long")
			leave(self)
		end
		return
	end
	local reach = state.arrived and GATHER_RADIUS + STRAY or GATHER_RADIUS + 1
	if about_well(pos, well, reach) then
		if not state.arrived then
			state.arrived, state.failures = true, nil
			-- Set once: being pushed out and walking back does not extend the stay.
			state.leave_at = state.leave_at or now() + STAY_MIN + math.random() * (STAY_MAX - STAY_MIN)
			release_spot(state)
		end
		-- Legs about the water, on the level of the ground: not up the steps
		-- and onto the rim.
		self._villages_wander_anchor = {pos = well.center, radius = GATHER_RADIUS, max_y = well.stand_y}
		return
	end
	if state.arrived then
		state.since, state.limit = now(), walk_limit(self, well.center)
	end
	state.arrived = nil
	self._villages_wander_anchor = nil
	if now() - state.since > state.limit then
		skip(self, well, "the walk took too long")
		return leave(self)
	end
	if not state.spot then
		state.spot = pick_spot(well, self._id)
		if not state.spot then return end
	end
	hold_spot(self, state)
	if not start_walk(self, state, state.spot) then
		skip(self, well, "no route")
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

	-- The visit is this session's: a reloaded villager starts the day over.
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
		-- ends is not mistaken for the visit's and stopped.
		if self._villages_well and (not free(self) or not enabled()) then leave(self) end
		local result = original_custom(self, dtime)
		if result == false then return result end
		if not enabled() or not free(self) then return result end
		-- Someone is trading with it: vanilla has stopped it, and the time
		-- spent does not count against its walk.
		if trading(self) then
			local state = self._villages_well
			if state then state.since = state.since + dtime end
			return result
		end
		local pos = self.object:get_pos()
		if pos then join(self, pos) end
		-- Vanilla's player scan turns jumping off near a player (see bell.lua).
		if self._villages_well and self.state == "gowp" then self.jump = true end
		return result
	end
end

return {
	install = install,
	-- Exposed for tests.
	examine = examine,
	scan = scan,
	nearest_well = nearest_well,
	pick_spot = pick_spot,
	wells = wells,
	scans = scans,
	holds = holds,
	spots = spots,
	CAP = CAP,
	GATHER_RADIUS = GATHER_RADIUS,
	SPOT_MIN = SPOT_MIN,
	SPOT_MAX = SPOT_MAX,
	SEARCH_RADIUS = SEARCH_RADIUS,
	STAY_MIN = STAY_MIN,
	STAY_MAX = STAY_MAX,
	SCAN_SECONDS = SCAN_SECONDS,
}
