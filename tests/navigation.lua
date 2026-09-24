local now = 100
local gopath_target, arrived, preflight_start, preflight_range = nil, nil, nil, nil
local path_available = true
local support_available = true

minetest = {
	registered_nodes = {
		["air"] = {walkable = false, liquidtype = "none"},
		["stone"] = {walkable = true},
		["mcl_beds:bed_red_bottom"] = {walkable = false, liquidtype = "none"},
	},
	get_timeofday = function() return 0.8 end,
	get_gametime = function() return now end,
	get_modpath = function() return "." end,
	get_node_or_nil = function(pos)
		if pos.x == 0 and pos.y == 0 and pos.z == 0 then return {name = "mcl_beds:bed_red_bottom"} end
		if pos.y == -1 and support_available then return {name = "stone"} end
		return {name = "air"}
	end,
	find_node_near = function() return nil end,
	get_item_group = function(name, group)
		return group == "bed" and name:find("bed", 1, true) and 1 or 0
	end,
	find_path = function(start, _, range)
		preflight_start, preflight_range = start, range
		return path_available and {{x = 1, y = 0, z = 0}} or nil
	end,
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
		if name == "villager" and pos.y == 0 then return "villager-1" end
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

print("navigation.lua: ok")
