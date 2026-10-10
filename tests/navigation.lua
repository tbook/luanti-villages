local now = 100
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
		get_bool = function(_, _, default) return default end,
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
assert(entity._villages_bed_route.status == "travelling" and entity.state == "gowp")
assert(not (entity._target.x == 0 and entity._target.z == 0), "the walk ends beside the bed")
entity.callback_arrived(entity)
assert(entity.order == "sleep")
assert(entity._villages_bed_route.status == "arrived")

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
assert(pane_entity.state == "gowp" and not (pane_entity._target.x == 1 and pane_entity._target.z == 0))
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
assert(low_ceiling_entity.state == "gowp" and not (low_ceiling_entity._target.x == 1 and low_ceiling_entity._target.z == 0))
low_ceiling = false

-- The planner keeps the whole villager clear of anything at head height, like
-- the wall posts beside a tavern's steps (#93).
low_ceiling = true
local overhang_def = {
	on_activate = function() end,
	do_custom = function() end,
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
assert(overhang_entity.state == "gowp")
for _, waypoint in ipairs(overhang_entity.waypoints) do
	assert(not (waypoint.pos.x == 1 and waypoint.pos.z == 0), "the planner's route keeps clear of the overhang")
end

-- A trip this module does not otherwise manage (a keeper to its jukebox, a
-- guest to its seat) is planned the same way, to the target itself when a
-- villager can stand there.
local detour_arrivals = 0
local detour_arrived = function() detour_arrivals = detour_arrivals + 1 end
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
detour_entity.callback_arrived(detour_entity)
assert(detour_arrivals == 1, "and its own arrival callback")
for _, waypoint in ipairs(detour_entity.waypoints) do
	assert(not (waypoint.pos.x == 1 and waypoint.pos.z == 0), "the detour keeps clear of the overhang")
end
-- When no route exists, the failure is recorded so that vanilla's
-- ready_to_path holds off the next attempt.
support_available = false
local stuck_entity = {
	_jobsite = {x = 50, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 5, y = 0.5, z = 0} end,
		set_velocity = function() end,
	},
}
timeofday = 0.3
assert(overhang_def.gopath(stuck_entity, {x = -2, y = 0, z = 0}, nil, true) == false, "nowhere to stand")
settle()
timeofday = 0.8
assert(stuck_entity.state == "stand" and stuck_entity._pf_last_failed, "a failed trip sets the pathfinding cooldown")
support_available = true
low_ceiling = false

def.do_custom(entity, 0.1)
settle()
assert(entity._villages_bed_route.status == "arrived")

local failed_def = {
	on_activate = function() end,
	do_custom = function() end,
}
dofile("navigation.lua")(failed_def)
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

local cooldown_def = {
	on_activate = function() end,
	do_custom = function() end,
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
assert(cooldown_entity._villages_bed_route.reason == "pathfinder cooldown")

local fallback_def = {
	on_activate = function() end,
	do_custom = function() end,
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
}
dofile("navigation.lua")(door_def)
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

-- A route that starts on the cell in front of the door keeps that cell's open
-- action: the start waypoint is dropped as "already there", and with it the
-- action that opens the door, so the villager walked into the closed door and
-- stood there (#202).
local at_door_pos = {x = 2.4, y = 0, z = 0}
local door_actions = {}
local at_door_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return at_door_pos end,
		set_velocity = function() end,
		get_velocity = function() return vector.zero() end,
		get_yaw = function() return 0 end,
	},
	do_pathfind_action = function(_, action) table.insert(door_actions, action) end,
}
assert(door_def.gopath(at_door_entity, at_door_entity._bed, nil, true))
settle()
local door_in_front = at_door_entity.current_target.action and at_door_entity.current_target.action.action == "open"
assert(door_in_front, "a route starting in front of a door must still open it")
-- The follower works that door as its step once on the cell's centre.
local follower_def = {check_gowp = function() end}
dofile("follower.lua").install(follower_def)
at_door_pos = {x = 2, y = 0, z = 0}
follower_def.check_gowp(at_door_entity, 0.1)
assert(#door_actions == 1 and door_actions[1].action == "open" and door_actions[1].target.x == 1,
	"the follower must open the door at the start cell")

-- The same with the door cell itself as the destination.
local to_door_actions = {}
local to_door_pos = {x = 2.4, y = 0, z = 0}
local to_door_entity = {
	state = "stand",
	object = {
		get_pos = function() return to_door_pos end,
		set_velocity = function() end,
		get_velocity = function() return vector.zero() end,
		get_yaw = function() return 0 end,
	},
	do_pathfind_action = function(_, action) table.insert(to_door_actions, action) end,
}
assert(door_def.gopath(to_door_entity, {x = 1, y = 0, z = 0}, nil, true))
settle()
assert(to_door_entity.current_target.action and to_door_entity.current_target.action.action == "open",
	"a route to the door cell from the cell in front of it must open the door")
to_door_pos = {x = 2, y = 0, z = 0}
follower_def.check_gowp(to_door_entity, 0.1)
assert(#to_door_actions == 1 and to_door_actions[1].action == "open")

-- A villager standing in the door's own cell, with the door shut, opens it
-- before leaving across the leaf.
local in_door_actions = {}
local in_door_entity = {
	_bed = {x = 0, y = 0, z = 0}, state = "stand",
	object = {
		get_pos = function() return {x = 1, y = 0, z = 0} end,
		set_velocity = function() end,
	},
	do_pathfind_action = function(_, action) table.insert(in_door_actions, action) end,
}
assert(door_def.gopath(in_door_entity, in_door_entity._bed, nil, true))
settle()
assert(in_door_entity.current_target.action and in_door_entity.current_target.action.action == "open"
	and in_door_entity.current_target.action.target.x == 1, "a route starting in the door's cell must open it")
minetest.get_node_or_nil = door_node
wooden_door = false

-- A waypoint's action fires when the mover leaves it for the next one. When
-- the destination sits just past a door, the door is the second-to-last
-- waypoint and the destination itself is last, so a close action attached to
-- the destination would never fire. It must close on arrival instead (#60).
local trailing_close_action = nil
local trailing_door_def = {
	on_activate = function() end,
	do_custom = function() end,
	do_pathfind_action = function(_, action) trailing_close_action = action end,
}
dofile("navigation.lua")(trailing_door_def)
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

-- A stair presents a full vertical face from the side, not just the low front
-- face. The fallback planner must jump directly onto it from any cardinal
-- direction rather than needing to detour to a particular facing side (#64).
local stair_side_def = {
	on_activate = function() end,
	do_custom = function() end,
}
dofile("navigation.lua")(stair_side_def)
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

local proactive_def = {
	on_activate = function() end,
	do_custom = function() end,
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
assert(proactive_entity._target and not (proactive_entity._target.x == 0 and proactive_entity._target.z == 0))
assert(proactive_entity._villages_bed_route.status == "travelling")

top_claimed_by_player = true
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
assert(not blocked_entity._target)
assert(not blocked_entity._villages_bed_route)

-- A villager already standing near its claimed bed at nightfall needs no
-- trip, but must still get order = "sleep" promptly rather than waiting on
-- VoxeLibre's five-second do_activity poll (#61).
top_claimed_by_player = false
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
assert(not already_home_entity._target, "an already-close villager must not be sent on a bed trip")
assert(already_home_entity.order == "sleep",
	"an already-close villager must get order = sleep immediately, not after VoxeLibre's poll")

-- VoxeLibre chooses and claims the jobsite. During its existing work periods,
-- adapt only the trip to that claimed solid node into a safe approach route.
timeofday = 0.4
local callback_target = nil
local job_def = {
	on_activate = function() end,
	do_custom = function() end,
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
assert(job_entity._villages_goto_route and job_entity.state == "gowp", "outside work hours the trip is unmanaged")
assert(not job_entity._villages_job_route)
job_entity.state = "stand"

timeofday = 0.4
assert(job_def.gopath(job_entity, job_entity._jobsite, function(_, target)
	callback_target = target
end, true))
settle()
local job_target = job_entity._target
assert(job_target and not (job_target.x == 10 and job_target.z == 0))
assert(job_entity._villages_job_route.status == "travelling")
job_entity.callback_arrived(job_entity)
assert(job_entity._villages_job_route.status == "arrived")
assert(callback_target and callback_target.x == job_target.x and callback_target.z == job_target.z)

-- Getting off the top of a stair is a plain one-node drop to a lower,
-- supported neighbor; it must not be treated as needing a detour around to
-- the stair's low front face (#64).
local off_stair_def = {
	on_activate = function() end,
	do_custom = function() end,
}
dofile("navigation.lua")(off_stair_def)
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

jobsite_present = false
job_entity._villages_job_route = nil
job_entity.state = "stand"
assert(job_def.gopath(job_entity, job_entity._jobsite, nil, true))
settle()
assert(job_entity._villages_goto_route and not job_entity._villages_job_route, "a missing jobsite is no managed trip")

-- When native look_for_job sends its nearest raw node to gopath, redirect the
-- trip to the nearest *reachable* free station.  The first candidate lacks a
-- safe cardinal approach; importantly, no claim is made by this layer.
jobsite_present = true
jobsite_claimed = false
search_sites = {{x = 20, y = 0, z = 0}, {x = 30, y = 0, z = 0}}
local original_node = minetest.get_node_or_nil
minetest.get_node_or_nil = function(pos)
	-- The four cells beside the site at x = 20 have no floor.
	if pos.y == -1 and math.abs(pos.x - 20) + math.abs(pos.z) == 1 then return {name = "air"} end
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
assert(searching_entity._target and searching_entity._target.x >= 29)
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
	-- The four cells beside the site at x = 20 have no floor.
	if pos.y == -1 and math.abs(pos.x - 20) + math.abs(pos.z) == 1 then return {name = "air"} end
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
-- and so does the commute to a claimed one (#125).
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
local pulpit_target = pulpit_seeker._target
assert(pulpit_target and math.abs(pulpit_target.x - 40) + math.abs(pulpit_target.z) == 1 and pulpit_target.y == 0,
	"a pulpit trip ends on a cardinal neighbor, where the claim on arrival finds it")
assert(pulpit_seeker._villages_job_search_route.status == "travelling")
pulpit_seeker.callback_arrived(pulpit_seeker)
assert(pulpit_arrivals == 1 and pulpit_seeker._villages_job_search_route.status == "arrived")

local failing_def = {
	on_activate = function() end,
	do_custom = function() end,
}
dofile("navigation.lua")(failing_def)
pulpit_claimed = true
local pulpit_cleric = {
	_id = "villager-1", _jobsite = {x = 40, y = 0, z = 0}, state = "stand",
	object = {get_pos = function() return {x = 35, y = 0, z = 0} end, set_velocity = function() end},
}
assert(failing_def.gopath(pulpit_cleric, pulpit_cleric._jobsite, nil, true),
	"the planner routes the commute to a claimed pulpit")
settle()
assert(pulpit_cleric._villages_job_route.status == "travelling")
minetest.get_node_or_nil, minetest.get_meta = pulpit_node, pulpit_meta
pulpit_claimed = false

-- If an accepted bed route stalls, planner recovery must retain the original
-- caller's arrival callback just as it does for jobsites.
jobsite_present = true
top_claimed_by_player = false
local bed_callback_called = false
local recovery_def = {
	on_activate = function() end,
	do_custom = function() end,
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
exhausted_recovery_entity._villages_follow_failed = {reason = "no progress along the route"}
recovery_def.do_custom(exhausted_recovery_entity, 0.1)
settle()
assert(exhausted_recovery_entity._villages_bed_route.status == "retry")
assert(exhausted_recovery_entity._villages_bed_route.reason:find("stair planner", 1, true))
assert(exhausted_recovery_entity._villages_bed_route.reason:find("after 0 nodes", 1, true))
assert(exhausted_recovery_entity._villages_bed_route.planner.searched == 0)
minetest.get_node_or_nil = no_bed_approach_node
support_available = true

-- A wooden door that becomes iron after planning ends the follower's walk
-- (follower.lua gives up on a blocked door), and the planner plans again.
local changed_door_entity = {
	_id = "villager-1", _bed = {x = 0, y = 0, z = 0}, state = "gowp",
	_villages_bed_route = {status = "travelling", id = 1, target = {x = -1, y = 0, z = 0}},
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
changed_door_entity.state = "stand"
changed_door_entity._villages_follow_failed = {reason = "door cannot be crossed"}
recovery_def.do_custom(changed_door_entity, 0.1)
settle()
assert(changed_door_entity.state == "gowp" and changed_door_entity._villages_bed_route.replans == 1)
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
settle()
assert(fish_entity._target and not (fish_entity._target.x == fish_site.x and fish_entity._target.z == fish_site.z),
	"the fisherman must stand beside the water, not on it")
assert(fish_entity._villages_fish_route.status == "travelling")
fish_entity.callback_arrived(fish_entity)
assert(fish_entity._villages_fish_route.status == "arrived")
assert(fish_arrived_called)

-- A stand already occupied by another loaded villager is skipped for an
-- unoccupied one instead of failing the whole route.
fish_entity._villages_fish_route = nil
fish_entity.state = "stand"
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
assert(not (fish_entity._target.x == occupied_stand.x and fish_entity._target.z == occupied_stand.z),
	"an occupied stand must be skipped for another candidate")
minetest.get_objects_inside_radius = original_objects_near

-- Every candidate stand occupied is reported as no safe standing space,
-- exactly like a bed or jobsite with no free approach.
fish_entity._villages_fish_route = nil
fish_entity.state = "stand"
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
settle()
assert(raised_fish_entity._target and raised_fish_entity._target.y == 1,
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

-- A canceled or superseded route must not run its old arrival callback.
local ownership_def = {
	on_activate = function() end,
	do_custom = function() end,
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
timeofday = 0.8
assert(ownership_def.gopath(ownership_entity, ownership_entity._bed, function()
	ownership_callback_calls = ownership_callback_calls + 1
end, true))
settle()
local stale_callback = ownership_entity.callback_arrived
local first_route_id = ownership_entity._villages_bed_route.id
ownership_entity.state = "stand"
assert(ownership_def.gopath(ownership_entity, ownership_entity._bed, function()
	ownership_callback_calls = ownership_callback_calls + 1
end, true))
settle()
assert(ownership_entity._villages_bed_route.id ~= first_route_id)
stale_callback(ownership_entity)
assert(ownership_entity._villages_bed_route.status == "travelling")
assert(ownership_callback_calls == 0)
ownership_entity.callback_arrived(ownership_entity)
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

local stalled_def = {
	on_activate = function() end,
	do_custom = function() end,
}
dofile("navigation.lua")(stalled_def)

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
support_available = true
support_node = "stone"
jobsite_present = false
search_sites = {}
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
search_sites = {}
jobsite_claimed = true
clear_pond()

-- With no water near its bed, a villager never pays for the workstation
-- search, which plans a route to every free site in range (#113).
water_scans = 0
jobsite_claimed = false
search_sites = {{x = 20, y = 0, z = 0}}
local scans_before = job_search_scans
local dry_entity = new_promotion_entity()
promotion_def.do_custom(dry_entity, 0.1)
settle()
assert(water_scans == 1, "the water is checked")
assert(job_search_scans == scans_before, "no water means no workstation search")
assert(dry_entity._profession == "unemployed")
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
	get_staticdata = function(self)
		-- mcl_mobs' own: it sets the live mob's state to "stand" as well.
		self.state = "stand"
		saved_fields = {}
		for field, value in pairs(self) do saved_fields[field] = value end
		return "saved"
	end,
}
dofile("navigation.lua")(staticdata_def)

-- #195: the engine saves a block's villagers whenever the block is written, and a
-- door opening or closing writes it. mcl_mobs' get_staticdata sets the live state
-- to "stand", which ended the walk through the door a few seconds later: the route
-- was cancelled and the villager stood short of its bed. The save says "stand"
-- (a reload must not resume a walk) but the live villager keeps walking.
local walking = {_id = "walker", state = "gowp", _villages_follow = {final = {x = 1, y = 0, z = 1}}}
staticdata_def.get_staticdata(walking)
assert(saved_fields.state == "stand", "the saved copy of a walking villager says stand")
assert(walking.state == "gowp", "a save must not end the live villager's walk")
assert(walking._villages_follow, "nor drop the follower's state")
local standing = {_id = "stander", state = "walk"}
staticdata_def.get_staticdata(standing)
assert(standing.state == "stand", "other states are mcl_mobs' own to reset")

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
	assert(polled._villages_bed_route.status == "travelling")
	assert(polled._villages_bed_route.id == first_id)

	-- A detour that a later trip superseded must not start.
	local called = {}
	local first_callback = function() called.first = true end
	local second_callback = function() called.second = true end
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
	detoured.callback_arrived(detoured)
	assert(called.second and not called.first, "the superseded detour does not restore its callback")
	assert(detoured.waypoints[#detoured.waypoints].pos.x == 8 or detoured._target.x == 8, "nor its path")
	low_ceiling = false
end

-- The planner chooses every route (#163) and the follower walks it (#164).
do
	timeofday = 0.8
	low_ceiling, wooden_door, glass_pane = false, false, false
	local planner_def = {
		on_activate = function() end,
		do_custom = function() end,
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

	-- A managed trip is planned, then walked by the follower.
	local sleeper = new_entity(true)
	assert(planner_def.gopath(sleeper, sleeper._bed, nil, true))
	assert(sleeper._villages_bed_route.status == "planning")
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

	-- A repeated managed request keeps the walk it has (review of #163).
	local commuter = new_entity(true)
	assert(planner_def.gopath(commuter, commuter._bed, nil, true))
	settle()
	commuter.current_target.failed_attempts = 50
	local walk_target = commuter.current_target
	assert(planner_def.gopath(commuter, commuter._bed, nil, true) == nil)
	assert(commuter.state == "gowp" and commuter.current_target == walk_target
		and walk_target.failed_attempts == 50, "the walk is not restarted")

	-- A target beyond the planner's range of the villager is still routed to
	-- (#182): the church search finds a pulpit 41 from the bed, which can be
	-- 55 from where the villager stands.
	local far = new_entity()
	far.object = {get_pos = function() return {x = -2663, y = 0.5, z = 266} end, set_velocity = function() end}
	assert(planner_def.gopath(far, {x = -2608, y = 0, z = 254}, nil, true))
	settle()
	assert(far._villages_goto_route.status == "travelling" and far.state == "gowp",
		"a target 55 away is planned: " .. tostring(far._villages_goto_route.status))
	local unreachable = new_entity()
	unreachable.object = far.object
	assert(planner_def.gopath(unreachable, {x = -2663 + 300, y = 0, z = 266}, nil, true) ~= nil)
	settle()
	assert(unreachable._villages_goto_route.status == "retry", "the widened box is still capped")

	-- A search still queued for one trip does not overwrite the next trip's route.
	local switcher = new_entity(true)
	assert(planner_def.gopath(switcher, {x = 8, y = 0, z = 0}, nil, true))
	assert(planner_def.gopath(switcher, switcher._bed, nil, true))
	settle()
	assert(switcher._villages_goto_route == nil, "the superseded search is dropped")
	assert(switcher._villages_bed_route.status == "travelling" and switcher._target.x ~= 8)

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

	-- A walk the follower gave up on (#164) is planned again from where the
	-- villager stands, twice at most, and then backs off with the reason.
	local gave_up = new_entity(true)
	assert(planner_def.gopath(gave_up, gave_up._bed, nil, true))
	settle()
	assert(gave_up.state == "gowp" and gave_up._villages_follow, "the planner's walk is the follower's")
	for attempt = 1, 2 do
		gave_up.state = "stand"
		gave_up._villages_follow = nil
		gave_up._villages_follow_failed = {reason = "no progress along the route"}
		planner_def.do_custom(gave_up, 0.1)
		settle()
		assert(gave_up.state == "gowp" and gave_up._villages_bed_route.replans == attempt,
			"replanned after the follower gave up, attempt " .. attempt)
	end
	gave_up.state = "stand"
	gave_up._villages_follow = nil
	gave_up._villages_follow_failed = {reason = "blocked by another villager"}
	planner_def.do_custom(gave_up, 0.1)
	settle()
	assert(gave_up._villages_bed_route.status == "retry"
		and gave_up._villages_bed_route.reason:find("blocked by another villager", 1, true), "then backs off")

end

math.random = real_random

print("navigation.lua: ok")
