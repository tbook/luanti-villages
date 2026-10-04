-- Run with: lua tests/step.lua
local nodes = {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end
local function near(a, b) return math.abs(a - b) < 1e-6 end
local afters = 0

local groups = {
	["mcl_wool:purple_carpet"] = {carpet = 1},
	["mcl_fences:fence"] = {fence = 1},
}
minetest = {
	get_modpath = function() return "." end,
	get_item_group = function(name, group) return (groups[name] or {})[group] or 0 end,
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["mcl_core:wood"] = {walkable = true},
		["mcl_wool:purple_carpet"] = {walkable = true,
			drawtype = "nodebox", node_box = {type = "fixed", fixed = {{-0.5, -0.5, -0.5, 0.5, -0.4375, 0.5}}}},
		["mcl_fences:fence"] = {walkable = true,
			collision_box = {type = "fixed", fixed = {{-0.125, -0.5, -0.125, 0.125, 1, 0.125}}}},
		["mcl_stairs:slab_wood"] = {walkable = true,
			collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0, 0.5}}},
	},
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
	after = function() afters = afters + 1 end,
}

-- A floor, and a step a node up ahead (+x) with carpet on it: the church dais.
for x = 0, 12 do
	for z = 0, 10 do nodes[key({x = x, y = 1, z = z})] = "mcl_core:stone" end
end
nodes[key({x = 8, y = 2, z = 5})] = "mcl_core:wood"
nodes[key({x = 8, y = 3, z = 5})] = "mcl_wool:purple_carpet"

local vanilla_jumped = false
mcl_mobs = {mob_class = {do_jump = function() return vanilla_jumped end}}
local def = {}
dofile("step.lua").install(def)

local function villager()
	local pos, velocity, acceleration = {x = 7, y = 1.51, z = 5}, {x = 0, y = 0, z = 0}, nil
	local self = {
		state = "gowp", jump = true, jump_height = 4, order = nil,
		-- The route's next waypoint: on top of the step.
		current_target = {pos = {x = 8, y = 3, z = 5}},
		initial_properties = {collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}},
	}
	self.object = {
		get_pos = function() return {x = pos.x, y = pos.y, z = pos.z} end,
		get_velocity = function() return {x = velocity.x, y = velocity.y, z = velocity.z} end,
		set_velocity = function(_, v) velocity = v end,
		set_acceleration = function(_, a) acceleration = a end,
		-- Facing +x: a mob's forward is (-sin yaw, cos yaw).
		get_yaw = function() return -math.pi / 2 end,
		get_luaentity = function() return self end,
	}
	self.velocity = function() return velocity end
	return setmetatable(self, {__index = def})
end

-- The carpeted step vanilla refuses: jumped, with vanilla's own jump.
local v = villager()
assert(def.do_jump(v) == true, "jumps the carpeted step")
assert(near(v.velocity().y, 4.3) and afters == 3, "vanilla's jump: jump_height + 0.3, then pushed forward")

-- Vanilla's own jumps pass straight through.
vanilla_jumped = true
v = villager()
assert(def.do_jump(v) == true and v.velocity().y == 0, "vanilla jumped; nothing added")
vanilla_jumped = false

-- Only on a planned route: wandering keeps vanilla's choice.
v = villager()
v.state = "walk"
assert(def.do_jump(v) == false, "not while wandering")

-- Nor when the route does not go up the step: passing alongside it, or
-- heading for the floor in front of it.
v = villager()
v.current_target = {pos = {x = 8, y = 2, z = 6}}
assert(def.do_jump(v) == false, "route stays on the floor")
v = villager()
v.current_target = nil
assert(def.do_jump(v) == false, "no route")

-- Nor when vanilla has jumping off, or the villager is told to stand.
v = villager()
v.jump = false
assert(def.do_jump(v) == false, "jumping off")
v = villager()
v.order = "stand"
assert(def.do_jump(v) == false, "ordered to stand")

-- Not from mid-air.
v = villager()
v.object:set_velocity({x = 0, y = 1, z = 0})
assert(def.do_jump(v) == false, "already in the air")

-- A real stack, two full blocks: still refused.
nodes[key({x = 8, y = 3, z = 5})] = "mcl_core:stone"
assert(def.do_jump(villager()) == false, "two blocks")
nodes[key({x = 8, y = 3, z = 5})] = "mcl_wool:purple_carpet"

-- No room to land on the step, or to rise from here.
nodes[key({x = 8, y = 4, z = 5})] = "mcl_core:stone"
assert(def.do_jump(villager()) == false, "no room on the step")
nodes[key({x = 8, y = 4, z = 5})] = nil
nodes[key({x = 7, y = 4, z = 5})] = "mcl_core:stone"
assert(def.do_jump(villager()) == false, "no room overhead")
nodes[key({x = 7, y = 4, z = 5})] = nil

-- A fence with carpet on it, or a half step, is not a step to jump.
nodes[key({x = 8, y = 2, z = 5})] = "mcl_fences:fence"
assert(def.do_jump(villager()) == false, "fence")
nodes[key({x = 8, y = 2, z = 5})] = "mcl_stairs:slab_wood"
assert(def.do_jump(villager()) == false, "slab")
nodes[key({x = 8, y = 2, z = 5})] = "mcl_core:wood"

-- Nothing under the villager: no jump.
nodes[key({x = 7, y = 1, z = 5})] = nil
assert(def.do_jump(villager()) == false, "nothing to jump from")
nodes[key({x = 7, y = 1, z = 5})] = "mcl_core:stone"

assert(def.do_jump(villager()) == true, "and the step is still jumped once all is clear")
print("ok")
