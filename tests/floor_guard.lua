-- Run with: lua tests/floor_guard.lua
local nodes = {}
local logs = {}

local function key(x, y, z)
	return ("%d,%d,%d"):format(x, y, z)
end

minetest = {
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {},
		["mcl_stairs:slab_stone"] = {},
	},
	get_node_or_nil = function(pos)
		return {name = nodes[key(pos.x, pos.y, pos.z)] or "air"}
	end,
	log = function(_, text) logs[#logs + 1] = text end,
}
vector = {zero = function() return {x = 0, y = 0, z = 0} end}

local def = {}
local step_calls = 0
local last_moveresult
def.on_step = function(self, dtime, moveresult)
	step_calls = step_calls + 1
	last_moveresult = moveresult
	if self.move_to then
		self.pos = self.move_to
		self.move_to = nil
	end
end
dofile("floor_guard.lua")(def)

local BOX = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}
local CHILD_BOX = {-0.15, -0.005, -0.15, 0.15, 0.97, 0.15}

local function villager(pos, box)
	local self = {_id = "v", collisionbox = box or BOX, pos = pos}
	self.object = {
		get_pos = function() return self.pos end,
		set_pos = function(_, p) self.pos = p end,
		set_velocity = function(_, v) self.velocity = v end,
		get_attach = function() return self.attached end,
		get_properties = function() return {collisionbox = self.collisionbox} end,
	}
	return self
end

-- The engine's move happens between two on_step calls; simulate it by
-- setting the position directly before the next step.
local function engine_moves(self, pos) self.pos = pos end

local function fill(x, z, from, to, name)
	for y = from, to do nodes[key(x, y, z)] = name or "mcl_core:stone" end
end

local function reset()
	nodes, logs, step_calls = {}, {}, 0
end

local function assert_pos(self, x, y, z, message)
	local p = self.pos
	assert(math.abs(p.x - x) < 1e-6 and math.abs(p.y - y) < 1e-6 and math.abs(p.z - z) < 1e-6,
		message .. (" (at %.2f,%.2f,%.2f)"):format(p.x, p.y, p.z))
end

-- The case recorded in #90: a villager standing on a stone floor at y=6 under
-- a two-node ceiling is snapped to the floor's underside, 5.5 - 1.94 = 3.56.
reset()
fill(0, 0, -5, 6)
fill(0, 0, 9, 9)
local v = villager({x = 0, y = 6.56, z = 0})
def.on_step(v, 0.05)
engine_moves(v, {x = 0, y = 3.56, z = 0})
def.on_step(v, 2.6, {touching_ground = true})
assert_pos(v, 0, 6.56, 0, "a villager dropped through its floor is put back")
assert(last_moveresult == nil, "mcl_mobs does not see the undone move's collision info")
assert(v.velocity and v.velocity.y == 0, "its velocity is cleared")
assert(#logs == 1 and logs[1]:find("dropped through mcl_core:stone at %(0.0,6.0,0.0%)"),
	"the undo names the floor it passed through: " .. tostring(logs[1]))
assert(step_calls == 2, "mcl_mobs still steps the villager both times")

-- The same snap off a bottom slab, whose top is at 6.0 rather than 6.5.
reset()
fill(0, 0, -5, 5)
nodes[key(0, 6, 0)] = "mcl_stairs:slab_stone"
v = villager({x = 0, y = 6.01, z = 0})
def.on_step(v, 0.05)
engine_moves(v, {x = 0, y = 3.56, z = 0})
def.on_step(v, 2.6)
assert_pos(v, 0, 6.01, 0, "a villager dropped through a slab floor is put back")

-- A child's box is half as tall, so the snap is shorter but still impossible.
reset()
fill(0, 0, -5, 6)
v = villager({x = 0, y = 6.505, z = 0}, CHILD_BOX)
def.on_step(v, 0.05)
engine_moves(v, {x = 0, y = 5.5 - 0.97, z = 0})
def.on_step(v, 2.6)
assert_pos(v, 0, 6.505, 0, "a child dropped through its floor is put back")

-- Walking off a ledge during a long step: the ledge is in the old column, the
-- new one is open all the way down to the ground it lands on.
reset()
fill(0, 0, -5, 6)
fill(2, 0, -5, 2)
v = villager({x = 0, y = 6.51, z = 0})
def.on_step(v, 0.05)
engine_moves(v, {x = 2, y = 2.51, z = 0})
def.on_step(v, 2.6)
assert_pos(v, 2, 2.51, 0, "a real fall off a ledge is left alone")
assert(#logs == 0, "and not reported")

-- Falling down a one-wide shaft in the same column: the only walkable node is
-- the ground below the new position, so nothing was passed through.
reset()
fill(0, 0, -5, 2)
fill(1, 0, -5, 6)
fill(-1, 0, -5, 6)
v = villager({x = 0, y = 6.51, z = 0})
def.on_step(v, 0.05)
engine_moves(v, {x = 0, y = 2.51, z = 0})
def.on_step(v, 2.6, {touching_ground = true})
assert_pos(v, 0, 2.51, 0, "a fall down a shaft is left alone")
assert(last_moveresult and last_moveresult.touching_ground, "and its moveresult is passed on")

-- Stepping down a single stair drops less than a node.
reset()
fill(0, 0, -5, 6)
fill(1, 0, -5, 5)
v = villager({x = 0, y = 6.51, z = 0})
def.on_step(v, 0.05)
engine_moves(v, {x = 1, y = 5.51, z = 0})
def.on_step(v, 0.05)
assert_pos(v, 1, 5.51, 0, "stepping down a stair is left alone")

-- Something else moving the villager during an ordinary step is not the snap,
-- which needs a long one.
reset()
fill(0, 0, -5, 6)
v = villager({x = 0, y = 6.56, z = 0})
def.on_step(v, 0.05)
engine_moves(v, {x = 0, y = 3.56, z = 0})
def.on_step(v, 0.05)
assert_pos(v, 0, 3.56, 0, "a move during an ordinary step is left alone")

-- The first step after activation has nothing to compare against.
reset()
fill(0, 0, -5, 6)
v = villager({x = 0, y = 3.56, z = 0})
def.on_step(v, 0.05)
assert_pos(v, 0, 3.56, 0, "a villager with no previous step is left alone")

-- A villager riding something is moved by its parent, not by collision.
reset()
fill(0, 0, -5, 6)
v = villager({x = 0, y = 6.56, z = 0})
def.on_step(v, 0.05)
v.attached = {}
engine_moves(v, {x = 0, y = 3.56, z = 0})
def.on_step(v, 2.6)
assert_pos(v, 0, 3.56, 0, "an attached villager is left alone")

-- A move made by mcl_mobs or this mod inside on_step is the new baseline.
reset()
fill(0, 0, -5, 6)
fill(0, 0, 9, 12)
v = villager({x = 0, y = 12.51, z = 0})
def.on_step(v, 0.05)
v.move_to = {x = 0, y = 6.56, z = 0}
def.on_step(v, 0.05)
def.on_step(v, 0.05)
assert_pos(v, 0, 6.56, 0, "a move made during on_step is not undone on the next step")

print("floor_guard tests passed")
