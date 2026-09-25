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
local NO_PROGRESS_SECONDS = 20
local PROGRESS_DISTANCE = 0.35
-- Allow ordinary multi-room trips beyond the legacy 25-node preflight while
-- staying inside the fallback planner's 48-node search boundary.
local PATH_RANGE = 40
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

local function iron_door_at(pos)
	local node = core.get_node_or_nil(pos)
	return node and core.get_item_group(node.name, "door") > 0
		and core.get_item_group(node.name, "door_iron") > 0 and pos
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

local function collision_box_top(def)
	local box = def and def.collision_box
	if not box or box.type ~= "fixed" then return 0.5 end
	local fixed = box.fixed
	if type(fixed) ~= "table" then return -0.5 end
	if type(fixed[1]) == "number" then return fixed[5] or -0.5 end
	local top = -0.5
	for _, part in ipairs(fixed) do
		if type(part) == "table" and type(part[5]) == "number" then top = math.max(top, part[5]) end
	end
	return top
end

local function is_supported(pos)
	local support = {x = pos.x, y = pos.y - 1, z = pos.z}
	local node = core.get_node_or_nil(support)
	local def = node and core.registered_nodes[node.name]
	if not def or not def.walkable then return false end
	-- A villager's feet are at the top of the supporting node. Low slabs do not
	-- reach that height; fences and trapdoors are not walkable floor surfaces.
	if collision_box_top(def) < 0.49 then return false end
	if core.get_item_group(node.name, "fence") > 0 or core.get_item_group(node.name, "trapdoor") > 0 then
		return false
	end
	if (def.damage_per_second or 0) > 0 then return false end
	return core.get_item_group(node.name, "fire") == 0
		and core.get_item_group(node.name, "cactus") == 0
		and core.get_item_group(node.name, "dangerous") == 0
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
	self.callback_arrived = nil
	self._villages_blocked_door = nil
	self.object:set_velocity(vector.zero())
end

local function set_route(self, route_field, route)
	self._villages_route_id = (self._villages_route_id or 0) + 1
	route.id = self._villages_route_id
	local pos = self.object:get_pos()
	route.last_progress_at = core.get_gametime()
	route.last_progress_pos = pos and vector.new(pos) or nil
	self[route_field] = route
	return route
end

local function cancel_route(self, route_field)
	local route = self[route_field]
	self[route_field] = nil
	if route and route.status == "travelling" then stop(self) end
end

local function fail(self, route_field, reason, target, retry_seconds, planner_report)
	local now = core.get_gametime()
	set_route(self, route_field, {
		status = "retry", reason = reason, retry_at = now + (retry_seconds or RETRY_SECONDS),
		target = target and vector.new(target) or nil,
		planner = planner_report,
	})
	stop(self)
end

local function arrival_callback(route_field, route_id, target, callback_arrived, sleep)
	return function(entity)
		local route = entity[route_field]
		-- Native path callbacks can fire after a route was canceled or replaced.
		-- Only the route that created this callback may complete it.
		if not route or route.status ~= "travelling" or route.id ~= route_id then return end
		entity[route_field] = {status = "arrived", id = route_id, target = vector.new(target)}
		if sleep then entity.order = "sleep" end
		if callback_arrived then return callback_arrived(entity, target) end
	end
end

local function path_cost(path)
	local cost = 0
	for index = 2, #path do
		cost = cost + 1 + math.abs(path[index].y - path[index - 1].y) * 0.25
	end
	return cost
end

local function choose_approach(self, candidates)
	local start = self.object:get_pos()
	if not start then return nil end
	start = legacy_path_start(start)
	if not start then return nil end
	local best_candidate, best_path, best_cost
	for _, candidate in ipairs(candidates) do
		local path = core.find_path(start, candidate, PATH_RANGE, 1, 4)
		local cost = path and path_cost(path)
		if cost and (not best_cost or cost < best_cost) then
			best_candidate, best_path, best_cost = candidate, path, cost
		end
	end
	if best_path then return best_candidate, best_path, best_cost end
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
	if #candidates == 0 then
		return nil, nil, "stair planner found no route after 0 nodes", nil, {
			start = vector.new(start), candidates = {}, status = "unreachable", searched = 0, trail = {},
		}
	end
	local function can_stand(pos)
		return is_open(pos, true) and is_open({x = pos.x, y = pos.y + 1, z = pos.z}, true) and is_supported(pos)
	end
	local targets = {}
	for _, target in ipairs(candidates) do targets[target.x .. ":" .. target.y .. ":" .. target.z] = target end
	-- Bed approaches share nearly all of their map search. Search them as one
	-- multi-goal route so two open sides do not each consume the full budget.
	local function distance_to_target(pos)
		local best
		for _, target in pairs(targets) do
			local distance = math.abs(pos.x - target.x) + math.abs(pos.z - target.z) + math.abs(pos.y - target.y)
			if not best or distance < best then best = distance end
		end
		return best
	end
	local path, visited, status, details = planner.find_path(start, can_stand, function(pos)
		return targets[pos.x .. ":" .. pos.y .. ":" .. pos.z] ~= nil
	end, {
		range = 48,
		heuristic = distance_to_target,
		distance = distance_to_target,
	})
	local report = {
		start = vector.new(start), candidates = {}, status = status, searched = visited,
		closest = details and details.closest and vector.new(details.closest) or nil,
		closest_distance = details and details.closest_distance or nil,
		closest_cost = details and details.closest_cost or nil,
		trail = {},
	}
	for _, target in pairs(targets) do table.insert(report.candidates, vector.new(target)) end
	for _, pos in ipairs(details and details.closest_path or {}) do table.insert(report.trail, vector.new(pos)) end
	if path then
		local target = path[#path]
		return target, path, nil, path_cost(path), report
	end
	local outcome = status == "search_limit" and "reached its search limit" or "found no route"
	return nil, nil, string.format("stair planner %s after %d nodes", outcome, visited), nil, report
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

local function better_jobsite(pos, site, cost, best)
	if not best or cost < best.cost then return true end
	if cost ~= best.cost then return false end
	local distance, best_distance = vector.distance(pos, site), vector.distance(pos, best.site)
	if distance ~= best_distance then return distance < best_distance end
	if site.x ~= best.site.x then return site.x < best.site.x end
	if site.y ~= best.site.y then return site.y < best.site.y end
	return site.z < best.site.z
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
	local profession = has_traded(self) and self._profession or nil
	local best
	for _, site in ipairs(sites) do
		local node = core.get_node_or_nil(site)
		if node and core.get_meta(site):get_string("villager") == ""
			and (not profession or common.workstation_profession(node.name) == profession) then
			-- Native employ uses find_node_near(..., 1, ...); a diagonal
			-- destination is not close enough to complete the native claim.
			local candidates = approaches(site, true)
			local approach, engine_path, engine_cost = choose_approach(self, candidates)
			if engine_path then
				if better_jobsite(pos, site, engine_cost, best) then
					best = {site = site, candidates = candidates, target = approach,
						engine_path = engine_path, cost = engine_cost}
				end
			else
				local stair_target, stair_path, _, stair_cost = plan_stair_route(self, candidates)
				if stair_target and stair_path and better_jobsite(pos, site, stair_cost, best) then
					best = {site = site, candidates = candidates, target = stair_target,
						planner_path = stair_path, cost = stair_cost}
				end
			end
		end
	end
	return best
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
	local planner_failure, planner_report
	-- A legacy route may start successfully, then wedge on stairs or a door.
	-- Hand that case to the Villages planner before backing off.
	if destination.claimed(self) and route.mode ~= "planner" then
		local target, path
		target, path, planner_failure, _, planner_report = plan_stair_route(self, approaches(destination.pos, destination.cardinal_only))
		if target and path then
			local recovered = set_route(self, destination.route_field, {
				status = "travelling", mode = "planner", target = vector.new(target),
				started_at = core.get_gametime(), wall_started_at = os.time(), callback = route.callback,
				site = route.site and vector.new(route.site) or nil,
				planner = planner_report,
			})
			if start_engine_path(self, target, path,
				arrival_callback(destination.route_field, recovered.id, target, route.callback, destination.sleep), true) then
				return true
			end
		end
	end
	local failed_at = self._pf_last_failed
	local reason = failed_at and failed_at >= (route.wall_started_at or failed_at)
		and "legacy pathfinder gave up on the " .. destination.kind .. " approach"
		or destination.kind .. " route was canceled before arrival"
	fail(self, destination.route_field, planner_failure or reason, route.target, nil, planner_report)
	return false
end

local function recover_stalled_route(self, destination)
	local route = self[destination.route_field]
	if not route or route.status ~= "travelling" or self.state ~= PATHFINDING then return false end
	if self._villages_blocked_door then
		self._villages_blocked_door = nil
		stop(self)
		return recover_route(self, destination)
	end
	local pos = self.object:get_pos()
	if not pos then return false end
	if not route.last_progress_pos or vector.distance(pos, route.last_progress_pos) >= PROGRESS_DISTANCE then
		route.last_progress_pos = vector.new(pos)
		route.last_progress_at = core.get_gametime()
		return false
	end
	if core.get_gametime() - (route.last_progress_at or core.get_gametime()) < NO_PROGRESS_SECONDS then
		return false
	end
	-- A mover that remains in gowp can otherwise be stuck forever. Stop it
	-- before recovery so the planner may take ownership of the trip.
	stop(self)
	return recover_route(self, destination)
end

local function install(def)
	local original_gopath = def.gopath or mcl_mobs.mob_class.gopath
	local original_custom = def.do_custom
	local original_activate = def.on_activate
	local original_door_action = def.do_pathfind_action or mcl_mobs.mob_class.do_pathfind_action

	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		-- An in-progress route cannot survive a mapblock unload safely.
		local had_managed_route = (self._villages_bed_route and self._villages_bed_route.status == "travelling")
			or (self._villages_job_route and self._villages_job_route.status == "travelling")
			or (self._villages_farm_route and self._villages_farm_route.status == "travelling")
			or (self._villages_job_search_route and self._villages_job_search_route.status == "travelling")
		self._villages_bed_route = nil
		self._villages_job_route = nil
		self._villages_farm_route = nil
		self._villages_farm_target = nil
		self._villages_job_search_route = nil
		if had_managed_route then stop(self) end
		return result
	end

	def.do_pathfind_action = function(self, action)
		if action and action.type == "door" and action.action == "open"
			and action.target and iron_door_at(action.target) then
			-- The door changed after planning or was replaced with an iron door.
			-- Do not keep retrying an action that cannot succeed; the next custom
			-- tick replans around it or records a bounded route failure.
			self._villages_blocked_door = vector.new(action.target)
			return
		end
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

		local route = set_route(self, destination.route_field, {
			status = "travelling", mode = "legacy", target = vector.new(candidate), started_at = now,
			wall_started_at = os.time(), callback = callback_arrived,
			site = destination.site and vector.new(destination.site) or nil,
		})
		local arrived = arrival_callback(destination.route_field, route.id, candidate, callback_arrived, destination.sleep)
		local started = original_gopath(self, candidate, arrived, true)
		if started or self.state == PATHFINDING then return true end
		if start_engine_path(self, candidate, engine_path, arrived) then
			self[destination.route_field].mode = "engine"
			return true
		end
		local stair_target, stair_path, planner_failure, _, planner_report
		if destination.planner_path then
			stair_target, stair_path = destination.target, destination.planner_path
		else
			stair_target, stair_path, planner_failure, _, planner_report = plan_stair_route(self, candidates)
		end
		if stair_target and start_engine_path(self, stair_target, stair_path,
			arrival_callback(destination.route_field, route.id, stair_target, callback_arrived, destination.sleep), true) then
			self[destination.route_field].target = vector.new(stair_target)
			self[destination.route_field].mode = "planner"
			self[destination.route_field].planner = planner_report
			return true
		end
		fail(self, destination.route_field, planner_failure or "pathfinder could not start a route to " .. destination.kind,
			candidate, nil, planner_report)
		return false
	end

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		-- The global step is the authoritative cleanup path. This also keeps
		-- standalone callers responsive in environments without global steps.
		if not core.register_globalstep then flush_deferred_door_closes() end
		if result == false then return false end
		if self.following then
			cancel_route(self, "_villages_bed_route")
			cancel_route(self, "_villages_job_route")
			cancel_route(self, "_villages_farm_route")
			cancel_route(self, "_villages_job_search_route")
			self._villages_farm_target = nil
			return result
		end
		if not is_sleep_time() then
			cancel_route(self, "_villages_bed_route")
		else
			-- VoxeLibre only schedules activity every five seconds. Start a bed trip
			-- promptly at night so a wandering villager does not wait for that timer.
			if not self._villages_bed_route and not self.following and self.state ~= PATHFINDING
			and has_claimed_bed(self) and self.object:get_pos() then
				if vector.distance(self.object:get_pos(), self._bed) >= 2 then
					self:gopath(self._bed, nil, true)
				elseif self.order ~= "sleep" then
					-- Already close enough that no trip is needed. Without this,
					-- a villager standing near its bed at nightfall would still
					-- wait out VoxeLibre's five-second activity poll before its
					-- order flips to "sleep" and it can lie down.
					self.order = "sleep"
				end
			end
			local bed_destination = {
				pos = self._bed, route_field = "_villages_bed_route", kind = "bed", sleep = true,
				claimed = has_claimed_bed,
			}
			if recover_stalled_route(self, bed_destination) or recover_route(self, bed_destination) then return result end
		end

		local working = is_work_time()
		if not working then
			cancel_route(self, "_villages_job_route")
			cancel_route(self, "_villages_farm_route")
			self._villages_farm_target = nil
		else
			local job_destination = {
			pos = self._jobsite, route_field = "_villages_job_route", kind = "jobsite",
			claimed = has_claimed_jobsite,
			}
			if recover_stalled_route(self, job_destination) or recover_route(self, job_destination) then return result end
		end
		local farm_destination = {
			pos = self._villages_farm_target, route_field = "_villages_farm_route", kind = "farm plot",
			claimed = has_farm_target,
		}
		if working and (recover_stalled_route(self, farm_destination) or recover_route(self, farm_destination)) then return result end
		if self._jobsite or is_sleep_time() then
			cancel_route(self, "_villages_job_search_route")
		else
			local search_route = self._villages_job_search_route
			if search_route and search_route.site then
				local search_destination = {
					pos = search_route.site, route_field = "_villages_job_search_route", kind = "jobsite search",
					cardinal_only = true,
					claimed = function(entity)
						local route = entity._villages_job_search_route
						return route and route.site and not entity._jobsite
							and core.get_meta(route.site):get_string("villager") == ""
					end,
				}
				if recover_stalled_route(self, search_destination) or recover_route(self, search_destination) then
					return result
				end
			end
		end
		return result
	end
end

return install
