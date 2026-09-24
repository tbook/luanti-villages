-- Bed-directed navigation on top of VoxeLibre's legacy gopath API.  Keep the
-- game's bed claims and movement implementation, but direct trips to an open
-- square beside a bed and retain enough state for useful diagnostics.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local is_sleep_time = common.is_sleep_time
local planner = dofile(core.get_modpath("villages") .. "/planner.lua")
local RETRY_SECONDS = 30
local LEGACY_FAILURE_WAIT = 30
-- Match VoxeLibre's legacy gopath range. A wider preflight can claim a route
-- is viable when gopath will reject that same route.
local PATH_RANGE = 25
local PATHFINDING = "gowp"

local function same_pos(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

local function node_def(pos)
	local node = core.get_node_or_nil(pos)
	return node and core.registered_nodes[node.name]
end

local function wooden_door_at(pos)
	local node = core.get_node_or_nil(pos)
	if node and core.get_item_group(node.name, "door") > 0
		and core.get_item_group(node.name, "door_iron") == 0 then
		return pos
	end
end

local function is_open(pos, allow_wooden_door)
	local node = core.get_node_or_nil(pos)
	if not node then return false end
	if core.get_item_group(node.name, "door") > 0 then
		return allow_wooden_door and core.get_item_group(node.name, "door_iron") == 0
	end
	local def = node_def(pos)
	return def and not def.walkable and (def.liquidtype == nil or def.liquidtype == "none")
end

local function is_supported(pos)
	local def = node_def({x = pos.x, y = pos.y - 1, z = pos.z})
	return def and def.walkable
end

-- Mirror the legacy gopath start normalization. Villagers on stairs often have
-- their rounded position inside the stair's walkable node, so gopath starts
-- from the open node above rather than from the entity's raw position.
local function legacy_path_start(pos)
	local start = vector.round(pos)
	local def = node_def(start)
	if def and not def.walkable then return start end
	local above = {x = start.x, y = start.y + 1, z = start.z}
	if is_open(above) then return above end
	return core.find_node_near(start, 1, {"air"})
end

local function approaches(bed)
	local result = {}
	for _, offset in ipairs({
		{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1},
		{x = 1, z = 1}, {x = 1, z = -1}, {x = -1, z = 1}, {x = -1, z = -1},
	}) do
		local pos = {x = bed.x + offset.x, y = bed.y, z = bed.z + offset.z}
		if is_open(pos) and is_open({x = pos.x, y = pos.y + 1, z = pos.z})
			and is_supported(pos) then
			table.insert(result, pos)
		end
	end
	return result
end

local function has_claimed_bed(self)
	if not self._bed or not self._id then return false end
	local node = core.get_node_or_nil(self._bed)
	if not node or core.get_item_group(node.name, "bed") ~= 1 then return false end
	local meta = core.get_meta(self._bed)
	if meta:get_string("villager") ~= self._id or meta:get_string("player") ~= "" then
		return false
	end
	local top = mcl_beds.get_bed_top(self._bed)
	return core.get_meta(top):get_string("player") == ""
end

local function stop(self)
	self.state = "stand"
	self._target = nil
	self.current_target = nil
	self.waypoints = nil
	self.object:set_velocity(vector.zero())
end

local function fail(self, reason, target, retry_seconds)
	local now = core.get_gametime()
	self._villages_bed_route = {
		status = "retry", reason = reason, retry_at = now + (retry_seconds or RETRY_SECONDS),
		target = target and vector.new(target) or nil,
	}
	stop(self)
end

local function choose_approach(self, candidates)
	local start = self.object:get_pos()
	if not start then return nil end
	start = legacy_path_start(start)
	if not start then return nil end
	for _, candidate in ipairs(candidates) do
		local path = core.find_path(start, candidate, PATH_RANGE, 1, 4)
		if path then return candidate, path end
	end
	-- The legacy gopath has limited door stitching of its own. Let it attempt a
	-- safe candidate even when the plain engine route cannot see one.
	return candidates[1]
end

local function nearest_walk_position(pos)
	local origin = vector.round(pos)
	local best, best_distance
	for x = origin.x - 1, origin.x + 1 do
		for y = origin.y - 2, origin.y + 2 do
			for z = origin.z - 1, origin.z + 1 do
				local candidate = {x = x, y = y, z = z}
				if is_open(candidate, true) and is_open({x = x, y = y + 1, z = z}, true) and is_supported(candidate) then
					local dx, dy, dz = x - pos.x, y - pos.y, z - pos.z
					local distance = dx * dx + dy * dy + dz * dz
					if not best_distance or distance < best_distance then
						best, best_distance = candidate, distance
					end
				end
			end
		end
	end
	return best
end

local function plan_stair_route(self, candidates)
	local start = self.object:get_pos()
	start = start and nearest_walk_position(start)
	if not start then return nil, nil, "stair planner found no nearby walk position" end
	local function can_stand(pos)
		return is_open(pos, true) and is_open({x = pos.x, y = pos.y + 1, z = pos.z}, true) and is_supported(pos)
	end
	local visited = 0
	for _, target in ipairs(candidates) do
		local path, searched = planner.find_path(start, can_stand, function(pos)
			return same_pos(pos, target)
		end, {
			range = 48,
			heuristic = function(pos) return math.abs(pos.x - target.x) + math.abs(pos.z - target.z) + math.abs(pos.y - target.y) end,
		})
		if path then return target, path end
		visited = visited + searched
	end
	return nil, nil, string.format("stair planner found no route after %d nodes", visited)
end

-- gopath occasionally rejects a path that minetest.find_path has returned,
-- particularly from stair landings. Reuse its waypoint mover directly for that
-- narrow case, rather than abandoning a known-valid route.
local function start_engine_path(self, target, path, arrived, door_actions)
	if not path or #path == 0 then return false end
	local waypoints = {}
	for _, pos in ipairs(path) do
		table.insert(waypoints, {pos = vector.new(pos), failed_attempts = 0})
	end
	if door_actions then
		for i = 2, #waypoints do
			local door = wooden_door_at(waypoints[i].pos)
			if door then
				waypoints[i - 1].action = {type = "door", action = "open", target = vector.new(door)}
				if waypoints[i + 1] then
					waypoints[i + 1].action = {type = "door", action = "close", target = vector.new(door)}
				end
			end
		end
	end
	local pos = self.object:get_pos()
	local current = table.remove(waypoints, 1)
	while current and pos and vector.distance(pos, current.pos) < 0.5 do
		current = table.remove(waypoints, 1)
	end
	if not current then return false end
	self._target = vector.new(target)
	self.callback_arrived = arrived
	self.current_target = current
	self.waypoints = waypoints
	self.state = PATHFINDING
	return true
end

local function install(def)
	local original_gopath = def.gopath or mcl_mobs.mob_class.gopath
	local original_custom = def.do_custom
	local original_activate = def.on_activate

	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		-- An in-progress route cannot survive a mapblock unload safely.
		self._villages_bed_route = nil
		return result
	end

	def.gopath = function(self, target, callback_arrived, prioritised)
		if not (self._bed and same_pos(target, self._bed) and is_sleep_time()) then
			return original_gopath(self, target, callback_arrived, prioritised)
		end

		local now = core.get_gametime()
		local route = self._villages_bed_route
		if route and route.status == "retry" and now < route.retry_at then
			stop(self)
			return false
		end
		-- gopath enforces its own failure cooldown. Check it before selecting an
		-- approach so that a restart or a quick retry is reported accurately.
		if self.ready_to_path and not self:ready_to_path(true) then
			local elapsed = self._pf_last_failed and os.time() - self._pf_last_failed or 0
			local retry = math.max(1, LEGACY_FAILURE_WAIT - elapsed)
			fail(self, "legacy pathfinder cooldown", nil, retry)
			return false
		end

		local candidates = approaches(self._bed)
		local candidate, engine_path = choose_approach(self, candidates)
		if not candidate then
		fail(self, "no safe standing space beside bed")
			return false
		end

		self._villages_bed_route = {
			status = "travelling", mode = "legacy", target = vector.new(candidate), started_at = now,
			wall_started_at = os.time(),
		}
		local function arrived_at(arrival_target)
			return function(entity)
				entity._villages_bed_route = {status = "arrived", target = vector.new(arrival_target)}
				entity.order = "sleep"
				if callback_arrived then return callback_arrived(entity) end
			end
		end
		local arrived = arrived_at(candidate)
		local started = original_gopath(self, candidate, arrived, true)
		if started or self.state == PATHFINDING then return started end
		if start_engine_path(self, candidate, engine_path, arrived) then
			self._villages_bed_route.mode = "engine"
			return true
		end
		local stair_target, stair_path, planner_failure = plan_stair_route(self, candidates)
		if stair_target and start_engine_path(self, stair_target, stair_path, arrived_at(stair_target), true) then
			self._villages_bed_route.target = vector.new(stair_target)
			self._villages_bed_route.mode = "planner"
			return true
		end
		fail(self, planner_failure or "pathfinder could not start a route to bed", candidate)
		return false
	end

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		if result == false then return false end
		local route = self._villages_bed_route
		if not is_sleep_time() then
			self._villages_bed_route = nil
			return result
		end
		-- VoxeLibre only schedules activity every five seconds. Start a bed trip
		-- promptly at night so a wandering villager does not wait for that timer.
		if not route and not self.following and self.state ~= PATHFINDING
			and has_claimed_bed(self) and self.object:get_pos()
			and vector.distance(self.object:get_pos(), self._bed) >= 2 then
			self:gopath(self._bed, nil, true)
			route = self._villages_bed_route
		end
		if not route then return result end
		if route.status == "travelling" and self.state ~= PATHFINDING then
			-- A legacy route may start successfully, then wedge on stairs or a
			-- door. Hand that case to the Villages planner before backing off.
			if route.mode ~= "planner" then
				local target, path = plan_stair_route(self, approaches(self._bed))
				if target and path then
					local function arrived(entity)
						entity._villages_bed_route = {status = "arrived", mode = "planner", target = vector.new(target)}
						entity.order = "sleep"
					end
					self._villages_bed_route = {status = "travelling", mode = "planner", target = vector.new(target), started_at = core.get_gametime()}
					if start_engine_path(self, target, path, arrived, true) then return result end
				end
			end
			local failed_at = self._pf_last_failed
			local reason = failed_at and failed_at >= (route.wall_started_at or failed_at)
				and "legacy pathfinder gave up on the bed approach"
				or "bed route was canceled before arrival"
			fail(self, reason, route.target)
		end
		return result
	end
end

return install
