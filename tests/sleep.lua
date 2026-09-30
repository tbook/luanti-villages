-- Run with: lua tests/sleep.lua
table.copy = table.copy or function(value)
	local result = {}
	for key, item in pairs(value) do result[key] = item end
	return result
end

local time = 0.9
local died = {}
local logged = {}
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

-- A villager may only be returned to a square it can stand in, so the room
-- around the bed needs a floor and open air above it.
local registered_nodes = {
	air = {walkable = false},
	["mcl_core:dirt"] = {walkable = true},
	["mcl_core:stone"] = {walkable = true},
	["mcl_beds:bed_red_bottom"] = {walkable = true},
	-- Fire fits a villager perfectly well: not walkable, no collision box, not
	-- a liquid. Only its group marks it as somewhere a villager must not be put.
	["mcl_fire:fire"] = {walkable = false},
}
local function build_floor(x, z)
	nodes[key({x = x, y = -1, z = z})] = {name = "mcl_core:dirt", param2 = 0}
	nodes[key({x = x, y = 0, z = z})] = nodes[key({x = x, y = 0, z = z})]
		or {name = "air", param2 = 0}
	nodes[key({x = x, y = 1, z = z})] = {name = "air", param2 = 0}
end
for x = -1, 2 do
	for z = -1, 2 do build_floor(x, z) end
end

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
	-- Stands in for mobs_mc/villager.lua's own do_custom (its periodic
	-- do_activity() polls the bed and can issue turns/movement of its own).
	do_custom = function(self)
		self._original_custom_calls = (self._original_custom_calls or 0) + 1
	end,
	on_activate = function() end,
	on_die = function(self) table.insert(died, self._id) end,
}
minetest = {
	registered_entities = {["mobs_mc:villager"] = entity_def},
	registered_nodes = registered_nodes,
	register_on_mods_loaded = function(callback) callback() end,
	get_modpath = function() return "." end,
	get_day_count = function() return 0 end,
	find_nodes_in_area = function() return {} end,
	get_timeofday = function() return time end,
	get_node_or_nil = function(pos) return nodes[key(pos)] end,
	get_item_group = function(name, group)
		if group == "fire" then return name:find("fire", 1, true) and 1 or 0 end
		if group == "opaque" then return name:find("mcl_core:", 1, true) and 1 or 0 end
		return group == "bed" and name:find("_bottom", 1, true) and 1 or 0
	end,
	get_meta = function(pos)
		return {
			get_string = function(_, field)
				return (metadata[key(pos)] or {})[field] or ""
			end,
			set_string = function(_, field, value)
				metadata[key(pos)] = metadata[key(pos)] or {}
				metadata[key(pos)][field] = value
			end,
		}
	end,
	get_objects_inside_radius = function() return objects end,
	facedir_to_dir = function() return {x = 0, y = 0, z = 1} end,
	log = function(level, message) table.insert(logged, {level = level, message = message}) end,
	register_entity = function() end,
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
			_villages_bed_exit = self._villages_bed_exit,
			_villages_bed_exit_bed = self._villages_bed_exit_bed,
			_villages_activated_at = self._villages_activated_at,
		}
	end,
	-- mob_class:set_yaw only records target_yaw/delay; a separate, always-on
	-- check_smooth_rotation() is what actually turns the model each tick.
	-- Track calls here rather than on self.object.set_yaw, since
	-- villages/init.lua must route through this, not a raw object call.
	set_yaw = function(self, yaw, delay) self._yaw, self._yaw_delay = yaw, delay end,
}}

dofile("init.lua")

local function make_villager(id, is_child, start_pos)
	local props = {mesh = "old.b3d", textures = {"old.png"}}
	local pos = start_pos or {x = 0, y = 0, z = 0}
	local removed = false
	local self = {
		name = "mobs_mc:villager", _id = id, _bed = bed,
		_profession = "weapon_smith", _max_trade_tier = 2,
		order = "sleep", child = is_child,
	}
	local velocity, acceleration
	self.object = {
		get_pos = function() if removed then return nil end return pos end,
		set_pos = function(_, value) pos = value end,
		set_yaw = function() end,
		set_velocity = function(_, v) velocity = v end,
		set_acceleration = function(_, v) acceleration = v end,
		get_properties = function() return props end,
		set_properties = function(_, values)
			for k, v in pairs(values) do props[k] = v end
		end,
		get_luaentity = function() return self end,
		remove = function() removed = true end,
	}
	return self, props, function() return velocity, acceleration end,
		function() return removed end
end

local alice, alice_props, alice_motion = make_villager("alice", false, {x = 1, y = 0, z = 0})
objects = {alice.object}
entity_def.on_activate(alice, "", 0)
assert(alice._villages_sleeping)
assert(alice.last_animation == "sleep")
assert(alice_props.mesh == "living_villages_villager.b3d")
assert(alice_props.textures[1]:find("profession_weaponsmith", 1, true))
assert(alice_props.textures[1]:find("badge_iron", 1, true))
assert(alice_props.collisionbox[5] == 0.3)
local saved = entity_def.get_staticdata(alice)
assert(saved.collisionbox[5] == 1.94)
assert(saved.animation.stand_start == 1)
assert(saved.head_swivel == "head.control")
assert(not saved._villages_sleeping)
-- Regression test (#84): mcl_mobs saves every field of self, so a bed exit
-- left in the save outlives the night it belongs to. The villager that
-- reloads may claim a different bed, and waking would then teleport it back
-- to the previous bed's exit -- across the village, often into a wall, where
-- it suffocates within seconds. The exit must never reach the save.
assert(not saved._villages_bed_exit and not saved._villages_bed_exit_bed,
	"a bed exit must not be written into the villager's staticdata")
assert(not saved._villages_activated_at,
	"where a villager loaded is this session's business only")
assert(alice._villages_bed_exit,
	"the live villager must keep its bed exit across a save")
assert(alice._villages_sleeping and alice.collisionbox[5] == 0.3)
alice._max_trade_tier = 3
alice_props.textures = {"old.png"} -- VoxeLibre refreshes this after a trade.
entity_def.do_custom(alice, 0.6)
assert(alice_props.textures[1]:find("badge_gold", 1, true))
assert(not alice._original_custom_calls,
	"the vanilla villager do_custom must not run while asleep")
assert(alice_props.visual_size and alice_props.visual_size.x == 1 and alice_props.visual_size.y == 1,
	"an adult villager's visual_size must be the full 1x scale")

-- Regression test: mcl_mobs/api.lua aliases (does not copy) self.base_size
-- when scaling a child's rendered size, mutating it in place; repeated
-- reactivations while a child decay it toward zero, and growing up then
-- copies that decayed value straight into visual_size, rendering the
-- villager invisible. villages/init.lua cannot fix mcl_mobs itself, so it
-- must notice and correct a wrong visual_size the same way it already
-- corrects mesh/texture drift.
alice_props.visual_size = {x = 0.0001, y = 0.0001} -- simulate the decayed upstream value
alice.base_size = {x = 0.0001, y = 0.0001}
entity_def.do_custom(alice, 0.6)
assert(alice_props.visual_size.x == 1 and alice_props.visual_size.y == 1,
	"a corrupted visual_size must be corrected back to full scale")
assert(alice.base_size.x == 1 and alice.base_size.y == 1,
	"self.base_size must also be corrected so future growth transitions are not re-corrupted")

-- Regression test: navigation/movement/motion/physics steps already ran for
-- the tick by the time do_custom is called, so a sleeping villager must be
-- re-pinned to the bed every tick, not just once when it fell asleep. It
-- must also turn via the mob's own set_yaw (which records target_yaw) and
-- not a raw object:set_yaw call: a separate check_smooth_rotation() runs
-- every tick regardless of do_custom, chasing target_yaw on its own, so
-- skipping set_yaw lets it keep chasing whatever heading the villager's own
-- AI wanted before falling asleep, spinning the villager. And the vanilla
-- villager do_custom (whose periodic do_activity() re-checks the bed and can
-- issue its own competing turns) must stay skipped every tick asleep, not
-- just on the tick sleep began.
local sleep_pos = alice.object:get_pos()
local custom_calls_before = alice._original_custom_calls
-- A small nudge, well within the "too far away, must have been kicked out
-- of bed" wake threshold checked below, but enough to reveal the drift bug.
alice.object:set_pos(vector.offset(sleep_pos, 0.2, 0, 0))
alice._yaw = -1 -- an arbitrary yaw a fighting wander AI might have left behind
entity_def.do_custom(alice, 0.1)
assert(vector.equals(alice.object:get_pos(), sleep_pos),
	"a sleeping villager must be re-pinned to the bed every tick")
local velocity, acceleration = alice_motion()
assert(velocity and vector.equals(velocity, vector.zero()),
	"a sleeping villager's velocity must be cleared every tick")
assert(acceleration and vector.equals(acceleration, vector.zero()),
	"a sleeping villager's acceleration must be cleared every tick")
assert(vector.equals(alice.acc, vector.zero()),
	"a sleeping villager's own steering vector (self.acc) must be cleared every tick")
assert(math.abs(alice._yaw - math.pi) < 1e-9,
	"a sleeping villager must be turned via the mob's own set_yaw, not a raw object:set_yaw, every tick")
assert(alice._original_custom_calls == custom_calls_before,
	"the vanilla villager do_custom must stay skipped on every asleep tick, not just the first")

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

-- Regression test: Luanti can duplicate an entity across a mapblock
-- save/reload race (see villages/init.lua for the mechanism), leaving two
-- live villagers sharing the same _id. Both copies must independently agree
-- on the same survivor, whichever one happens to activate first.
local dup_a, dup_a_props, _, dup_a_removed =
	make_villager("carol", false, {x = 5, y = 0, z = 0})
local dup_b, dup_b_props, _, dup_b_removed =
	make_villager("carol", false, {x = 2, y = 0, z = 0})

objects = {dup_a.object, dup_b.object}
entity_def.on_activate(dup_a, "", 0)
assert(dup_a_removed(), "the duplicate with the larger position key must remove itself")
assert(not dup_b_removed(), "the surviving duplicate must not be touched")

-- Same pair, but the surviving copy activates first this time: it must
-- remove the other copy itself, since that copy's own on_activate will
-- never run again to notice the collision on its own.
local dup_c, dup_c_props, _, dup_c_removed =
	make_villager("dana", false, {x = 5, y = 0, z = 0})
local dup_d, dup_d_props, _, dup_d_removed =
	make_villager("dana", false, {x = 2, y = 0, z = 0})

objects = {dup_c.object, dup_d.object}
entity_def.on_activate(dup_d, "", 0)
assert(dup_c_removed(), "the surviving copy must remove the other duplicate directly")
assert(not dup_d_removed(), "the surviving copy must not remove itself")

-- Regression test: the engine can duplicate an entity at its exact position,
-- so position alone is not a safe tie-breaker (both copies would otherwise
-- take the "remove the other" branch). Exactly one of the two must be
-- removed, from either activation order, never both and never neither.
local dup_e, _, _, dup_e_removed = make_villager("erin", false, {x = 3, y = 0, z = 0})
local dup_f, _, _, dup_f_removed = make_villager("erin", false, {x = 3, y = 0, z = 0})

objects = {dup_e.object, dup_f.object}
entity_def.on_activate(dup_e, "", 0)
assert(dup_e_removed() ~= dup_f_removed(),
	"exactly one same-position duplicate must be removed, not both or neither")

local dup_g, _, _, dup_g_removed = make_villager("fern", false, {x = 3, y = 0, z = 0})
local dup_h, _, _, dup_h_removed = make_villager("fern", false, {x = 3, y = 0, z = 0})

objects = {dup_g.object, dup_h.object}
entity_def.on_activate(dup_h, "", 0)
assert(dup_g_removed() ~= dup_h_removed(),
	"exactly one same-position duplicate must be removed regardless of activation order")

-- Regression test: skin() must trust _villages_fisherman, which is never
-- transiently cleared, rather than raw _profession. fisherman.lua's guard
-- (#70) only restores a jobsite-less fisherman's _profession after vanilla's
-- own do_custom -- which this file's do_custom wraps innermost, calling
-- tick_visual right after it -- has already reset it to "unemployed" for
-- that tick. Reading _profession directly would occasionally paint the
-- plain, no-profession skin for one visual-refresh cycle every time that
-- reset and the 0.5s refresh throttle happen to land on the same tick.
local gwen, gwen_props = make_villager("gwen", false, {x = 50, y = 0, z = 0})
gwen._villages_fisherman = true
gwen._profession = "unemployed" -- simulates the transient reset window
objects = {}
entity_def.on_activate(gwen, "", 0)
gwen_props.textures = {"old.png"}
entity_def.do_custom(gwen, 0.6)
assert(gwen_props.textures[1]:find("profession_fisherman", 1, true),
	"a transiently-unemployed fisherman must still render its fisherman skin")

-- Regression test: vanilla's own set_textures (mobs_mc/villager.lua:734,
-- called directly from remove_job/employ, not throttled or gated by this
-- mod) overwrites the object's textures outright, bypassing refresh_visual
-- entirely. A throttled correction here used to leave that visible for up
-- to its own interval after every such call; refresh_visual must now run
-- (and correct a mismatch) on every tick, including a single small dtime
-- far under the old 0.5s threshold, not just once enough dtime has
-- accumulated.
local hank, hank_props = make_villager("hank", false, {x = 51, y = 0, z = 0})
objects = {}
entity_def.on_activate(hank, "", 0)
hank_props.textures = {"old.png"} -- simulates vanilla's set_textures firing
entity_def.do_custom(hank, 0.05)
assert(hank_props.textures[1]:find("profession_weaponsmith", 1, true), hank_props.textures[1])
assert(hank_props.textures[1]:find("badge_iron", 1, true))

-- Regression test (#84): an exit recorded beside one bed must never be used to
-- leave another. A villager can claim a different bed between two nights, and
-- teleporting it back to the old bed's exit throws it across the village,
-- frequently into solid nodes, where it suffocates and appears to vanish.
time = 0.9
nodes[key(bed)] = {name = "mcl_beds:bed_red_bottom", param2 = 0} -- restored after the bed-removal test above
local ivy = make_villager("alice", false, {x = 1, y = 0, z = 0})
objects = {ivy.object}
entity_def.on_activate(ivy, "", 0)
assert(ivy._villages_sleeping)
assert(vector.equals(ivy._villages_bed_exit_bed, bed),
	"the exit must be recorded against the bed it was taken beside")
ivy._villages_bed_exit_bed = {x = 40, y = 0, z = 40} -- as if recorded at another bed
local ivy_sleep_pos = ivy.object:get_pos()
time = 0.5
entity_def.do_custom(ivy, 1)
assert(not ivy._villages_sleeping)
assert(vector.equals(ivy.object:get_pos(), ivy_sleep_pos),
	"an exit belonging to another bed must not be teleported to")

-- Regression test (#84): the world can change while a villager sleeps. An exit
-- the player has since built over is no longer a standing space, and setting a
-- villager down inside an opaque node kills it by suffocation within seconds.
time = 0.9
local jack = make_villager("alice", false, {x = 1, y = 0, z = 0})
objects = {jack.object}
entity_def.on_activate(jack, "", 0)
assert(jack._villages_sleeping)
local jack_sleep_pos = jack.object:get_pos()
nodes[key({x = 1, y = 0, z = 0})] = {name = "mcl_core:stone", param2 = 0}
time = 0.5
entity_def.do_custom(jack, 1)
assert(not jack._villages_sleeping)
assert(vector.equals(jack.object:get_pos(), jack_sleep_pos),
	"an exit that is no longer a standing space must not be teleported to")
nodes[key({x = 1, y = 0, z = 0})] = {name = "air", param2 = 0}

-- Regression test (#84): object:remove() skips on_die, so VoxeLibre never
-- clears a removed duplicate's claims and the bed stays owned by an _id with
-- no villager near it. The survivor's own claims must survive, though: both
-- copies carry the same _id, so a shared bed would otherwise be freed out
-- from under the villager still sleeping in it.
time = 0.9
local other_bed = {x = 6, y = 0, z = 0}
metadata[key(other_bed)] = {villager = "kim", player = ""}
metadata[key(bed)].villager = "kim"
local kim_a, _, _, kim_a_removed = make_villager("kim", false, {x = 5, y = 0, z = 0})
local kim_b, _, _, kim_b_removed = make_villager("kim", false, {x = 2, y = 0, z = 0})
kim_a._bed, kim_b._bed = other_bed, bed
objects = {kim_a.object, kim_b.object}
entity_def.on_activate(kim_a, "", 0)
assert(kim_a_removed() and not kim_b_removed())
assert(metadata[key(other_bed)].villager == "",
	"the removed duplicate's bed claim must be released")
assert(metadata[key(bed)].villager == "kim",
	"the surviving villager's own bed claim must be left alone")
metadata[key(bed)].villager = "alice"

-- An exit only has to be somewhere a villager fits for it to be reachable, but
-- fitting is not the same as surviving: fire is not walkable, has no collision
-- box and is not a liquid, so a villager can be dropped straight into one.
time = 0.9
local mae = make_villager("alice", false, {x = 1, y = 0, z = 0})
objects = {mae.object}
entity_def.on_activate(mae, "", 0)
assert(mae._villages_sleeping)
local mae_sleep_pos = mae.object:get_pos()
nodes[key({x = 1, y = 0, z = 0})] = {name = "mcl_fire:fire", param2 = 0}
time = 0.5
entity_def.do_custom(mae, 1)
assert(not mae._villages_sleeping)
assert(vector.equals(mae.object:get_pos(), mae_sleep_pos),
	"an exit that has caught fire must not be teleported to")
nodes[key({x = 1, y = 0, z = 0})] = {name = "air", param2 = 0}

-- A recorded exit is a continuous position, not a node center, and a villager
-- is 0.6 nodes across. Checking only the column the position falls in misses a
-- wall that the standing box overlaps but the center of the box does not.
time = 0.9
local nils = make_villager("alice", false, {x = 1.4, y = 0, z = 0})
objects = {nils.object}
entity_def.on_activate(nils, "", 0)
assert(nils._villages_sleeping)
assert(nils._villages_bed_exit.x == 1.4, "the exit is recorded where the villager stood")
local nils_sleep_pos = nils.object:get_pos()
-- Spans x 1.5 to 2.5; the villager's box at x = 1.4 reaches x = 1.7.
nodes[key({x = 2, y = 0, z = 0})] = {name = "mcl_core:stone", param2 = 0}
nodes[key({x = 2, y = 1, z = 0})] = {name = "mcl_core:stone", param2 = 0}
time = 0.5
entity_def.do_custom(nils, 1)
assert(not nils._villages_sleeping)
assert(vector.equals(nils.object:get_pos(), nils_sleep_pos),
	"an exit whose standing box now overlaps a wall must not be teleported to")
nodes[key({x = 2, y = 0, z = 0})] = {name = "air", param2 = 0}
nodes[key({x = 2, y = 1, z = 0})] = {name = "air", param2 = 0}

-- Touching a node is not reaching into it. A villager at x = 1.2 spans 0.9 to
-- 1.5, so its box stops exactly at the boundary of the node beginning at 1.5
-- and does not enter it. Villagers stand on half-node offsets constantly, and
-- the node they most often touch this way is the bed they are climbing out of,
-- so treating a touch as an overlap would decline most usable exits.
time = 0.9
local quinn = make_villager("alice", false, {x = 1.2, y = 0, z = 0})
objects = {quinn.object}
entity_def.on_activate(quinn, "", 0)
assert(quinn._villages_sleeping)
nodes[key({x = 2, y = 0, z = 0})] = {name = "mcl_core:stone", param2 = 0}
nodes[key({x = 2, y = 1, z = 0})] = {name = "mcl_core:stone", param2 = 0}
time = 0.5
entity_def.do_custom(quinn, 1)
assert(not quinn._villages_sleeping)
assert(quinn.object:get_pos().x == 1.2,
	"an exit whose box only touches the neighboring node must still be usable")
nodes[key({x = 2, y = 0, z = 0})] = {name = "air", param2 = 0}
nodes[key({x = 2, y = 1, z = 0})] = {name = "air", param2 = 0}

-- A villager that loads already sealed inside a node was buried before this
-- session and dies within seconds whatever happens next. Saying so at
-- activation is what separates a death that began elsewhere from one that
-- began here (#84). A villager lying in its bed must not trip it: beds are
-- walkable, but they do not suffocate anyone.
time = 0.5
nodes[key({x = 2, y = 0, z = 0})] = {name = "mcl_core:stone", param2 = 0}
local olive = make_villager("olive", false, {x = 2, y = 0, z = 0})
objects = {olive.object}
logged = {}
entity_def.on_activate(olive, "", 0)
local buried_log
for _, entry in ipairs(logged) do
	if entry.message:find("already buried", 1, true) then buried_log = entry.message end
end
assert(buried_log, "a villager that loads inside a solid node must be reported")
assert(buried_log:find("mcl_core:stone", 1, true), buried_log)
nodes[key({x = 2, y = 0, z = 0})] = {name = "air", param2 = 0}

time = 0.9
local pearl = make_villager("alice", false, {x = 1, y = 0, z = 0})
objects = {pearl.object}
logged = {}
entity_def.on_activate(pearl, "", 0)
assert(pearl._villages_sleeping)
for _, entry in ipairs(logged) do
	assert(not entry.message:find("already buried", 1, true),
		"a villager asleep in its bed must not be reported as buried")
end

-- A villager leaves no corpse and drops nothing, so a death is indistinguishable
-- from a disappearance in game (#84). Record the cause, and keep chaining to
-- VoxeLibre's own on_die, which is what releases the dead villager's claims.
local liam = make_villager("liam", false, {x = 2, y = 6, z = 0})
objects = {liam.object}
entity_def.on_activate(liam, "", 0)
liam.standing_in = "mcl_core:stone"
logged = {}
entity_def.on_die(liam, {x = 2, y = 0, z = 0}, {type = "environment", node = "mcl_core:stone"})
assert(died[1] == "liam", "the villager's own on_die must still run")
local death_log
for _, entry in ipairs(logged) do
	if entry.message:find("died at", 1, true) then death_log = entry.message end
end
assert(death_log, "a villager's death must be logged")
assert(death_log:find("environment", 1, true) and death_log:find("mcl_core:stone", 1, true),
	"the death log must name the cause and the node it happened in: " .. tostring(death_log))
-- A villager that dies well below where it loaded fell there; one that dies
-- where it loaded arrived that way. The death has to carry that distance,
-- since nothing else in the game reports it.
assert(death_log:find("6.0 below", 1, true),
	"the death log must say how far the villager was from where it loaded: " .. death_log)

print("villager sleep tests passed")
