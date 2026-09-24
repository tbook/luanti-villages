-- Bed-directed navigation on top of VoxeLibre's legacy gopath API.  Keep the
-- game's bed claims and movement implementation, but direct trips to an open
-- square beside a bed and retain enough state for useful diagnostics.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local is_sleep_time = common.is_sleep_time
local is_work_time = common.is_work_time
local is_workstation_node = common.is_workstation_node
local planner = dofile(core.get_modpath("villages") .. "/planner.lua")
local RETRY_SECONDS = 30
local LEGACY_FAILURE_WAIT = 30
-- Match VoxeLibre's legacy gopath range. A wider preflight can claim a route
-- is viable when gopath will reject that same route.
local PATH_RANGE = 25
local PATHFINDING = "gowp"
local DOOR_USE_RADIUS = 2.5
-- Door closes must outlive the villager that scheduled them: an entity can be
-- unloaded or despawned while another villager is still passing through.
local deferred_door_closes = {}

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

local function door_is_in_use(door, ignored_object)
	for _, object in ipairs(core.get_objects_inside_radius(door, DOOR_USE_RADIUS)) do
		if object ~= ignored_object then
			local entity = object:get_luaentity()
			if entity and entity.name == "mobs_mc:villager" and entity.state == PATHFINDING then
				return true
			end
		end
	end
	return false
end

local function flush_deferred_door_closes()
	for key, deferred in pairs(deferred_door_closes) do
		if not wooden_door_at(deferred.action.target) then
			deferred_door_closes[key] = nil
		elseif not door_is_in_use(deferred.action.target, deferred.object) then
			deferred_door_closes[key] = nil
			deferred.close()
		end
	end
end

if core.register_globalstep then
	core.register_globalstep(flush_deferred_door_closes)
end

local function is_open(pos, allow_wooden_door)
	local node = core.get_node_or_nil(pos)
	if not node then return false end
	if core.get_item_group(node.name, "door") > 0 then
		return allow_wooden_door and core.get_item_group(node.name, "door_iron") == 0
	end
	local def = node_def(pos)
	return def and not def.walkable and (not def.collision_box or def.collision_box.type == "none")
		and (def.liquidtype == nil or def.liquidtype == "none")
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

local function approaches(node_pos, cardinal_only)
	local result = {}
	local offsets = {
		{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1},
		{x = 1, z = 1}, {x = 1, z = -1}, {x = -1, z = 1}, {x = -1, z = -1},
	}
	for index, offset in ipairs(offsets) do
		if cardinal_only and index > 4 then break end
		local pos = {x = node_pos.x + offset.x, y = node_pos.y, z = node_pos.z + offset.z}
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

local function has_claimed_jobsite(self)
	if not self._jobsite or not self._id then return false end
	local node = core.get_node_or_nil(self._jobsite)
	if not node or not is_workstation_node(node.name) then return false end
	return core.get_meta(self._jobsite):get_string("villager") == self._id
end

local function has_farm_target(self)
	local node = self._villages_farm_target and core.get_node_or_nil(self._villages_farm_target)
	return node and common.farm_replant_node(node.name)
end

local function stop(self)
	self.state = "stand"
	self._target = nil
	self.current_target = nil
	self.waypoints = nil
	self.object:set_velocity(vector.zero())
end

local function fail(self, route_field, reason, target, retry_seconds)
	local now = core.get_gametime()
	self[route_field] = {
		status = "retry", reason = reason, retry_at = now + (retry_seconds or RETRY_SECONDS),
		target = target and vector.new(target) or nil,
	}
	stop(self)
end

local function arrival_callback(route_field, target, callback_arrived, sleep)
	return function(entity)
		entity[route_field] = {status = "arrived", target = vector.new(target)}
		if sleep then entity.order = "sleep" end
		if callback_arrived then return callback_arrived(entity, target) end
	end
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

local function has_traded(self)
	if not self._trades or not core.deserialize then return false end
	local trades = core.deserialize(self._trades)
	if type(trades) ~= "table" then return false end
	for _, trade in pairs(trades) do
		if type(trade) == "table" and trade.traded_once then return true end
	end
	return false
end

-- Do not claim here: native get_a_job still finds this station within one
-- block and invokes its own employ function after the villager arrives.
local function job_search_target(self)
	if self._jobsite or not self._id then return end
	local pos = self.object:get_pos()
	if not pos then return end
	local minp = {x = pos.x - 48, y = pos.y - 48, z = pos.z - 48}
	local maxp = {x = pos.x + 48, y = pos.y + 48, z = pos.z + 48}
	local sites = core.find_nodes_in_area(minp, maxp, common.workstation_search_nodes())
	table.sort(sites, function(a, b) return vector.distance(pos, a) < vector.distance(pos, b) end)
	local profession = has_traded(self) and self._profession or nil
	for _, site in ipairs(sites) do
		local node = core.get_node_or_nil(site)
		if node and core.get_meta(site):get_string("villager") == ""
			and (not profession or common.workstation_profession(node.name) == profession) then
			-- Native employ uses find_node_near(..., 1, ...); a diagonal
			-- destination is not close enough to complete the native claim.
			local candidates = approaches(site, true)
			local approach, engine_path = choose_approach(self, candidates)
			if engine_path then
				return {site = site, candidates = candidates, target = approach, engine_path = engine_path}
			end
			local stair_target, stair_path = plan_stair_route(self, candidates)
			if stair_target and stair_path then
				return {site = site, candidates = candidates, target = stair_target, planner_path = stair_path}
			end
		end
	end
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

local function recover_route(self, destination)
	local route = self[destination.route_field]
	if not route or route.status ~= "travelling" or self.state == PATHFINDING then return false end
	-- A legacy route may start successfully, then wedge on stairs or a door.
	-- Hand that case to the Villages planner before backing off.
	if destination.claimed(self) and route.mode ~= "planner" then
		local target, path = plan_stair_route(self, approaches(destination.pos, destination.cardinal_only))
		if target and path then
			self[destination.route_field] = {
				status = "travelling", mode = "planner", target = vector.new(target),
				started_at = core.get_gametime(), wall_started_at = os.time(), callback = route.callback,
				site = route.site and vector.new(route.site) or nil,
			}
			if start_engine_path(self, target, path,
				arrival_callback(destination.route_field, target, route.callback, destination.sleep), true) then
				return true
			end
		end
	end
	local failed_at = self._pf_last_failed
	local reason = failed_at and failed_at >= (route.wall_started_at or failed_at)
		and "legacy pathfinder gave up on the " .. destination.kind .. " approach"
		or destination.kind .. " route was canceled before arrival"
	fail(self, destination.route_field, reason, route.target)
	return false
end

local function install(def)
	local original_gopath = def.gopath or mcl_mobs.mob_class.gopath
	local original_custom = def.do_custom
	local original_activate = def.on_activate
	local original_door_action = def.do_pathfind_action or mcl_mobs.mob_class.do_pathfind_action

	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		-- An in-progress route cannot survive a mapblock unload safely.
		self._villages_bed_route = nil
		self._villages_job_route = nil
		self._villages_farm_route = nil
		self._villages_farm_target = nil
		self._villages_job_search_route = nil
		self._villages_tavern_route = nil
		self._villages_tavern_target = nil
		return result
	end

	def.do_pathfind_action = function(self, action)
		if action and action.type == "door" and action.action == "close"
			and action.target and wooden_door_at(action.target) and door_is_in_use(action.target, self.object) then
			local key = core.hash_node_position(action.target)
			deferred_door_closes[key] = {
				action = action,
				-- This is compared by identity only during later checks, so it is
				-- safe if the originating villager has since been removed.
				object = self.object,
				close = function() return original_door_action(self, action) end,
			}
			return
		end
		return original_door_action(self, action)
	end

	def.gopath = function(self, target, callback_arrived, prioritised)
		local destination
		local no_jobsite_candidate = false
		local now = core.get_gametime()
		if self._bed and same_pos(target, self._bed) and is_sleep_time() then
			destination = {
				pos = self._bed, route_field = "_villages_bed_route", kind = "bed", sleep = true,
			}
		elseif self._jobsite and same_pos(target, self._jobsite) and is_work_time()
			and has_claimed_jobsite(self) then
			destination = {
				pos = self._jobsite, route_field = "_villages_job_route", kind = "jobsite",
			}
		elseif self._villages_farm_target and same_pos(target, self._villages_farm_target)
			and is_work_time() and has_farm_target(self) then
			destination = {
				pos = self._villages_farm_target, route_field = "_villages_farm_route", kind = "farm plot",
			}
		elseif self._villages_tavern_target and same_pos(target, self._villages_tavern_target)
			and common.is_dinner_time() then
			destination = {
				pos = target, route_field = "_villages_tavern_route", kind = "tavern",
			}
		elseif not self._jobsite and not is_sleep_time() then
			local node = core.get_node_or_nil(target)
			if node and is_workstation_node(node.name) and core.get_meta(target):get_string("villager") == "" then
				local route = self._villages_job_search_route
				if route and route.status == "retry" and now < route.retry_at then
					stop(self)
					return false
				end
				local selection = job_search_target(self)
				if selection then
					destination = {
						pos = selection.site, site = selection.site, candidates = selection.candidates,
						target = selection.target, engine_path = selection.engine_path, planner_path = selection.planner_path,
						route_field = "_villages_job_search_route", kind = "jobsite search",
						cardinal_only = true,
					}
				else
					destination = {
						pos = target, route_field = "_villages_job_search_route", kind = "jobsite search",
					}
					no_jobsite_candidate = true
				end
			end
		end
		if not destination then
			return original_gopath(self, target, callback_arrived, prioritised)
		end

		local route = self[destination.route_field]
		if route and route.status == "retry" and now < route.retry_at then
			stop(self)
			return false
		end
		if no_jobsite_candidate then
			fail(self, destination.route_field, "no reachable unclaimed workstation", target)
			return false
		end
		-- gopath enforces its own failure cooldown. Check it before selecting an
		-- approach so that a restart or a quick retry is reported accurately.
		if self.ready_to_path and not self:ready_to_path(true) then
			local elapsed = self._pf_last_failed and os.time() - self._pf_last_failed or 0
			local retry = math.max(1, LEGACY_FAILURE_WAIT - elapsed)
			fail(self, destination.route_field, "legacy pathfinder cooldown", nil, retry)
			return false
		end

		local candidates = destination.candidates or approaches(destination.pos, destination.cardinal_only)
		local candidate, engine_path = destination.target, destination.engine_path
		if not candidate then candidate, engine_path = choose_approach(self, candidates) end
		if not candidate then
			fail(self, destination.route_field, "no safe standing space beside " .. destination.kind)
			return false
		end

		self[destination.route_field] = {
			status = "travelling", mode = "legacy", target = vector.new(candidate), started_at = now,
			wall_started_at = os.time(), callback = callback_arrived,
			site = destination.site and vector.new(destination.site) or nil,
		}
		local arrived = arrival_callback(destination.route_field, candidate, callback_arrived, destination.sleep)
		local started = original_gopath(self, candidate, arrived, true)
		if started or self.state == PATHFINDING then return started end
		if start_engine_path(self, candidate, engine_path, arrived) then
			self[destination.route_field].mode = "engine"
			return true
		end
		local stair_target, stair_path, planner_failure
		if destination.planner_path then
			stair_target, stair_path = destination.target, destination.planner_path
		else
			stair_target, stair_path, planner_failure = plan_stair_route(self, candidates)
		end
		if stair_target and start_engine_path(self, stair_target, stair_path,
			arrival_callback(destination.route_field, stair_target, callback_arrived, destination.sleep), true) then
			self[destination.route_field].target = vector.new(stair_target)
			self[destination.route_field].mode = "planner"
			return true
		end
		fail(self, destination.route_field, planner_failure or "pathfinder could not start a route to " .. destination.kind, candidate)
		return false
	end

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		-- The global step is the authoritative cleanup path. This also keeps
		-- standalone callers responsive in environments without global steps.
		if not core.register_globalstep then flush_deferred_door_closes() end
		if result == false then return false end
		if not is_sleep_time() then
			self._villages_bed_route = nil
		else
			-- VoxeLibre only schedules activity every five seconds. Start a bed trip
			-- promptly at night so a wandering villager does not wait for that timer.
			if not self._villages_bed_route and not self.following and self.state ~= PATHFINDING
			and has_claimed_bed(self) and self.object:get_pos()
			and vector.distance(self.object:get_pos(), self._bed) >= 2 then
				self:gopath(self._bed, nil, true)
			end
			if recover_route(self, {
				pos = self._bed, route_field = "_villages_bed_route", kind = "bed", sleep = true,
				claimed = has_claimed_bed,
			}) then return result end
		end

		local working = is_work_time()
		if not working then
			self._villages_job_route = nil
			self._villages_farm_route = nil
			self._villages_farm_target = nil
		elseif recover_route(self, {
			pos = self._jobsite, route_field = "_villages_job_route", kind = "jobsite",
			claimed = has_claimed_jobsite,
		}) then
			return result
		end
		if working and recover_route(self, {
			pos = self._villages_farm_target, route_field = "_villages_farm_route", kind = "farm plot",
			claimed = has_farm_target,
		}) then
			return result
		end
		if not common.is_dinner_time() then
			self._villages_tavern_route = nil
		elseif self._villages_tavern_target and recover_route(self, {
			pos = self._villages_tavern_target, route_field = "_villages_tavern_route",
			kind = "tavern", claimed = function(entity)
				local node = core.get_node_or_nil(entity._villages_tavern_target)
				return node and node.name ~= "air" and node.name ~= "ignore"
			end,
		}) then
			return result
		end
		if self._jobsite or is_sleep_time() then
			self._villages_job_search_route = nil
		else
			local search_route = self._villages_job_search_route
			if search_route and search_route.site and recover_route(self, {
				pos = search_route.site, route_field = "_villages_job_search_route", kind = "jobsite search",
				cardinal_only = true,
				claimed = function(entity)
					local route = entity._villages_job_search_route
					return route and route.site and not entity._jobsite
						and core.get_meta(route.site):get_string("villager") == ""
				end,
			}) then
				return result
			end
		end
		return result
	end
end

return install
