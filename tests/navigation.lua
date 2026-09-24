local now = 100
local gopath_target, arrived, preflight_start, preflight_range, preflight_found = nil, nil, nil, nil, nil
local path_available = true
local required_path_range = 0
local engine_paths = nil
local support_available = true
local support_node = "stone"
local wooden_door = false
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
			return {name = "mcl_doors:wooden_door_b_1"}
		end
		if pos.y == -1 and support_available then return {name = support_node} end
		return {name = "air"}
	end,
	find_node_near = function() return nil end,
	find_nodes_in_area = function()
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
	register_globalstep = function(callback) globalstep = callback end,
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
assert(gopath_target.x == -1 and gopath_target.z == 0)
low_ceiling = false

def.do_custom(entity, 0.1)
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
local opens_door = door_entity.current_target.action and door_entity.current_target.action.action == "open"
for _, waypoint in ipairs(door_entity.waypoints) do
	if waypoint.action and waypoint.action.action == "open" then opens_door = true end
end
assert(opens_door)
minetest.get_node_or_nil = door_node
wooden_door = false
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
assert(not proactive_target)
assert(not blocked_entity._villages_bed_route)

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
timeofday = 0.5
assert(job_def.gopath(job_entity, job_entity._jobsite, nil, true))
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

jobsite_present = false
job_entity._villages_job_route = nil
assert(job_def.gopath(job_entity, job_entity._jobsite, nil, true))
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
assert(not job_def.gopath(no_site_entity, {x = 10, y = 0, z = 0}, nil, true))
assert(no_site_entity._villages_job_search_route.status == "retry")
assert(no_site_entity._villages_job_search_route.reason == "no reachable unclaimed workstation")
local scans_after_failure = job_search_scans
assert(not job_def.gopath(no_site_entity, {x = 10, y = 0, z = 0}, nil, true))
assert(job_search_scans == scans_after_failure, "job-search retry must not rescan during its cooldown")
minetest.get_node_or_nil = original_node
search_sites = {}
jobsite_claimed = true

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
exhausted_recovery_entity.state = "stand"
support_available = false
local no_bed_approach_node = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	if pos.y == -1 and pos.x >= 4 then return {name = "stone"} end
	return no_bed_approach_node(pos)
end
recovery_def.do_custom(exhausted_recovery_entity, 0.1)
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
assert(changed_door_entity.state == "gowp")
assert(changed_door_entity._villages_bed_route.mode == "planner")
iron_door = false

-- A work-period interruption invalidates a farm route and its chosen crop as
-- one unit, so farmer.lua can choose a fresh crop next time work begins.
timeofday = 0.5
local interrupted_farmer = {
	_villages_farm_target = {x = 2, y = 0, z = 0},
	_villages_farm_route = {status = "travelling"},
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
job_def.do_custom(interrupted_farmer, 0.1)
assert(not interrupted_farmer._villages_farm_route)
assert(not interrupted_farmer._villages_farm_target)

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
local stalled_route_id = stalled_entity._villages_bed_route.id
now = now + 21
stalled_def.do_custom(stalled_entity, 0.1)
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

print("navigation.lua: ok")
