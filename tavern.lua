-- The evening trip to the tavern (#16, first slice): during the Tavern stage
-- (#22) every adult walks to the nearest tavern's jukebox and stays there
-- until Home. The first to find a tavern with no keeper becomes its keeper;
-- the rest take a seat at a table if one is free (seat.lua, #99) and are
-- served dinner there while the keeper is on duty (meal.lua, #100).
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local keeper = dofile(core.get_modpath("living_villages") .. "/keeper.lua")
local seat = dofile(core.get_modpath("living_villages") .. "/seat.lua")
local JUKEBOX = "mcl_jukebox:jukebox"
-- How far from its bed a villager looks for a tavern: its own village, not
-- the next one over, and inside vanilla's 50-node leash, past which
-- do_activity walks a villager straight home (villager.lua wandered_too_far).
local SEARCH_RADIUS = 48
local SEARCH_HEIGHT = 16
-- A villager this close to the jukebox is inside the tavern.
local ARRIVE_DISTANCE = 4
-- A villager not at the tavern by 17:00 goes home instead (#22).
-- Skipping sets _villages_skip_tavern to the day, which turns the rest of
-- that villager's Tavern stage into Home (common.lua), so navigation's own
-- bed trip and vanilla's go_home take it there.
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

local meal

local function end_visit(self)
	meal.stand(self)
	seat.stand(self)
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
		-- On the way to a chair, which may be further from the jukebox than
		-- the arrival distance.
		if self._villages_seat and seat.approach_seat(self) then return end
		if vector.distance(pos, jukebox) < ARRIVE_DISTANCE then
			if not self._villages_tavern_arrived then arrive(self) end
			-- A keeper stays on its feet; everyone else looks for a seat,
			-- and stands if there is none.
			if not self._villages_keeper and seat.reserve(self, jukebox) and seat.approach_seat(self) then
				return
			end
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
			self._villages_skip_tavern = day
			return
		end
		local route = self._villages_tavern_route
		if self.state ~= "gowp" and not (route and route.status == "travelling")
			and not (route and route.status == "retry" and core.get_gametime() < route.retry_at) then
			self:gopath(jukebox, arrive, true)
		end
		return
	end
	if self._villages_tavern_day == day then return end
	if ticks() >= LEAVE_BY then
		self._villages_tavern_day = day
		self._villages_skip_tavern = day
		return
	end
	-- One decision a day: a village with no tavern skips straight to Home.
	self._villages_tavern_day = day
	local tavern = nearest_tavern(self._bed or vector.round(pos))
	if not tavern then
		self._villages_skip_tavern = day
		return
	end
	self._villages_tavern_target = tavern
	return visit(self)
end

-- Still at dinner: the Tavern stage, and the tavern still there.
local function dining(self)
	local jukebox = self._villages_tavern_target
	local node = jukebox and core.get_node_or_nil(jukebox)
	return not self.child and self._id and not self.following
		and common.schedule_stage(nil, self) == "tavern"
		and not (node and node.name ~= JUKEBOX)
end

return function(def, shared_meal)
	-- init.lua passes the copy it loaded, which registered the meal entity.
	meal = shared_meal or dofile(core.get_modpath("living_villages") .. "/meal.lua")
	seat.install(def)
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_staticdata = def.get_staticdata
	local original_die = def.on_die

	-- Keep the evening's destination across an unload: it is plain data,
	-- and the day's one decision has already been made, so dropping it would
	-- leave the villager neither at dinner nor going home. The route and the
	-- arrival are this session's and are redone; the hold is released until
	-- the villager is back inside.
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		self._villages_tavern_route = nil
		self._villages_tavern_arrived = nil
		if self.order == "stand" then self.order = nil end
		-- The meal entity is never saved; the evening's meal day is.
		self._villages_meal, self._villages_seated_at = nil, nil
		return result
	end

	-- The meal holds its entity, which cannot be serialized.
	def.get_staticdata = function(self)
		local current, seated_at = self._villages_meal, self._villages_seated_at
		self._villages_meal, self._villages_seated_at = nil, nil
		local saved = original_staticdata(self)
		self._villages_meal, self._villages_seated_at = current, seated_at
		return saved
	end

	def.on_die = function(self, pos, cmi_cause)
		meal.stand(self)
		return original_die(self, pos, cmi_cause)
	end

	def.do_custom = function(self, dtime)
		-- Seated, like asleep in init.lua: skip the vanilla do_custom, whose
		-- activity poll would walk the guest off, and hold the pose each tick.
		if self._villages_seated then
			if dining(self) and seat.hold_seat(self) then
				self.order = "stand"
				meal.tick(self, dtime, self._villages_tavern_target)
				return false
			end
			meal.stand(self)
			seat.stand(self)
		end
		local result = original_custom(self, dtime)
		if result == false then return result end
		-- Keepers never see this stage: theirs is Staff (common.lua).
		if dining(self) then
			visit(self)
		elseif self._villages_tavern_target then
			end_visit(self)
		end
		return result
	end
end
