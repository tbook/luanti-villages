local now = 100
local gopath_target, arrived, preflight_start, preflight_range, preflight_found = nil, nil, nil, nil, nil
local path_available = true
local required_path_range = 0
local engine_paths = nil
local support_available = true
local support_node = "stone"
local wooden_door = false
local door_name, door_param2 = "mcl_doors:wooden_door_b_1", nil
local iron_door = false
local glass_pane = false
local low_ceiling = false
local timeofday = 0.8
local jobsite_present = true
local nearby_objects = {}
local search_sites = {}
local job_search_scans = 0
local jobsite_claimed = true
local globalstep = nil
local all_steps = {}
local water_sites = {}
local water_source_nodes = {}
local water_scans = 0
local raised_shore_nodes = {}
local logged = {}
-- The planner chooses every route (#163). The first half of this file runs
-- with the setting off, which keeps today's engine-first route choice.
local planner_routes = false

-- Route planning runs from the route queue's globalstep (#162); settle() lets
-- every pending search finish.
local function settle()
	for _ = 1, 200 do
		for _, step in ipairs(all_steps) do step(0.1) end
	end
end

minetest = {
	registered_nodes = {
		["air"] = {walkable = false, liquidtype = "none"},
		["stone"] = {walkable = true},
		["mcl_beds:bed_red_bottom"] = {walkable = false, liquidtype = "none"},
		["mcl_composters:composter"] = {walkable = true},
		["mcl_doors:wooden_door_b_1"] = {walkable = false, liquidtype = "none"},
		["mcl_doors:iron_door_b_1"] = {walkable = false, liquidtype = "none"},
		["mcl_panes:glass_pane"] = {walkable = false, liquidtype = "none", collision_box = {type = "fixed"}},
		["test:low_slab"] = {walkable = true, collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0, 0.5}}},
		["test:stair"] = {walkable = true, collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}},
		["test:fence"] = {walkable = true},
		["test:trapdoor"] = {walkable = true},
		["test:cactus"] = {walkable = true},
		["mcl_core:water_source"] = {liquidtype = "source"},
		["mcl_core:water_flowing"] = {liquidtype = "flowing"},
	},
	settings = {
		get = function() return nil end,
		get_bool = function(_, name, default)
			if name == "living_villages_planner_routes" then return planner_routes end
			return default
		end,
	},
	get_timeofday = function() return timeofday end,
	get_gametime = function() return now end,
	get_modpath = function() return "." end,
	get_node_or_nil = function(pos)
		if pos.x == 0 and pos.y == 0 and pos.z == 0 then return {name = "mcl_beds:bed_red_bottom"} end
		if jobsite_present and pos.x == 10 and pos.y == 0 and pos.z == 0 then
			return {name = "mcl_composters:composter"}
		end
		if (pos.x == 20 or pos.x == 30) and pos.y == 0 and pos.z == 0 then
			return {name = "mcl_composters:composter"}
		end
		if glass_pane and pos.x == 1 and pos.y == 0 and pos.z == 0 then
			return {name = "mcl_panes:glass_pane"}
		end
		if low_ceiling and pos.x == 1 and pos.y == 1 and pos.z == 0 then
			return {name = "mcl_panes:glass_pane"}
		end
		if iron_door and pos.x == 1 and pos.y == 0 and pos.z == 0 then
			return {name = "mcl_doors:iron_door_b_1"}
		end
		if wooden_door and pos.x == 1 and pos.y == 0 and pos.z == 0 then
			return {name = door_name, param2 = door_param2}
		end
		local water_node = water_source_nodes[pos.x .. ":" .. pos.y .. ":" .. pos.z]
		if water_node then return {name = water_node} end
		local shore_node = raised_shore_nodes[pos.x .. ":" .. pos.y .. ":" .. pos.z]
		if shore_node then return {name = shore_node} end
		if pos.y == -1 and support_available then return {name = support_node} end
		return {name = "air"}
	end,
	find_node_near = function() return nil end,
	find_nodes_in_area = function(minp, maxp, nodenames)
		if nodenames[1] == "group:water" then
			water_scans = water_scans + 1
			-- The real engine bounds the returned sites to minp/maxp; match
			-- that here so vertical- and horizontal-band tests can rely on
			-- out-of-range seeds genuinely never being offered, the same way
			-- flood_fill_pond's own neighbor walk is bounded once a seed is.
			local bounded = {}
			for _, site in ipairs(water_sites) do
				if site.x >= minp.x and site.x <= maxp.x
					and site.y >= minp.y and site.y <= maxp.y
					and site.z >= minp.z and site.z <= maxp.z then
					table.insert(bounded, site)
				end
			end
			return bounded
		end
		job_search_scans = job_search_scans + 1
		return search_sites
	end,
	get_item_group = function(name, group)
		return group == "bed" and name:find("bed", 1, true) and 1
			or group == "door" and name:find("door", 1, true) and 1
			or group == "door_iron" and name:find("iron_door", 1, true) and 1
			or group == "fence" and name == "test:fence" and 1
			or group == "trapdoor" and name == "test:trapdoor" and 1
			or group == "cactus" and name == "test:cactus" and 1 or 0
	end,
	find_path = function(start, target, range)
		preflight_start, preflight_range = start, range
		preflight_found = path_available and range >= required_path_range
		if engine_paths then return engine_paths[target.x .. ":" .. target.y .. ":" .. target.z] end
		return preflight_found and {{x = 1, y = 0, z = 0}} or nil
	end,
	get_objects_inside_radius = function() return nearby_objects end,
	hash_node_position = function(pos) return pos.x .. ":" .. pos.y .. ":" .. pos.z end,
	register_globalstep = function(callback) globalstep = callback; table.insert(all_steps, callback) end,
	log = function(level, message) table.insert(logged, message) end,
	pos_to_string = function(pos) return "(" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")" end,
}
vector = {
	new = function(pos) return {x = pos.x, y = pos.y, z = pos.z} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
	round = function(pos) return {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5)} end,
	distance = function(a, b)
		local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(x * x + y * y + z * z)
	end,
}
mcl_beds = {get_bed_top = function(pos)
	return {x = pos.x, y = pos.y + 1, z = pos.z}
end}
mcl_mobs = {mob_class = {}}

local def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function(self, target, callback)
		gopath_target, arrived = target, callback
		self.state = "gowp"
		return true
	end,
}
dofile("navigation.lua")(def)

local entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
assert(def.gopath(entity, entity._bed, function() end, true))
settle()
assert(gopath_target and not (gopath_target.x == 0 and gopath_target.z == 0))
assert(preflight_start.y == 1 and preflight_range == 40)
assert(entity._villages_bed_route.status == "travelling")
arrived(entity)
assert(entity.order == "sleep")
assert(entity._villages_bed_route.status == "arrived")

-- Select the lowest-cost reachable bed approach rather than the first compass
-- direction returned by approaches().
local function path_with_length(length)
	local path = {}
	for index = 1, length do table.insert(path, {x = index, y = 0, z = 0}) end
	return path
end
engine_paths = {
	["1:0:0"] = path_with_length(10),
	["-1:0:0"] = path_with_length(2),
}
local cost_aware_bed_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
assert(def.gopath(cost_aware_bed_entity, cost_aware_bed_entity._bed, nil, true))
settle()
assert(gopath_target.x == -1 and gopath_target.z == 0)
engine_paths = nil

-- Routes just beyond the legacy 25-node preflight remain eligible for the
-- engine path check under the expanded 40-node bound.
required_path_range = 26
local expanded_range_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
assert(def.gopath(expanded_range_entity, expanded_range_entity._bed, nil, true))
settle()
assert(preflight_range == 40 and preflight_found)
required_path_range = 0

-- A pane is non-walkable but has collision geometry, so it cannot be used as
-- a standing position beside a bed.
glass_pane = true
local pane_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
assert(def.gopath(pane_entity, pane_entity._bed, nil, true))
settle()
assert(gopath_target.x == -1 and gopath_target.z == 0)
glass_pane = false

-- The standing box needs a clear head node as well as a clear feet node.
low_ceiling = true
local low_ceiling_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
assert(def.gopath(low_ceiling_entity, low_ceiling_entity._bed, nil, true))
settle()
assert(gopath_target.x == -1 and gopath_target.z == 0)
low_ceiling = false

-- core.find_path plans for a walker one node tall, so the legacy mover's own
-- route can pass under something at head height, like the wall posts beside
-- a tavern's steps (#93). Such a route is dropped for the planner's, which
-- keeps the whole villager clear, and the engine preflight path is not used.
low_ceiling = true
local overhang_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function(self, target, callback)
		self.current_target = {pos = {x = 2, y = 0, z = 0}}
		self.waypoints = {{pos = {x = 1, y = 0, z = 0}}, {pos = vector.new(target)}}
		self.state = "gowp"
		return true
	end,
}
dofile("navigation.lua")(overhang_def)
local overhang_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
assert(overhang_def.gopath(overhang_entity, overhang_entity._bed, nil, true))
settle()
assert(overhang_entity._villages_bed_route.mode == "planner", "a route under an overhang goes to the planner")
for _, waypoint in ipairs(overhang_entity.waypoints) do
	assert(not (waypoint.pos.x == 1 and waypoint.pos.z == 0), "the planner's route keeps clear of the overhang")
end
assert(logged[#logged]:find("passes under mcl_panes:glass_pane at (1,1,0)", 1, true), "a replan is logged")

-- A trip this module does not otherwise manage (a keeper to its jukebox, a
-- guest to its seat) is rerouted the same way, to the target itself when a
-- villager can stand there.
local detour_arrived = function() end
local detour_entity = {
	_jobsite = {x = 50, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
timeofday = 0.3
assert(overhang_def.gopath(detour_entity, {x = -2, y = 0, z = 0}, detour_arrived, true))
settle()
timeofday = 0.8
assert(detour_entity.state == "gowp" and detour_entity._target.x == -2 and detour_entity._target.z == 0,
	"an unmanaged trip keeps its own target")
assert(detour_entity.callback_arrived == detour_arrived, "and its own arrival callback")
for _, waypoint in ipairs(detour_entity.waypoints) do
	assert(not (waypoint.pos.x == 1 and waypoint.pos.z == 0), "the detour keeps clear of the overhang")
end
-- When no detour exists either, the failure is recorded so that vanilla's
-- ready_to_path holds off the next attempt; upstream saw its own route
-- succeed and set no cooldown of its own.
support_available = false
local stuck_entity = {
	_jobsite = {x = 50, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
timeofday = 0.3
assert(overhang_def.gopath(stuck_entity, {x = -2, y = 0, z = 0}, nil, true), "the detour is planned later")
assert(stuck_entity.state == "stand" and not stuck_entity._pf_last_failed, "and the villager waits meanwhile")
settle()
timeofday = 0.8
assert(stuck_entity.state == "stand" and stuck_entity._pf_last_failed, "a failed detour sets the pathfinding cooldown")
support_available = true
low_ceiling = false

def.do_custom(entity, 0.1)
settle()
assert(entity._villages_bed_route.status == "arrived")

local failed_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return false end,
}
dofile("navigation.lua")(failed_def)
path_available = false
support_available = false
local failed_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(not failed_def.gopath(failed_entity, failed_entity._bed, nil, true))
assert(failed_entity.state == "stand")
assert(failed_entity._villages_bed_route.status == "retry")
assert(failed_entity._villages_bed_route.reason:find("no safe standing", 1, true))
assert(not failed_entity._villages_bed_route.target)
path_available = true
support_available = true

-- Fallback routes require floor-height, non-hazardous support. Low slabs,
-- fences, and cactus support must not produce a standable bed approach.
for _, unsafe_support in ipairs({"test:low_slab", "test:fence", "test:trapdoor", "test:cactus"}) do
	support_node = unsafe_support
	local unsafe_entity = {
		_bed = {x = 0, y = 0, z = 0}, state = "stand",
		object = {
			get_pos = function() return {x = 5, y = 0, z = 0} end,
			set_velocity = function() end,
		},
	}
	assert(not failed_def.gopath(unsafe_entity, unsafe_entity._bed, nil, true))
	assert(unsafe_entity._villages_bed_route.reason:find("no safe standing", 1, true))
end
support_node = "test:stair"
local stair_support_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(def.gopath(stair_support_entity, stair_support_entity._bed, nil, true))
settle()
support_node = "stone"

local cooldown_called = false
local cooldown_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function()
		cooldown_called = true
		return true
	end,
}
dofile("navigation.lua")(cooldown_def)
local cooldown_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand", _pf_last_failed = os.time(),
	ready_to_path = function() return false end,
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(not cooldown_def.gopath(cooldown_entity, cooldown_entity._bed, nil, true))
assert(not cooldown_called)
assert(cooldown_entity._villages_bed_route.reason == "legacy pathfinder cooldown")

local fallback_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return false end,
}
dofile("navigation.lua")(fallback_def)
local fallback_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(fallback_def.gopath(fallback_entity, fallback_entity._bed, nil, true))
settle()
assert(fallback_entity.state == "gowp")
assert(fallback_entity.current_target and fallback_entity.waypoints)

local door_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return false end,
}
dofile("navigation.lua")(door_def)
path_available = false
wooden_door = true
local door_node = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	-- Force the only valid bed approach to be beyond the door; otherwise the
	-- cost-aware planner correctly chooses a shorter route around it.
	if pos.y == -1 and pos.z ~= 0 then return {name = "air"} end
	return door_node(pos)
end
local door_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(door_def.gopath(door_entity, door_entity._bed, nil, true))
settle()
local opens_door = door_entity.current_target.action and door_entity.current_target.action.action == "open"
for _, waypoint in ipairs(door_entity.waypoints) do
	if waypoint.action and waypoint.action.action == "open" then opens_door = true end
end
assert(opens_door)
minetest.get_node_or_nil = door_node
wooden_door = false
path_available = true

-- A waypoint's action fires when the mover leaves it for the next one. When
-- the destination sits just past a door, the door is the second-to-last
-- waypoint and the destination itself is last, so a close action attached to
-- the destination would never fire. It must close on arrival instead (#60).
local trailing_close_action = nil
local trailing_door_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return false end,
	do_pathfind_action = function(_, action) trailing_close_action = action end,
}
dofile("navigation.lua")(trailing_door_def)
path_available = false
local trailing_door_node = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	if pos.y == -1 and pos.z ~= 0 then return {name = "air"} end
	if pos.x == 2 and pos.y == 0 and pos.z == 0 then return {name = "mcl_doors:wooden_door_b_1"} end
	return trailing_door_node(pos)
end
local trailing_door_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	do_pathfind_action = trailing_door_def.do_pathfind_action,
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(trailing_door_def.gopath(trailing_door_entity, trailing_door_entity._bed, nil, true))
settle()
local no_close_waypoint = trailing_door_entity.current_target.action == nil
for _, waypoint in ipairs(trailing_door_entity.waypoints) do
	if waypoint.action and waypoint.action.action == "close" then no_close_waypoint = false end
end
assert(no_close_waypoint, "a close action must not be attached to the final waypoint")
trailing_door_entity.callback_arrived(trailing_door_entity)
assert(trailing_close_action and trailing_close_action.action == "close" and trailing_close_action.target.x == 2,
	"arrival must close the door just behind the destination")

-- A stale native callback from a superseded route must not close its old
-- trailing door, just as it must not complete the wrapped arrival callback.
trailing_close_action = nil
local superseded_trailing_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	do_pathfind_action = trailing_door_def.do_pathfind_action,
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(trailing_door_def.gopath(superseded_trailing_entity, superseded_trailing_entity._bed, nil, true))
settle()
local stale_trailing_arrived = superseded_trailing_entity.callback_arrived
superseded_trailing_entity.state = "stand"
assert(trailing_door_def.gopath(superseded_trailing_entity, superseded_trailing_entity._bed, nil, true))
settle()
stale_trailing_arrived(superseded_trailing_entity)
assert(not trailing_close_action, "a superseded route must not close its old trailing door")
minetest.get_node_or_nil = trailing_door_node
path_available = true

-- A stair presents a full vertical face from the side, not just the low front
-- face. The fallback planner must jump directly onto it from any cardinal
-- direction rather than needing to detour to a particular facing side (#64).
local stair_side_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return false end,
}
dofile("navigation.lua")(stair_side_def)
path_available = false
local stair_side_node = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	if pos.x == 0 and pos.y == 1 and pos.z == 0 then return {name = "mcl_beds:bed_red_bottom"} end
	if pos.x == 0 and pos.y == 0 and pos.z == 0 then return {name = "air"} end
	-- The only support at the bed's height is the top of this stair, one node
	-- to its side rather than in front of it.
	if pos.x == 1 and pos.y == 0 and pos.z == 0 then return {name = "test:stair"} end
	-- Support only the corridor leading to that side. Every other direction
	-- into the bed's approach is unsupported, so reaching it can only happen
	-- by jumping onto the stair from here, not by detouring to some other
	-- side the default floor would otherwise make just as easy.
	if pos.y == -1 and not (pos.z == 0 and pos.x >= 1) then return {name = "air"} end
	return stair_side_node(pos)
end
local stair_side_entity = {
	_bed = {x = 0, y = 1, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(stair_side_def.gopath(stair_side_entity, stair_side_entity._bed, nil, true))
settle()
assert(stair_side_entity._target and stair_side_entity._target.x == 1
	and stair_side_entity._target.y == 1 and stair_side_entity._target.z == 0,
	"the planner must reach the bed by jumping onto the stair from its side")
-- Pin the actual rise edge, not just the final target, so a regression that
-- reached the same target by some other means would still be caught.
local side_rise = stair_side_entity.waypoints[#stair_side_entity.waypoints - 1].pos
local side_arrival = stair_side_entity.waypoints[#stair_side_entity.waypoints].pos
assert(side_rise.x == 2 and side_rise.y == 0 and side_rise.z == 0
	and side_arrival.x == 1 and side_arrival.y == 1 and side_arrival.z == 0,
	"the route must rise directly from the stair's side, not some other approach")
minetest.get_node_or_nil = stair_side_node
path_available = true

local proactive_target = nil
local proactive_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function(self, target)
		proactive_target = target
		self.state = "gowp"
		return true
	end,
}
dofile("navigation.lua")(proactive_def)
local proactive_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "walk",
	gopath = proactive_def.gopath,
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
-- Supply the bed claim required by the proactive controller. A player claim on
-- either bed half must suppress the trip, just as it suppresses sleeping.
local top_claimed_by_player = false
minetest.get_meta = function(pos)
	return {get_string = function(_, name)
		if name == "villager" and pos.y == 0
			and (pos.x == 0 or (jobsite_claimed and pos.x == 10)) then return "villager-1" end
		if name == "player" and top_claimed_by_player and pos.y == 1 then return "player" end
		return ""
	end}
end
proactive_def.do_custom(proactive_entity, 0.1)
settle()
assert(proactive_target and not (proactive_target.x == 0 and proactive_target.z == 0))
assert(proactive_entity._villages_bed_route.status == "travelling")

top_claimed_by_player = true
proactive_target = nil
local blocked_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "walk",
	gopath = proactive_def.gopath,
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
proactive_def.do_custom(blocked_entity, 0.1)
settle()
assert(not proactive_target)
assert(not blocked_entity._villages_bed_route)

-- A villager already standing near its claimed bed at nightfall needs no
-- trip, but must still get order = "sleep" promptly rather than waiting on
-- VoxeLibre's five-second do_activity poll (#61).
top_claimed_by_player = false
proactive_target = nil
local already_home_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "stand",
	gopath = proactive_def.gopath,
	object = {
		get_pos = function() return {x = 1, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
proactive_def.do_custom(already_home_entity, 0.1)
settle()
assert(not proactive_target, "an already-close villager must not be sent on a bed trip")
assert(already_home_entity.order == "sleep",
	"an already-close villager must get order = sleep immediately, not after VoxeLibre's poll")

-- VoxeLibre chooses and claims the jobsite. During its existing work periods,
-- adapt only the trip to that claimed solid node into a safe approach route.
timeofday = 0.4
local job_target, job_arrived, callback_target = nil, nil, nil
local job_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function(self, target, callback)
		job_target, job_arrived = target, callback
		self.state = "gowp"
		return true
	end,
}
dofile("navigation.lua")(job_def)
local job_entity = {
	_id = "villager-1", _jobsite = {x = 10, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 15, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
timeofday = 0.7
assert(job_def.gopath(job_entity, job_entity._jobsite, nil, true))
settle()
assert(job_target.x == 10 and job_target.z == 0)
assert(not job_entity._villages_job_route)

timeofday = 0.4
assert(job_def.gopath(job_entity, job_entity._jobsite, function(_, target)
	callback_target = target
end, true))
assert(job_target and not (job_target.x == 10 and job_target.z == 0))
assert(job_entity._villages_job_route.status == "travelling")
job_arrived(job_entity)
assert(job_entity._villages_job_route.status == "arrived")
assert(callback_target and callback_target.x == job_target.x and callback_target.z == job_target.z)

-- Getting off the top of a stair is a plain one-node drop to a lower,
-- supported neighbor; it must not be treated as needing a detour around to
-- the stair's low front face (#64).
local off_stair_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return false end,
}
dofile("navigation.lua")(off_stair_def)
path_available = false
local off_stair_node = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	if pos.x == 9 and pos.y == 0 and pos.z == 0 then return {name = "test:stair"} end
	return off_stair_node(pos)
end
local off_stair_entity = {
	_id = "villager-1", _jobsite = {x = 10, y = 0, z = 0}, state = "stand",
	object = {
		-- Standing on top of the stair, one node higher and to the side of the
		-- jobsite's own approach column.
		get_pos = function() return {x = 9, y = 1, z = 0} end,
		set_velocity = function() end,
	},
}
assert(off_stair_def.gopath(off_stair_entity, off_stair_entity._jobsite, nil, true))
settle()
assert(off_stair_entity.current_target and #off_stair_entity.waypoints == 0,
	"stepping off the stair must be a direct one-node drop, not a detour")
minetest.get_node_or_nil = off_stair_node
path_available = true

jobsite_present = false
job_entity._villages_job_route = nil
assert(job_def.gopath(job_entity, job_entity._jobsite, nil, true))
settle()
assert(job_target.x == 10 and job_target.z == 0)

-- When native look_for_job sends its nearest raw node to gopath, redirect the
-- trip to the nearest *reachable* free station.  The first candidate lacks a
-- safe cardinal approach; importantly, no claim is made by this layer.
jobsite_present = true
jobsite_claimed = false
search_sites = {{x = 20, y = 0, z = 0}, {x = 30, y = 0, z = 0}}
local original_node = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	if pos.y == -1 and pos.x >= 19 and pos.x <= 21 then return {name = "air"} end
	return original_node(pos)
end
local searching_entity = {
	_id = "villager-1", state = "stand",
	object = {
		get_pos = function() return {x = 15, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(job_def.gopath(searching_entity, {x = 10, y = 0, z = 0}, nil, true))
settle()
assert(job_target and job_target.x >= 29)
assert(searching_entity._villages_job_search_route.status == "travelling")
assert(not searching_entity._jobsite)
minetest.get_node_or_nil = original_node
search_sites = {}
jobsite_claimed = true

-- A first jobsite is selected by route cost, not straight-line distance. The
-- farther station has the short path and must win over the nearer long route.
jobsite_claimed = false
search_sites = {{x = 20, y = 0, z = 0}, {x = 30, y = 0, z = 0}}
engine_paths = {
	["21:0:0"] = path_with_length(10),
	["31:0:0"] = path_with_length(2),
}
local cost_aware_job_entity = {
	_id = "villager-1", state = "stand",
	object = {
		get_pos = function() return {x = 15, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(job_def.gopath(cost_aware_job_entity, {x = 10, y = 0, z = 0}, nil, true))
settle()
assert(job_target.x == 31 and job_target.z == 0)
engine_paths = nil
search_sites = {}
jobsite_claimed = true

-- A search with no viable station is reported as a local retry instead of
-- sending the villager back to the known-bad raw-node route.
jobsite_claimed = false
search_sites = {{x = 20, y = 0, z = 0}}
minetest.get_node_or_nil = function(pos)
	if pos.y == -1 and pos.x >= 19 and pos.x <= 21 then return {name = "air"} end
	return original_node(pos)
end
local no_site_entity = {
	_id = "villager-1", state = "stand",
	object = {
		get_pos = function() return {x = 15, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(job_def.gopath(no_site_entity, {x = 10, y = 0, z = 0}, nil, true))
assert(no_site_entity._villages_job_search_route.status == "planning", "the search waits its turn")
settle()
assert(no_site_entity._villages_job_search_route.status == "retry")
assert(no_site_entity._villages_job_search_route.reason == "no reachable unclaimed workstation")
local scans_after_failure = job_search_scans
assert(not job_def.gopath(no_site_entity, {x = 10, y = 0, z = 0}, nil, true))
assert(job_search_scans == scans_after_failure, "job-search retry must not rescan during its cooldown")
minetest.get_node_or_nil = original_node
search_sites = {}
jobsite_claimed = true

-- A cleric's pulpit (cleric.lua) is claimed by this mod, not vanilla, but trips
-- to it get the same managed routes: a search trip arrives beside the pulpit,
-- and the commute to a claimed one falls back to the planner when the legacy
-- pathfinder fails (#125).
local pulpit_claimed = false
local pulpit_node, pulpit_meta = minetest.get_node_or_nil, minetest.get_meta
minetest.get_node_or_nil = function(pos)
	if pos.x == 40 and pos.y == 0 and pos.z == 0 then return {name = "living_villages:pulpit"} end
	return pulpit_node(pos)
end
minetest.get_meta = function(pos)
	if pos.x == 40 and pos.y == 0 and pos.z == 0 then
		return {get_string = function(_, name)
			return name == "villager" and pulpit_claimed and "villager-1" or ""
		end}
	end
	return pulpit_meta(pos)
end
local pulpit_arrivals = 0
local pulpit_seeker = {
	_id = "villager-1", state = "stand",
	object = {get_pos = function() return {x = 35, y = 0, z = 0} end, set_velocity = function() end},
}
assert(job_def.gopath(pulpit_seeker, {x = 40, y = 0, z = 0}, function() pulpit_arrivals = pulpit_arrivals + 1 end, true))
settle()
assert(job_target and math.abs(job_target.x - 40) + math.abs(job_target.z) == 1 and job_target.y == 0,
	"a pulpit trip ends on a cardinal neighbor, where the claim on arrival finds it")
assert(pulpit_seeker._villages_job_search_route.status == "travelling")
job_arrived(pulpit_seeker)
assert(pulpit_arrivals == 1 and pulpit_seeker._villages_job_search_route.status == "arrived")

local failing_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return false end,
}
dofile("navigation.lua")(failing_def)
path_available = false
pulpit_claimed = true
local pulpit_cleric = {
	_id = "villager-1", _jobsite = {x = 40, y = 0, z = 0}, state = "stand",
	object = {get_pos = function() return {x = 35, y = 0, z = 0} end, set_velocity = function() end},
}
assert(failing_def.gopath(pulpit_cleric, pulpit_cleric._jobsite, nil, true),
	"the planner takes over when the legacy pathfinder fails")
settle()
assert(pulpit_cleric._villages_job_route.status == "travelling" and pulpit_cleric._villages_job_route.mode == "planner")
minetest.get_node_or_nil, minetest.get_meta = pulpit_node, pulpit_meta
pulpit_claimed = false
path_available = true

-- If an accepted bed route stalls, planner recovery must retain the original
-- caller's arrival callback just as it does for jobsites.
jobsite_present = true
path_available = false
top_claimed_by_player = false
local bed_callback_called = false
local recovery_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function(self)
		self.state = "gowp"
		return true
	end,
}
dofile("navigation.lua")(recovery_def)
local recovery_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
timeofday = 0.8
assert(recovery_def.gopath(recovery_entity, recovery_entity._bed, function()
	bed_callback_called = true
end, true))
recovery_entity.state = "stand"
recovery_def.do_custom(recovery_entity, 0.1)
settle()
assert(recovery_entity.state == "gowp")
recovery_entity.callback_arrived(recovery_entity)
assert(bed_callback_called)
path_available = true

-- A fallback planner failure is preserved in route diagnostics instead of being
-- reported as a generic native-path cancellation.
local exhausted_recovery_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(recovery_def.gopath(exhausted_recovery_entity, exhausted_recovery_entity._bed, nil, true))
settle()
exhausted_recovery_entity.state = "stand"
support_available = false
local no_bed_approach_node = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	if pos.y == -1 and pos.x >= 4 then return {name = "stone"} end
	return no_bed_approach_node(pos)
end
recovery_def.do_custom(exhausted_recovery_entity, 0.1)
settle()
assert(exhausted_recovery_entity._villages_bed_route.status == "retry")
assert(exhausted_recovery_entity._villages_bed_route.reason:find("stair planner", 1, true))
assert(exhausted_recovery_entity._villages_bed_route.reason:find("after 0 nodes", 1, true))
assert(exhausted_recovery_entity._villages_bed_route.planner.searched == 0)
minetest.get_node_or_nil = no_bed_approach_node
support_available = true

-- A wooden door that becomes iron after planning causes an immediate bounded
-- replan instead of waiting for the no-progress watchdog.
local changed_door_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "gowp",
	_villages_bed_route = {status = "travelling", mode = "legacy", id = 1, target = {x = -1, y = 0, z = 0}},
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
iron_door = true
recovery_def.do_pathfind_action(changed_door_entity, {
	type = "door", action = "open", target = {x = 1, y = 0, z = 0},
})
assert(changed_door_entity._villages_blocked_door)
recovery_def.do_custom(changed_door_entity, 0.1)
settle()
assert(changed_door_entity.state == "gowp")
assert(changed_door_entity._villages_bed_route.mode == "planner")
iron_door = false

-- A work-period interruption invalidates a farm route and its chosen crop as
-- one unit, so farmer.lua can choose a fresh crop next time work begins.
timeofday = 0.7
local interrupted_farmer = {
	_villages_farm_target = {x = 2, y = 0, z = 0},
	_villages_farm_route = {status = "travelling"},
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
job_def.do_custom(interrupted_farmer, 0.1)
settle()
assert(not interrupted_farmer._villages_farm_route)
assert(not interrupted_farmer._villages_farm_target)

-- #72: a fisherman travels to a stand at the water's edge, mirroring the
-- farm-plot destination but standing beside the water rather than at an
-- already-claimed node.
timeofday = 0.4
local fish_site = {x = 50, y = 0, z = 0}
water_source_nodes[fish_site.x .. ":" .. fish_site.y .. ":" .. fish_site.z] = "mcl_core:water_source"
local fish_entity = {
	_id = "villager-1", _villages_fish_target = vector.new(fish_site), state = "stand",
	object = {
		get_pos = function() return {x = 55, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
local fish_arrived_called = false
assert(job_def.gopath(fish_entity, fish_entity._villages_fish_target, function()
	fish_arrived_called = true
end, true))
assert(job_target and not (job_target.x == fish_site.x and job_target.z == fish_site.z),
	"the fisherman must stand beside the water, not on it")
assert(fish_entity._villages_fish_route.status == "travelling")
job_arrived(fish_entity)
assert(fish_entity._villages_fish_route.status == "arrived")
assert(fish_arrived_called)

-- A stand already occupied by another loaded villager is skipped for an
-- unoccupied one instead of failing the whole route.
fish_entity._villages_fish_route = nil
local original_objects_near = minetest.get_objects_inside_radius
local occupied_stand = {x = fish_site.x + 1, y = 0, z = fish_site.z}
minetest.get_objects_inside_radius = function(pos)
	if pos.x == occupied_stand.x and pos.y == occupied_stand.y and pos.z == occupied_stand.z then
		return {{get_luaentity = function() return {name = "mobs_mc:villager"} end}}
	end
	return {}
end
assert(job_def.gopath(fish_entity, fish_entity._villages_fish_target, nil, true))
settle()
assert(not (job_target.x == occupied_stand.x and job_target.z == occupied_stand.z),
	"an occupied stand must be skipped for another candidate")
minetest.get_objects_inside_radius = original_objects_near

-- Every candidate stand occupied is reported as no safe standing space,
-- exactly like a bed or jobsite with no free approach.
fish_entity._villages_fish_route = nil
nearby_objects = {{get_luaentity = function() return {name = "mobs_mc:villager"} end}}
assert(not job_def.gopath(fish_entity, fish_entity._villages_fish_target, nil, true))
assert(fish_entity._villages_fish_route.status == "retry")
assert(fish_entity._villages_fish_route.reason:find("no safe standing", 1, true))
nearby_objects = {}

-- #72 review fix: a natural shore commonly sits a block above the water's
-- own surface (sand or dirt right up to and including the water's own y
-- level), so the walkable stand is the block on top of that shore, not
-- beside it at the water's own height. raised_ok must find that stand
-- instead of reporting "no safe standing space" against an anchor whose
-- only dry neighbors are solid ground, not open air, at the water's height.
local raised_fish_site = {x = 60, y = 0, z = 0}
water_source_nodes[raised_fish_site.x .. ":" .. raised_fish_site.y .. ":" .. raised_fish_site.z] = "mcl_core:water_source"
for _, offset in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
	local shore = {x = raised_fish_site.x + offset[1], y = raised_fish_site.y, z = raised_fish_site.z + offset[2]}
	raised_shore_nodes[shore.x .. ":" .. shore.y .. ":" .. shore.z] = "stone"
end
local raised_fish_entity = {
	_id = "villager-1", _villages_fish_target = vector.new(raised_fish_site), state = "stand",
	object = {
		get_pos = function() return {x = 65, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(job_def.gopath(raised_fish_entity, raised_fish_entity._villages_fish_target, nil, true),
	"a raised (sand-at-water-level) shore must still yield a route, not \"no safe standing space\"")
assert(job_target and job_target.y == 1,
	"the stand must be one block above the water's own height, on top of the shore")
water_source_nodes[raised_fish_site.x .. ":" .. raised_fish_site.y .. ":" .. raised_fish_site.z] = nil
raised_shore_nodes = {}

-- A work-period interruption invalidates a fish route and its target as one
-- unit, so fisherman.lua can choose a fresh spot next time work begins.
timeofday = 0.7
local interrupted_fisherman = {
	_villages_fish_target = {x = 2, y = 0, z = 0},
	_villages_fish_route = {status = "travelling"},
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
job_def.do_custom(interrupted_fisherman, 0.1)
settle()
assert(not interrupted_fisherman._villages_fish_route)
assert(not interrupted_fisherman._villages_fish_target)
water_source_nodes[fish_site.x .. ":" .. fish_site.y .. ":" .. fish_site.z] = nil

-- A close action waits while another villager is actively crossing the same
-- wooden door, then uses the normal mob close action once the doorway clears.
wooden_door = true
local closed_action = nil
local door_action_def = {
	on_activate = function() end,
	do_custom = function() return false end,
	gopath = function() end,
	do_pathfind_action = function(_, action) closed_action = action end,
}
dofile("navigation.lua")(door_action_def)
local door_entity = {
	state = "gowp",
	object = {
		set_velocity = function() end,
		get_pos = function() return {x = 0, y = 0, z = 0} end,
		get_luaentity = function() return {name = "mobs_mc:villager", state = "gowp"} end,
	},
}
nearby_objects = {{
	get_luaentity = function() return {name = "mobs_mc:villager", state = "gowp"} end,
}}
local close = {type = "door", action = "close", target = {x = 1, y = 0, z = 0}}
door_action_def.do_pathfind_action(door_entity, close)
assert(not closed_action)
assert(globalstep)
-- The initiating villager can still be pathfinding just past the doorway; it
-- must not prevent its own deferred close from being retried.
nearby_objects = {door_entity.object}
door_action_def.on_activate(door_entity)
globalstep(0.1)
assert(closed_action == close)
wooden_door = false

-- The door cell of #121 is entered from the north and left to the east, and the
-- door was left open with its leaf along the east edge. Vanilla leaves an open
-- door alone, and the villager pushes at the leaf; closing it swings the leaf
-- to the south edge and clears the turn.
local turn_actions = {}
local turn_def = {
	on_activate = function() end,
	do_custom = function() return false end,
	gopath = function() end,
	do_pathfind_action = function(_, action) table.insert(turn_actions, action) end,
}
dofile("navigation.lua")(turn_def)
local function door_walker(from, to)
	return {
		state = "gowp",
		object = {set_velocity = function() end, get_pos = function() return from end},
		current_target = {pos = from},
		waypoints = {{pos = {x = 1, y = 0, z = 0}}, {pos = to}},
	}
end
local open_door = {type = "door", action = "open", target = {x = 1, y = 0, z = 0}}
wooden_door = true
door_name, door_param2 = "mcl_doors:spruce_door_b_2", 3
turn_def.do_pathfind_action(door_walker({x = 1, y = 0, z = -1}, {x = 2, y = 0, z = 0}), open_door)
assert(#turn_actions == 1 and turn_actions[1].action == "close"
	and turn_actions[1].target.x == 1, "an open door whose leaf blocks the turn must be closed")
-- A straight crossing from the north is clear of that leaf, so it stays as it is.
turn_actions = {}
turn_def.do_pathfind_action(door_walker({x = 1, y = 0, z = -1}, {x = 1, y = 0, z = 1}), open_door)
assert(#turn_actions == 0)
-- A closed door in the way of a straight crossing is opened, as before.
door_name, door_param2 = "mcl_doors:wooden_door_b_1", 0
turn_def.do_pathfind_action(door_walker({x = 1, y = 0, z = -1}, {x = 1, y = 0, z = 1}), open_door)
assert(#turn_actions == 1 and turn_actions[1].action == "open")
-- The native mover fires a second open action from the door cell itself. It
-- must keep the entry the first one saw, not read the entry as empty and swing
-- a closed door's leaf onto the edge the villager is still coming in by.
turn_actions = {}
door_name, door_param2 = "mcl_doors:wooden_door_b_1", 0
local native = door_walker({x = 0, y = 0, z = 0}, {x = 2, y = 0, z = 0})
native.current_target = {pos = {x = 0, y = 0, z = 0}}
turn_def.do_pathfind_action(native, open_door)
native.current_target = table.remove(native.waypoints, 1)
turn_def.do_pathfind_action(native, open_door)
assert(#turn_actions == 0, "both actions must leave the door as the first chose")
door_name, door_param2 = "mcl_doors:spruce_door_b_2", 3
-- A route with no way through the door's cell in either state is reported
-- blocked so that the villager replans, and the door is left alone.
turn_actions = {}
door_name, door_param2 = "mcl_doors:spruce_door_b_2", 3
local diagonal = door_walker({x = 1, y = 0, z = -1}, {x = 0, y = 0, z = 1})
diagonal.current_target.pos = {x = 2, y = 0, z = -1}
turn_def.do_pathfind_action(diagonal, open_door)
assert(#turn_actions == 0 and diagonal._villages_blocked_door)
-- Without a route to judge by, the action is vanilla's.
turn_def.do_pathfind_action({object = {set_velocity = function() end}}, open_door)
assert(#turn_actions == 1 and turn_actions[1] == open_door)
wooden_door = false
door_name, door_param2 = "mcl_doors:wooden_door_b_1", nil

-- A native gopath implementation may set its active state before returning a
-- falsey value. That is still a successfully started route to callers.
local falsey_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function(self)
		self.state = "gowp"
		return false
	end,
}
dofile("navigation.lua")(falsey_def)
timeofday = 0.8
local falsey_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(falsey_def.gopath(falsey_entity, falsey_entity._bed, nil, true))
settle()
assert(falsey_entity._villages_bed_route.status == "travelling")

-- A canceled or superseded route must not run its old arrival callback.
local callbacks = {}
local ownership_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function(self, _, callback)
		self.state = "gowp"
		table.insert(callbacks, callback)
		return true
	end,
}
dofile("navigation.lua")(ownership_def)
local ownership_callback_calls = 0
local ownership_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
assert(ownership_def.gopath(ownership_entity, ownership_entity._bed, function()
	ownership_callback_calls = ownership_callback_calls + 1
end, true))
local first_route_id = ownership_entity._villages_bed_route.id
ownership_entity.state = "stand"
assert(ownership_def.gopath(ownership_entity, ownership_entity._bed, function()
	ownership_callback_calls = ownership_callback_calls + 1
end, true))
assert(ownership_entity._villages_bed_route.id ~= first_route_id)
callbacks[1](ownership_entity)
assert(ownership_entity._villages_bed_route.status == "travelling")
assert(ownership_callback_calls == 0)
callbacks[2](ownership_entity)
assert(ownership_entity._villages_bed_route.status == "arrived")
assert(ownership_callback_calls == 1)

-- Following cancels an owned route instead of allowing recovery to override the
-- player's instruction on the next villager tick.
local following_entity = {
	following = {}, state = "gowp",
	_villages_bed_route = {status = "travelling", id = 1},
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
ownership_def.do_custom(following_entity, 0.1)
settle()
assert(not following_entity._villages_bed_route)
assert(following_entity.state == "stand")

-- If the native mover remains in gowp without positional progress, hand the
-- route to the planner rather than leaving the villager stuck forever.
local stalled_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function(self)
		self.state = "gowp"
		return true
	end,
}
dofile("navigation.lua")(stalled_def)
local stalled_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
now = 500
assert(stalled_def.gopath(stalled_entity, stalled_entity._bed, nil, true))
settle()
local stalled_route_id = stalled_entity._villages_bed_route.id
now = now + 21
stalled_def.do_custom(stalled_entity, 0.1)
settle()
assert(stalled_entity.state == "gowp")
assert(stalled_entity._villages_bed_route.mode == "planner")
assert(stalled_entity._villages_bed_route.id ~= stalled_route_id)

-- Reloading a villager with an owned route clears the native waypoint state as
-- well as Villages' bookkeeping, avoiding an unmanaged resumed trip.
local activated_entity = {
	state = "gowp", _target = {x = 1}, current_target = {pos = {x = 1}}, waypoints = {},
	callback_arrived = function() end,
	_villages_bed_route = {status = "travelling", id = 1},
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
stalled_def.on_activate(activated_entity)
assert(activated_entity.state == "stand")
assert(not activated_entity._target and not activated_entity.current_target and not activated_entity.waypoints)
assert(not activated_entity.callback_arrived and not activated_entity._villages_bed_route)

-- The same reload cleanup applies to an in-progress fishing-spot route.
local activated_fisherman = {
	state = "gowp", _target = {x = 1}, current_target = {pos = {x = 1}}, waypoints = {},
	callback_arrived = function() end,
	_villages_fish_route = {status = "travelling", id = 1}, _villages_fish_target = {x = 1, y = 0, z = 0},
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
stalled_def.on_activate(activated_fisherman)
assert(activated_fisherman.state == "stand")
assert(not activated_fisherman._target and not activated_fisherman.current_target and not activated_fisherman.waypoints)
assert(not activated_fisherman.callback_arrived and not activated_fisherman._villages_fish_route)
assert(not activated_fisherman._villages_fish_target)

-- #71: an unemployed, bedded villager with no reachable workstation and a
-- qualifying pond near its bed is promoted to fisherman on the work-time
-- path.
timeofday = 0.4
now = 1000
path_available = true
support_available = true
support_node = "stone"
jobsite_present = false
search_sites = {}
engine_paths = nil
jobsite_claimed = true

local function place_pond(min_x, max_x, min_z, max_z, y)
	water_sites = {}
	for x = min_x, max_x do
		for z = min_z, max_z do
			local pos = {x = x, y = y, z = z}
			water_source_nodes[pos.x .. ":" .. pos.y .. ":" .. pos.z] = "mcl_core:water_source"
			table.insert(water_sites, pos)
		end
	end
end

local function clear_pond()
	water_sites, water_source_nodes = {}, {}
end

-- The promotion check staggers its first run after a gap by math.random();
-- pin it to no delay so each case below evaluates on its first tick.
local real_random = math.random
math.random = function() return 0 end

local promotion_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return true end,
}
dofile("navigation.lua")(promotion_def)

local function new_promotion_entity(overrides)
	local entity = {
		_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, _profession = "unemployed", state = "stand",
		object = {
			get_pos = function() return {x = 0, y = 0, z = 0} end,
			set_velocity = function() end,
		},
	}
	for key, value in pairs(overrides or {}) do entity[key] = value end
	return entity
end

water_scans = 0
place_pond(5, 7, -1, 1, 0)
local promoted_entity = new_promotion_entity()
promotion_def.do_custom(promoted_entity, 0.1)
settle()
assert(promoted_entity._profession == "fisherman", "a 3x3 pond must qualify for promotion")
assert(promoted_entity._villages_fisherman == true, "promotion must set the fisherman guard flag immediately")
assert(water_scans == 1)

-- Idempotent, and the cooldown suppresses a rescan on the very next tick.
promotion_def.do_custom(promoted_entity, 0.1)
settle()
assert(promoted_entity._profession == "fisherman")
assert(water_scans == 1, "the promotion evaluation must respect its cooldown")
clear_pond()

-- A 2x2 pool is not bigger than a 2x2 pool, so it does not qualify.
place_pond(5, 6, -1, 0, 0)
local small_pool_entity = new_promotion_entity()
promotion_def.do_custom(small_pool_entity, 0.1)
settle()
assert(small_pool_entity._profession == "unemployed", "a 2x2 pool must not qualify for promotion")
clear_pond()

-- A one-wide channel can hold more tiles than a 3x3 pond while still being
-- too narrow to fish from; the span check, not just the tile count, must
-- reject it.
place_pond(5, 20, 0, 0, 0)
local channel_entity = new_promotion_entity()
promotion_def.do_custom(channel_entity, 0.1)
settle()
assert(channel_entity._profession == "unemployed", "a one-wide channel must not qualify for promotion")
clear_pond()

-- The flood fill must not walk outside the search radius: find_nodes_in_area
-- only bounds the seed positions, so a one-wide channel that reaches the edge
-- of the radius and connects to a qualifying pond just beyond it must not
-- borrow that pond's footprint. Only the in-bounds channel tile at x=24 is a
-- seed; the 3x3 pond at x=25..27 sits entirely outside WATER_SEARCH_RADIUS.
water_source_nodes[24 .. ":0:0"] = "mcl_core:water_source"
water_sites = {{x = 24, y = 0, z = 0}}
for x = 25, 27 do
	for z = -1, 1 do
		water_source_nodes[x .. ":0:" .. z] = "mcl_core:water_source"
	end
end
local boundary_entity = new_promotion_entity()
promotion_def.do_custom(boundary_entity, 0.1)
settle()
assert(boundary_entity._profession == "unemployed",
	"a pond outside the search radius must not qualify, even reached from an in-bounds seed")
clear_pond()

-- The vertical search is asymmetric: a lake below a bed built on higher
-- ground is common, water hanging above one is rare, so downward reach is
-- wider than upward reach.
water_scans = 0
place_pond(5, 7, -1, 1, -6)
local below_entity = new_promotion_entity()
promotion_def.do_custom(below_entity, 0.1)
settle()
assert(below_entity._profession == "fisherman", "a qualifying pond 6 below the bed must be found")
clear_pond()

water_scans = 0
place_pond(5, 7, -1, 1, -7)
local too_deep_entity = new_promotion_entity()
promotion_def.do_custom(too_deep_entity, 0.1)
settle()
assert(too_deep_entity._profession == "unemployed", "a pond 7 below the bed must be outside the downward reach")
clear_pond()

water_scans = 0
place_pond(5, 7, -1, 1, 2)
local above_entity = new_promotion_entity()
promotion_def.do_custom(above_entity, 0.1)
settle()
assert(above_entity._profession == "fisherman", "a qualifying pond 2 above the bed must be found")
clear_pond()

water_scans = 0
place_pond(5, 7, -1, 1, 3)
local too_high_entity = new_promotion_entity()
promotion_def.do_custom(too_high_entity, 0.1)
settle()
assert(too_high_entity._profession == "unemployed", "a pond 3 above the bed must be outside the narrower upward reach")
clear_pond()

-- A reachable, unclaimed workstation suppresses promotion even beside
-- qualifying water.
water_scans = 0
place_pond(5, 7, -1, 1, 0)
jobsite_claimed = false
search_sites = {{x = 20, y = 0, z = 0}, {x = 30, y = 0, z = 0}}
engine_paths = {
	["21:0:0"] = path_with_length(5),
	["31:0:0"] = path_with_length(5),
}
local workstation_entity = new_promotion_entity({
	object = {
		get_pos = function() return {x = 15, y = 0, z = 0} end,
		set_velocity = function() end,
	},
})
promotion_def.do_custom(workstation_entity, 0.1)
settle()
assert(workstation_entity._profession == "unemployed", "a reachable workstation must suppress promotion")
assert(not workstation_entity._villages_fisherman)
assert(water_scans == 1, "water is checked before the workstation search")
engine_paths = nil
search_sites = {}
jobsite_claimed = true
clear_pond()

-- With no water near its bed, a villager never pays for the workstation
-- search, which pathfinds to every free site in range (#113).
water_scans = 0
jobsite_claimed = false
search_sites = {{x = 20, y = 0, z = 0}}
local path_calls = 0
local counted_find_path = minetest.find_path
minetest.find_path = function(...)
	path_calls = path_calls + 1
	return counted_find_path(...)
end
local dry_entity = new_promotion_entity()
promotion_def.do_custom(dry_entity, 0.1)
settle()
assert(water_scans == 1, "the water is checked")
assert(path_calls == 0, "no water means no workstation search")
assert(dry_entity._profession == "unemployed")
minetest.find_path = counted_find_path
search_sites = {}
jobsite_claimed = true

-- The first work tick after a gap (night, or loading) does not send every
-- eligible villager into the search at once: each gets its own offset (#113).
water_scans = 0
place_pond(5, 7, -1, 1, 0)
local offsets = {0.1, 0.5, 0.9}
local draw = 0
math.random = function()
	draw = draw + 1
	return offsets[draw] or 0
end
local morning = {}
for i = 1, 3 do
	morning[i] = new_promotion_entity({_villages_fisherman_check = now - 3600})
	promotion_def.do_custom(morning[i], 0.1)
end
assert(water_scans == 0, "no villager searches on the first tick back at work")
local start = now
local promoted_at = {}
for _ = 1, 30 do
	now = now + 1
	for i = 1, 3 do
		promotion_def.do_custom(morning[i], 0.1)
		settle()
		if not promoted_at[i] and morning[i]._profession == "fisherman" then promoted_at[i] = now - start end
	end
end
assert(promoted_at[1] == 3 and promoted_at[2] == 15 and promoted_at[3] == 27,
	"each villager's first check lands at its own offset: "
	.. tostring(promoted_at[1]) .. ", " .. tostring(promoted_at[2]) .. ", " .. tostring(promoted_at[3]))
math.random = function() return 0 end
clear_pond()

-- A bedless villager is never promoted, and never reaches the water search.
water_scans = 0
place_pond(5, 7, -1, 1, 0)
local bedless_entity = new_promotion_entity()
bedless_entity._bed = nil
promotion_def.do_custom(bedless_entity, 0.1)
settle()
assert(bedless_entity._profession == "unemployed", "a bedless villager must never be promoted")
assert(water_scans == 0, "a bedless villager must never reach the water search")
clear_pond()

-- Children and nitwits are never promoted, even beside qualifying water.
place_pond(5, 7, -1, 1, 0)
local child_entity = new_promotion_entity({child = true})
promotion_def.do_custom(child_entity, 0.1)
settle()
assert(child_entity._profession == "unemployed", "a child must never be promoted")

local nitwit_entity = new_promotion_entity({_profession = "nitwit"})
promotion_def.do_custom(nitwit_entity, 0.1)
settle()
assert(nitwit_entity._profession == "nitwit", "a nitwit must never be promoted")
clear_pond()

-- The flood fill terminates at its cap instead of exploring an entire large
-- lake; the capped region already exceeds the qualifying span, so promotion
-- still succeeds.
place_pond(0, 49, 0, 49, 0)
local lookup_calls = 0
local original_lookup = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	lookup_calls = lookup_calls + 1
	return original_lookup(pos)
end
local big_pond_entity = new_promotion_entity()
promotion_def.do_custom(big_pond_entity, 0.1)
settle()
minetest.get_node_or_nil = original_lookup
assert(big_pond_entity._profession == "fisherman", "a large lake must still qualify for promotion")
assert(lookup_calls < 500, "the flood fill must stop at its cap instead of scanning the whole lake")
clear_pond()

-- Regression test (#84): mcl_mobs serializes every field of the entity, so a
-- saved route writes its arrival callback into the staticdata as a dumped Lua
-- function. The engine has already deprecated dumping functions; once it stops
-- supporting them, core.deserialize returns nil for the whole string and the
-- villager loses every saved field -- its _id, bed, jobsite and trades -- with
-- its claims silently orphaned. on_activate discards routes anyway, so none of
-- this trip state may reach the save, and the live entity must keep it.
local saved_fields
local staticdata_def = {
	on_activate = function() end,
	do_custom = function() end,
	gopath = function() return true end,
	get_staticdata = function(self)
		saved_fields = {}
		for field, value in pairs(self) do saved_fields[field] = value end
		return "saved"
	end,
}
dofile("navigation.lua")(staticdata_def)

local travelling = {
	_villages_bed_route = {status = "travelling", callback = function() end},
	_villages_fish_target = {x = 1, y = 0, z = 1},
	_id = "zoe",
}
assert(staticdata_def.get_staticdata(travelling) == "saved")
assert(saved_fields._id == "zoe", "ordinary villager fields must still be saved")
assert(not saved_fields._villages_bed_route,
	"a route (and the live callback it holds) must not be written to staticdata")
assert(not saved_fields._villages_fish_target,
	"a trip target must not be written to staticdata")
assert(travelling._villages_bed_route and travelling._villages_fish_target,
	"the live villager must keep its trip state across a save")

-- Review of #162: polling, superseded detours and holding a waiting villager.
do
	timeofday = 0.8
	low_ceiling = true
	local hold_def = {
		on_activate = function() end,
		do_custom = function() end,
		gopath = function(self, target, callback)
			self.callback_arrived = callback
			self.current_target = {pos = {x = 2, y = 0, z = 0}}
			self.waypoints = {{pos = {x = 1, y = 0, z = 0}}, {pos = vector.new(target)}}
			self.state = "gowp"
			return true
		end,
	}
	dofile("navigation.lua")(hold_def)
	local function new_entity()
		return {
			_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "stand",
			object = {get_pos = function() return {x = 5, y = 0.5, z = 0} end, set_velocity = function() end},
		}
	end
	-- Polling while the search is queued keeps the one route and the one job.
	local polled = new_entity()
	assert(hold_def.gopath(polled, polled._bed, nil, true))
	local first_id = polled._villages_bed_route.id
	assert(polled._villages_bed_route.status == "planning")
	polled._pf_last_failed = os.time()
	assert(hold_def.gopath(polled, polled._bed, nil, true))
	assert(polled._villages_bed_route.id == first_id and polled._villages_bed_route.status == "planning",
		"a repeated gopath reuses the planning route")
	-- The villager is held on every tick, even if vanilla would walk it off.
	polled.state = "walk"
	assert(hold_def.do_custom(polled, 0.1) == false, "a planning villager skips vanilla's states")
	assert(polled.state == "stand", "and stands still")
	settle()
	assert(polled._villages_bed_route.status == "travelling" and polled._villages_bed_route.mode == "planner")
	assert(polled._villages_bed_route.id == first_id)

	-- A detour that a later trip superseded must not start.
	local first_callback, second_callback = function() end, function() end
	local detoured = new_entity()
	detoured._bed = nil
	detoured._jobsite = {x = 50, y = 0, z = 0}
	timeofday = 0.3
	assert(hold_def.gopath(detoured, {x = -2, y = 0, z = 0}, first_callback, true))
	assert(detoured.state == "stand" and hold_def.do_custom(detoured, 0.1) == false, "a detour waits in place")
	low_ceiling = false
	assert(hold_def.gopath(detoured, {x = 8, y = 0, z = 0}, second_callback, true))
	settle()
	timeofday = 0.8
	assert(detoured._target == nil or detoured._target.x == 8 or detoured.callback_arrived == second_callback)
	assert(detoured.callback_arrived == second_callback, "the superseded detour does not restore its callback")
	assert(detoured.waypoints[#detoured.waypoints].pos.x == 8, "nor its path")
	low_ceiling = false
end

-- With the setting on (#163) the planner chooses every route: the engine's
-- pathfinder and vanilla's gopath are never asked.
do
	planner_routes = true
	timeofday = 0.8
	low_ceiling, wooden_door, glass_pane = false, false, false
	local engine_calls, vanilla_calls = 0, 0
	local plain_find_path = minetest.find_path
	minetest.find_path = function(...) engine_calls = engine_calls + 1 return plain_find_path(...) end
	local planner_def = {
		on_activate = function() end,
		do_custom = function() end,
		gopath = function() vanilla_calls = vanilla_calls + 1 return false end,
	}
	dofile("navigation.lua")(planner_def)
	local function new_entity(bed)
		return {
			_id = "villager-1", _bed = bed and {x = 0, y = 0, z = 0}, state = "stand", order = "stand",
			gopath = function(...) return planner_def.gopath(...) end,
			object = {get_pos = function() return {x = 5, y = 0.5, z = 0} end, set_velocity = function() end},
		}
	end
	local function ends_at(entity, x)
		local last = entity.waypoints[#entity.waypoints] or entity.current_target
		return last.pos.x == x
	end

	-- A managed trip is planned, then walked by the legacy mover.
	local sleeper = new_entity(true)
	assert(planner_def.gopath(sleeper, sleeper._bed, nil, true))
	assert(sleeper._villages_bed_route.status == "planning" and sleeper._villages_bed_route.mode == "planner")
	assert(sleeper.state == "stand", "a villager waits where it is while the search runs")
	settle()
	assert(sleeper._villages_bed_route.status == "travelling" and sleeper.state == "gowp")
	assert(sleeper._target and sleeper.current_target, "the mover has its target and waypoint")
	sleeper.callback_arrived(sleeper)
	assert(sleeper.order == "sleep" and sleeper._villages_bed_route.status == "arrived")

	-- So is any other trip, to the target itself when a villager can stand there.
	local arrivals = {}
	local walker = new_entity()
	assert(planner_def.gopath(walker, {x = 8, y = 0, z = 0}, function(entity, target)
		table.insert(arrivals, target)
	end, true))
	assert(walker._villages_goto_route.status == "planning" and walker.order == nil)
	-- Polling the same request keeps its one search; another target replaces it.
	local goto_id = walker._villages_goto_route.id
	assert(planner_def.gopath(walker, {x = 8, y = 0, z = 0}, nil, true))
	assert(walker._villages_goto_route.id == goto_id)
	assert(planner_def.do_custom(walker, 0.1) == false, "a waiting villager is held")
	settle()
	assert(walker.state == "gowp" and ends_at(walker, 8) and walker._target.x == 8)
	assert(walker._villages_goto_route.status == "travelling")
	assert(planner_def.gopath(walker, {x = 9, y = 0, z = 0}, nil, true) == nil, "gopath does not interrupt a walk")
	walker.callback_arrived(walker)
	assert(#arrivals == 1 and arrivals[1].x == 8 and walker._villages_goto_route.status == "arrived")

	local changed = new_entity()
	local ignored = false
	assert(planner_def.gopath(changed, {x = 8, y = 0, z = 0}, function() ignored = true end, true))
	assert(planner_def.gopath(changed, {x = 9, y = 0, z = 0}, nil, true))
	settle()
	assert(ends_at(changed, 9) and not ignored, "the newer request is the one walked")

	-- A target in solid ground is approached from beside it.
	local beside = new_entity()
	jobsite_present = true
	assert(planner_def.gopath(beside, {x = 10, y = 0, z = 0}, nil, true))
	settle()
	assert(beside.state == "gowp")
	local last = beside.waypoints[#beside.waypoints].pos
	assert(math.abs(last.x - 10) <= 1 and math.abs(last.z) <= 1 and not (last.x == 10 and last.z == 0))

	-- The planner keeps the villager clear of an overhang, whoever asked.
	low_ceiling = true
	local ducker = new_entity()
	assert(planner_def.gopath(ducker, {x = -2, y = 0, z = 0}, nil, true))
	settle()
	assert(ducker.state == "gowp")
	for _, waypoint in ipairs(ducker.waypoints) do
		assert(not (waypoint.pos.x == 1 and waypoint.pos.z == 0), "no waypoint under the overhang")
	end
	low_ceiling = false

	-- vanilla's failure cooldown holds a request back, and a failed search sets it.
	local waiting = new_entity()
	function waiting:ready_to_path() return false end
	assert(planner_def.gopath(waiting, {x = 8, y = 0, z = 0}, nil, true) == nil)
	assert(waiting._villages_goto_route == nil and waiting.state == "stand")
	local cooling = new_entity(true)
	function cooling:ready_to_path() return false end
	assert(planner_def.gopath(cooling, cooling._bed, nil, true) == false)
	assert(cooling._villages_bed_route.status == "retry" and cooling._villages_bed_route.reason == "pathfinder cooldown")
	local trapped = new_entity()
	support_available = false
	assert(planner_def.gopath(trapped, {x = 8, y = 0, z = 0}, nil, true) == false, "nowhere to stand")
	support_available = true
	assert(trapped._villages_goto_route.status == "retry" and trapped._pf_last_failed, "a failed request sets the cooldown")
	assert(trapped.state == "stand")

	-- A walk that stops making progress is given up on.
	local stuck = new_entity()
	assert(planner_def.gopath(stuck, {x = 8, y = 0, z = 0}, nil, true))
	settle()
	now = now + 60
	assert(planner_def.do_custom(stuck, 0.1) ~= false)
	assert(stuck._villages_goto_route.status == "retry" and stuck.state == "stand")
	-- A trip another module's mover took over is dropped without a word.
	local taken = new_entity()
	assert(planner_def.gopath(taken, {x = 8, y = 0, z = 0}, nil, true))
	settle()
	taken.state = "stand"
	planner_def.do_custom(taken, 0.1)
	assert(taken._villages_goto_route == nil)

	-- The workstation search plans its routes too.
	search_sites = {{x = 20, y = 0, z = 0}, {x = 30, y = 0, z = 0}}
	jobsite_claimed = false
	local seeker = new_entity()
	timeofday = 0.3
	assert(planner_def.gopath(seeker, {x = 20, y = 0, z = 0}, nil, true))
	settle()
	assert(seeker._villages_job_search_route.status == "travelling" and seeker.state == "gowp")
	timeofday = 0.8
	search_sites = {}

	assert(engine_calls == 0, "the engine's pathfinder is never asked")
	assert(vanilla_calls == 0, "nor is vanilla's gopath")
	minetest.find_path = plain_find_path
	planner_routes = false
end

math.random = real_random

print("navigation.lua: ok")
