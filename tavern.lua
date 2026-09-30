-- The evening trip to the tavern (#16, first slice): during the Tavern stage
-- (#22) every adult walks to the nearest tavern's jukebox and stays there
-- until Home. The first to find a tavern with no keeper becomes its keeper.
-- Seats, plates and meals come later.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local keeper = dofile(core.get_modpath("villages") .. "/keeper.lua")
local JUKEBOX = "mcl_jukebox:jukebox"
-- How far from its bed a villager looks for a tavern: its own village, not
-- the next one over, and inside vanilla's 50-node leash, past which
-- do_activity walks a villager straight home (villager.lua wandered_too_far).
local SEARCH_RADIUS = 48
local SEARCH_HEIGHT = 16
-- A villager this close to the jukebox is inside the tavern.
local ARRIVE_DISTANCE = 4
-- A villager not at the tavern by 17:00 goes home instead (#22).
local LEAVE_BY = 17000

local function ticks()
	return (core.get_timeofday() * 24000) % 24000
end

local function nearest_tavern(origin)
	local sites = core.find_nodes_in_area(
		{x = origin.x - SEARCH_RADIUS, y = origin.y - SEARCH_HEIGHT, z = origin.z - SEARCH_RADIUS},
		{x = origin.x + SEARCH_RADIUS, y = origin.y + SEARCH_HEIGHT, z = origin.z + SEARCH_RADIUS},
		{JUKEBOX})
	local best, best_distance
	for _, site in ipairs(sites) do
		local distance = vector.distance(origin, site)
		if distance <= SEARCH_RADIUS and (not best or distance < best_distance) then best, best_distance = site, distance end
	end
	return best
end

local function end_visit(self)
	local route = self._villages_tavern_route
	self._villages_tavern_route = nil
	if route and route.status == "travelling" and self.state == "gowp" then
		-- The same stop navigation.lua uses when it cancels a trip.
		self.state = "stand"
		self._target, self.current_target, self.waypoints, self.callback_arrived = nil, nil, nil, nil
		self.object:set_velocity(vector.zero())
	end
	self._villages_tavern_target = nil
	self._villages_tavern_arrived = nil
	if self.order == "stand" then self.order = nil end
end

local function arrive(self)
	local jukebox = self._villages_tavern_target
	if not jukebox then return end
	self._villages_tavern_arrived = true
	keeper.take_over(self, jukebox)
end

local visit
visit = function(self)
	local day = core.get_day_count()
	local jukebox = self._villages_tavern_target
	local pos = self.object:get_pos()
	if not pos then return end
	if jukebox then
		local node = core.get_node_or_nil(jukebox)
		if node and node.name ~= JUKEBOX then
			end_visit(self)
			return
		end
		if vector.distance(pos, jukebox) < ARRIVE_DISTANCE then
			if not self._villages_tavern_arrived then arrive(self) end
			-- Stay put. Vanilla clears the order on every activity poll
			-- (villager.lua do_activity's else branch), so hold it each tick;
			-- "stand" is one of the orders that stops the wander
			-- (mcl_mobs/movement.lua).
			self.order = "stand"
			return
		end
		if self._villages_tavern_arrived then
			-- Wandered out, or was pushed: walk back in.
			self._villages_tavern_arrived = nil
		elseif ticks() >= LEAVE_BY then
			end_visit(self)
			self._villages_tavern_day = day
			return
		end
		local route = self._villages_tavern_route
		if self.state ~= "gowp" and not (route and route.status == "travelling")
			and not (route and route.status == "retry" and core.get_gametime() < route.retry_at) then
			self:gopath(jukebox, arrive, true)
		end
		return
	end
	if self._villages_tavern_day == day or ticks() >= LEAVE_BY then return end
	-- One decision a day: a village with no tavern skips straight to Home.
	self._villages_tavern_day = day
	local tavern = nearest_tavern(self._bed or vector.round(pos))
	if not tavern then return end
	self._villages_tavern_target = tavern
	return visit(self)
end

return function(def)
	local original_activate = def.on_activate
	local original_custom = def.do_custom

	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		end_visit(self)
		return result
	end

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		if result == false then return result end
		-- Keepers never see this stage: theirs is Staff (common.lua).
		local dining = not self.child and self._id and not self.following
			and common.schedule_stage(nil, self) == "tavern"
		if dining then
			visit(self)
		elseif self._villages_tavern_target then
			end_visit(self)
		end
		return result
	end
end
