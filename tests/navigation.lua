local now = 100
local gopath_target, arrived, preflight_start, preflight_range = nil, nil, nil, nil
local path_available = true
local support_available = true
local wooden_door = false
local timeofday = 0.8
local jobsite_present = true
local nearby_objects = {}
local search_sites = {}
local jobsite_claimed = true

minetest = {
	registered_nodes = {
		["air"] = {walkable = false, liquidtype = "none"},
		["stone"] = {walkable = true},
		["mcl_beds:bed_red_bottom"] = {walkable = false, liquidtype = "none"},
		["mcl_composters:composter"] = {walkable = true},
		["mcl_doors:wooden_door_b_1"] = {walkable = false, liquidtype = "none"},
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
		if wooden_door and pos.x == 1 and pos.y == 0 and pos.z == 0 then
			return {name = "mcl_doors:wooden_door_b_1"}
		end
		if pos.y == -1 and support_available then return {name = "stone"} end
		return {name = "air"}
	end,
	find_node_near = function() return nil end,
	find_nodes_in_area = function() return search_sites end,
	get_item_group = function(name, group)
		return group == "bed" and name:find("bed", 1, true) and 1
			or group == "door" and name:find("door", 1, true) and 1 or 0
	end,
	find_path = function(start, _, range)
		preflight_start, preflight_range = start, range
		return path_available and {{x = 1, y = 0, z = 0}} or nil
	end,
	get_objects_inside_radius = function() return nearby_objects end,
	hash_node_position = function(pos) return pos.x .. ":" .. pos.y .. ":" .. pos.z end,
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
assert(preflight_start.y == 1 and preflight_range == 25)
assert(entity._villages_bed_route.status == "travelling")
arrived(entity)
assert(entity.order == "sleep")
assert(entity._villages_bed_route.status == "arrived")

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
	},
}
nearby_objects = {{
	get_luaentity = function() return {name = "mobs_mc:villager", state = "gowp"} end,
}}
local close = {type = "door", action = "close", target = {x = 1, y = 0, z = 0}}
door_action_def.do_pathfind_action(door_entity, close)
assert(not closed_action)
assert(door_entity._villages_pending_door_closes)
nearby_objects = {}
assert(door_action_def.do_custom(door_entity, 0.1) == false)
assert(closed_action == close)
assert(not next(door_entity._villages_pending_door_closes))
wooden_door = false

print("navigation.lua: ok")
