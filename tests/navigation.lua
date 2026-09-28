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
local water_sites = {}
local water_source_nodes = {}
local water_scans = 0

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
		local water_node = water_source_nodes[pos.x .. ":" .. pos.y .. ":" .. pos.z]
		if water_node then return {name = water_node} end
		if pos.y == -1 and support_available then return {name = support_node} end
		return {name = "air"}
	end,
	find_node_near = function() return nil end,
	find_nodes_in_area = function(minp, maxp, nodenames)
		if nodenames[1] == "group:water" then
			water_scans = water_scans + 1
			return water_sites
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
local stale_trailing_arrived = superseded_trailing_entity.callback_arrived
superseded_trailing_entity.state = "stand"
assert(trailing_door_def.gopath(superseded_trailing_entity, superseded_trailing_entity._bed, nil, true))
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
assert(off_stair_entity.current_target and #off_stair_entity.waypoints == 0,
	"stepping off the stair must be a direct one-node drop, not a detour")
minetest.get_node_or_nil = off_stair_node
path_available = true

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

-- A work-period interruption invalidates a fish route and its target as one
-- unit, so fisherman.lua can choose a fresh spot next time work begins.
timeofday = 0.5
local interrupted_fisherman = {
	_villages_fish_target = {x = 2, y = 0, z = 0},
	_villages_fish_route = {status = "travelling"},
	object = {
		get_pos = function() return {x = 5, y = 0, z = 0} end,
		set_velocity = function() end,
	},
}
job_def.do_custom(interrupted_fisherman, 0.1)
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
assert(promoted_entity._profession == "fisherman", "a 3x3 pond must qualify for promotion")
assert(promoted_entity._villages_fisherman == true, "promotion must set the fisherman guard flag immediately")
assert(water_scans == 1)

-- Idempotent, and the cooldown suppresses a rescan on the very next tick.
promotion_def.do_custom(promoted_entity, 0.1)
assert(promoted_entity._profession == "fisherman")
assert(water_scans == 1, "the promotion evaluation must respect its cooldown")
clear_pond()

-- A 2x2 pool is not bigger than a 2x2 pool, so it does not qualify.
place_pond(5, 6, -1, 0, 0)
local small_pool_entity = new_promotion_entity()
promotion_def.do_custom(small_pool_entity, 0.1)
assert(small_pool_entity._profession == "unemployed", "a 2x2 pool must not qualify for promotion")
clear_pond()

-- A one-wide channel can hold more tiles than a 3x3 pond while still being
-- too narrow to fish from; the span check, not just the tile count, must
-- reject it.
place_pond(5, 20, 0, 0, 0)
local channel_entity = new_promotion_entity()
promotion_def.do_custom(channel_entity, 0.1)
assert(channel_entity._profession == "unemployed", "a one-wide channel must not qualify for promotion")
clear_pond()

-- The flood fill must not walk outside the search radius: find_nodes_in_area
-- only bounds the seed positions, so a one-wide channel that reaches the edge
-- of the radius and connects to a qualifying pond just beyond it must not
-- borrow that pond's footprint. Only the in-bounds channel tile at x=16 is a
-- seed; the 3x3 pond at x=17..19 sits entirely outside WATER_SEARCH_RADIUS.
water_source_nodes[16 .. ":0:0"] = "mcl_core:water_source"
water_sites = {{x = 16, y = 0, z = 0}}
for x = 17, 19 do
	for z = -1, 1 do
		water_source_nodes[x .. ":0:" .. z] = "mcl_core:water_source"
	end
end
local boundary_entity = new_promotion_entity()
promotion_def.do_custom(boundary_entity, 0.1)
assert(boundary_entity._profession == "unemployed",
	"a pond outside the search radius must not qualify, even reached from an in-bounds seed")
clear_pond()

-- A reachable, unclaimed workstation suppresses promotion even beside
-- qualifying water, and the water search is never reached.
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
assert(workstation_entity._profession == "unemployed", "a reachable workstation must suppress promotion")
assert(not workstation_entity._villages_fisherman)
assert(water_scans == 0, "water must not be searched when a workstation is reachable")
engine_paths = nil
search_sites = {}
jobsite_claimed = true
clear_pond()

-- A bedless villager is never promoted, and never reaches the water search.
water_scans = 0
place_pond(5, 7, -1, 1, 0)
local bedless_entity = new_promotion_entity()
bedless_entity._bed = nil
promotion_def.do_custom(bedless_entity, 0.1)
assert(bedless_entity._profession == "unemployed", "a bedless villager must never be promoted")
assert(water_scans == 0, "a bedless villager must never reach the water search")
clear_pond()

-- Children and nitwits are never promoted, even beside qualifying water.
place_pond(5, 7, -1, 1, 0)
local child_entity = new_promotion_entity({child = true})
promotion_def.do_custom(child_entity, 0.1)
assert(child_entity._profession == "unemployed", "a child must never be promoted")

local nitwit_entity = new_promotion_entity({_profession = "nitwit"})
promotion_def.do_custom(nitwit_entity, 0.1)
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
minetest.get_node_or_nil = original_lookup
assert(big_pond_entity._profession == "fisherman", "a large lake must still qualify for promotion")
assert(lookup_calls < 500, "the flood fill must stop at its cap instead of scanning the whole lake")
clear_pond()

print("navigation.lua: ok")
