-- Run with: lua tests/sleep.lua
table.copy = table.copy or function(value)
	local result = {}
	for key, item in pairs(value) do result[key] = item end
	return result
end

local time = 0.9
local nodes = {}
local metadata = {}
local objects = {}
local function key(pos)
	return ("%d,%d,%d"):format(pos.x, pos.y, pos.z)
end
local bed = {x = 0, y = 0, z = 0}
local top = {x = 0, y = 0, z = 1}
nodes[key(bed)] = {name = "mcl_beds:bed_red_bottom", param2 = 0}
metadata[key(bed)] = {villager = "alice", player = ""}
metadata[key(top)] = {player = ""}

vector = {
	new = function(x, y, z) return {x = x, y = y, z = z} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
	offset = function(pos, x, y, z)
		return {x = pos.x + x, y = pos.y + y, z = pos.z + z}
	end,
	equals = function(a, b)
		return a.x == b.x and a.y == b.y and a.z == b.z
	end,
	distance = function(a, b)
		return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2)
	end,
}

local entity_def = {
	initial_properties = {collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}, mesh = "old.b3d"},
	animation = {stand_start = 1},
	_child_animations = {stand_start = 71},
	head_swivel = "head.control",
	head_bone_position = {x = 0, y = 6.3, z = 0},
	do_custom = function() end,
	on_activate = function() end,
}
minetest = {
	registered_entities = {["mobs_mc:villager"] = entity_def},
	register_on_mods_loaded = function(callback) callback() end,
	get_modpath = function() return "." end,
	get_day_count = function() return 0 end,
	find_nodes_in_area = function() return {} end,
	get_timeofday = function() return time end,
	get_node_or_nil = function(pos) return nodes[key(pos)] end,
	get_item_group = function(name, group)
		return group == "bed" and name:find("_bottom", 1, true) and 1 or 0
	end,
	get_meta = function(pos)
		return {get_string = function(_, field)
			return (metadata[key(pos)] or {})[field] or ""
		end}
	end,
	get_objects_inside_radius = function() return objects end,
	facedir_to_dir = function() return {x = 0, y = 0, z = 1} end,
	log = function() end,
}
mcl_beds = {get_bed_top = function() return top end}
mcl_mobs = {mob_class = {
	set_animation = function(self, name) self.last_animation = name end,
	get_staticdata = function(self)
		return {
			collisionbox = table.copy(self.collisionbox),
			animation = self.animation,
			head_swivel = self.head_swivel,
			_villages_sleeping = self._villages_sleeping,
		}
	end,
	-- Spawned villager instances do not reliably inherit these through their
	-- metatable, so villages/init.lua calls them as plain functions captured
	-- from def/mob_class at mod-load time, never as self:method(). Mock them
	-- the same way here, on mob_class, rather than per villager instance.
	cancel_navigation = function(self)
		self._cancel_navigation_calls = (self._cancel_navigation_calls or 0) + 1
	end,
	halt_in_tracks = function(self)
		self._halt_in_tracks_calls = (self._halt_in_tracks_calls or 0) + 1
	end,
	set_yaw = function(self, yaw) self._yaw = yaw end,
}}

dofile("init.lua")

local function make_villager(id, is_child, start_pos)
	local props = {mesh = "old.b3d", textures = {"old.png"}}
	local pos = start_pos or {x = 0, y = 0, z = 0}
	local self = {
		name = "mobs_mc:villager", _id = id, _bed = bed,
		_profession = "weapon_smith", _max_trade_tier = 2,
		order = "sleep", child = is_child,
		_cancel_navigation_calls = 0, _halt_in_tracks_calls = 0,
	}
	self.object = {
		get_pos = function() return pos end,
		set_pos = function(_, value) pos = value end,
		set_yaw = function() end,
		get_properties = function() return props end,
		set_properties = function(_, values)
			for k, v in pairs(values) do props[k] = v end
		end,
		get_luaentity = function() return self end,
	}
	return self, props
end

local alice, alice_props = make_villager("alice", false, {x = 1, y = 0, z = 0})
objects = {alice.object}
entity_def.on_activate(alice, "", 0)
assert(alice._villages_sleeping)
assert(alice.last_animation == "sleep")
assert(alice_props.mesh == "villages_villager.b3d")
assert(alice_props.textures[1]:find("profession_weaponsmith", 1, true))
assert(alice_props.textures[1]:find("badge_iron", 1, true))
assert(alice_props.collisionbox[5] == 0.3)
local saved = entity_def.get_staticdata(alice)
assert(saved.collisionbox[5] == 1.94)
assert(saved.animation.stand_start == 1)
assert(saved.head_swivel == "head.control")
assert(not saved._villages_sleeping)
assert(alice._villages_sleeping and alice.collisionbox[5] == 0.3)
alice._max_trade_tier = 3
alice_props.textures = {"old.png"} -- VoxeLibre refreshes this after a trade.
entity_def.do_custom(alice, 0.6)
assert(alice_props.textures[1]:find("badge_gold", 1, true))

-- Regression test: navigation/movement/motion/ai already ran for the tick by
-- the time do_custom is called, so a sleeping villager must be re-pinned to
-- the bed every tick, not just once when it fell asleep. It must also cancel
-- the wander/pathfinding AI's movement goal every tick (cancel_navigation +
-- halt_in_tracks), and turn via the mob's own set_yaw rather than a raw
-- object:set_yaw call: set_yaw is what keeps rotate_step's gradual-turn
-- target in sync, so skipping it lets rotate_step keep chasing whatever
-- heading the (uncancelled) wander AI last wanted, spinning the villager.
local sleep_pos = alice.object:get_pos()
local cancels_before, halts_before
	= alice._cancel_navigation_calls, alice._halt_in_tracks_calls
-- A small nudge, well within the "too far away, must have been kicked out
-- of bed" wake threshold checked below, but enough to reveal the drift bug.
alice.object:set_pos(vector.offset(sleep_pos, 0.2, 0, 0))
alice._yaw = -1 -- an arbitrary yaw a fighting wander AI might have left behind
entity_def.do_custom(alice, 0.1)
assert(vector.equals(alice.object:get_pos(), sleep_pos),
	"a sleeping villager must be re-pinned to the bed every tick")
assert(alice._cancel_navigation_calls > cancels_before,
	"a sleeping villager's pathfinding must be cancelled every tick")
assert(alice._halt_in_tracks_calls > halts_before,
	"a sleeping villager's movement must be halted every tick")
assert(math.abs(alice._yaw - math.pi) < 1e-9,
	"a sleeping villager must be turned via set_yaw, not a raw object:set_yaw, every tick")

-- Reactivation while asleep must retain the pre-sleep exit, rather than
-- replacing it with the in-bed sleeping position.
entity_def.on_activate(alice, "", 0)
assert(alice._villages_sleeping)

local bob = make_villager("bob")
objects = {alice.object, bob.object}
entity_def.on_activate(bob, "", 0)
assert(not bob._villages_sleeping, "another villager must not share a bed")

time = 0.5
entity_def.do_custom(alice, 1)
assert(not alice._villages_sleeping)
assert(alice.last_animation == "stand")
assert(alice_props.collisionbox[5] == 1.94)
local alice_pos = alice.object:get_pos()
assert(alice_pos.x == 1 and alice_pos.y == 0 and alice_pos.z == 0,
	"waking must return a villager to its pre-sleep standing position")

metadata[key(top)].player = "player1"
local player_bed_villager = make_villager("alice")
objects = {player_bed_villager.object}
entity_def.on_activate(player_bed_villager, "", 0)
assert(not player_bed_villager._villages_sleeping)
metadata[key(top)].player = ""

time = 0.9
local child, child_props = make_villager("alice", true)
objects = {child.object}
entity_def.on_activate(child, "", 0)
assert(child._villages_sleeping)
assert(child_props.collisionbox[5] == 0.15)

nodes[key(bed)] = {name = "air", param2 = 0}
entity_def.do_custom(child, 1)
assert(not child._villages_sleeping, "removing the bed must wake its occupant")
assert(child_props.collisionbox[5] == 0.97)

print("villager sleep tests passed")
