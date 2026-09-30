-- Run with: lua tests/wander.lua
-- Lua 5.3+ folded atan2 into atan; the game runs LuaJIT, which has both.
math.atan2 = math.atan2 or math.atan
local nodes = {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end

vector = {
	new = function(a) return {x = a.x, y = a.y, z = a.z} end,
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
}
mcl_mobs = {mob_class = {get_staticdata = function(self)
	return self._villages_wander and "with leg" or "without leg"
end}}

minetest = {
	get_modpath = function() return "." end,
	get_item_group = function() return 0 end,
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["mcl_fences:fence"] = {walkable = true},
		["mcl_core:water_source"] = {walkable = false, liquidtype = "source"},
	},
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
}

local function fill(x1, y1, z1, x2, y2, z2, name)
	for x = x1, x2 do
		for y = y1, y2 do
			for z = z1, z2 do nodes[key({x = x, y = y, z = z})] = name end
		end
	end
end

local function reset()
	nodes = {}
	fill(-10, -1, -10, 10, -1, 10, "mcl_core:stone")
end

local def = {}
local inner_result
def.do_custom = function() return inner_result end
dofile("wander.lua")(def)

-- A villager standing on the floor at y = -1, facing yaw. Only the mob API
-- this module calls is stubbed; set_velocity moves the villager one step at
-- its heading so a leg can be driven to its end.
local function villager(x, z, yaw)
	local pos = {x = x, y = -0.49, z = z}
	local self = {
		state = "walk", walk_chance = 50, walk_velocity = 1.2, rotate = 0, pause_timer = 0,
		object = {
			get_pos = function() return {x = pos.x, y = pos.y, z = pos.z} end,
			get_yaw = function() return yaw end,
		},
	}
	self.turn_in_direction = function(_, dx, dz)
		-- Turn straight away; smoothing is vanilla's concern.
		yaw = -math.atan2(dx, dz)
		self.target_yaw = yaw
	end
	self.set_velocity = function(_, v)
		self.velocity = v
		pos.x, pos.z = pos.x - math.sin(yaw) * v * 0.1, pos.z + math.cos(yaw) * v * 0.1
	end
	self.set_animation = function(_, name) self.animation = name end
	self.stand = function()
		self.state = "stand"
		self.velocity = 0
	end
	self.move_to = function(_, x, z) pos.x, pos.z = x, z end
	return self
end

local function step(self, times)
	local result
	for _ = 1, times or 1 do result = def.do_custom(self, 0.1) end
	return result
end

local function leg_is_clear(self, from)
	local target = self._villages_wander.target
	local dx, dz = target.x - from.x, target.z - from.z
	local length = math.sqrt(dx * dx + dz * dz)
	for d = 0, length, 0.1 do
		local x, z = from.x + dx / length * d, from.z + dz / length * d
		for _, cx in ipairs({math.floor(x - 0.3 + 0.5), math.floor(x + 0.3 + 0.5)}) do
			for _, cz in ipairs({math.floor(z - 0.3 + 0.5), math.floor(z + 0.3 + 0.5)}) do
				if nodes[key({x = cx, y = 0, z = cz})] then return false end
			end
		end
	end
	return true
end

-- Facing a wall a node ahead: the leg goes somewhere open instead.
math.randomseed(1)
for _ = 1, 20 do
	reset()
	fill(-10, 0, 1, 10, 1, 1, "mcl_core:stone")
	local self = villager(0, 0, 0)
	assert(step(self) == false, "a planned leg keeps vanilla's wander from running")
	local leg = self._villages_wander
	assert(leg, "open floor behind the villager gives it a leg")
	assert(leg.target.z < 0.3, "the leg does not head into the wall")
	assert(leg_is_clear(self, {x = 0, z = 0}), "every step of the leg is clear")
	assert(vector.distance({x = 0, y = leg.target.y, z = 0}, leg.target) >= 2 - 1e-9, "a leg is worth walking")
end

-- Open ground ahead: vanilla's heading is kept.
reset()
local ahead = villager(0, 0, 0)
step(ahead)
assert(math.abs(ahead._villages_wander.target.x) < 1e-9 and ahead._villages_wander.target.z >= 2,
	"a clear heading is walked as vanilla chose it")

-- Hemmed in on every side, by walls and a fence: stand rather than push.
reset()
fill(-1, 0, -1, 1, 1, -1, "mcl_core:stone")
fill(-1, 0, 1, 1, 1, 1, "mcl_core:stone")
fill(-1, 0, 0, -1, 1, 0, "mcl_core:stone")
fill(1, 0, 0, 1, 0, 0, "mcl_fences:fence")
local boxed = villager(0, 0, 0)
assert(step(boxed) == nil, "standing leaves the rest of the tick to vanilla")
assert(boxed.state == "stand" and boxed._villages_wander == nil, "a boxed-in villager stands")

-- Water and one-node pits are not somewhere to walk; a floor that falls
-- away ends the leg too.
reset()
fill(-10, 0, 1, 10, 1, 10, "mcl_core:stone")
fill(-10, 0, -10, -1, 1, 0, "mcl_core:stone")
fill(1, 0, -10, 10, 1, 0, "mcl_core:stone")
fill(0, -1, -10, 0, -1, -2, "mcl_core:water_source")
local shore = villager(0, 0, math.pi)
step(shore)
assert(shore.state == "stand", "a villager does not walk into water")

-- A one-node step up is climbed only with headroom over the lower side.
reset()
fill(-10, 0, 2, 10, 0, 10, "mcl_core:stone")
fill(-10, 0, -10, 10, 1, -1, "mcl_core:stone")
fill(-1, 0, 0, -1, 1, 10, "mcl_core:stone")
fill(1, 0, 0, 1, 1, 10, "mcl_core:stone")
local climber = villager(0, 0, 0)
step(climber)
assert(climber._villages_wander.target.y == 1, "a step up is followed onto the higher floor")
reset()
fill(-10, 0, 2, 10, 0, 10, "mcl_core:stone")
fill(-10, 0, -10, 10, 1, -1, "mcl_core:stone")
fill(-1, 0, 0, -1, 1, 10, "mcl_core:stone")
fill(1, 0, 0, 1, 1, 10, "mcl_core:stone")
fill(-1, 2, 0, 1, 2, 1, "mcl_core:stone")
local ducked = villager(0, 0, 0)
step(ducked)
assert(ducked.state == "stand", "a low ceiling on the near side stops the climb")

-- A one-node drop is stepped down; a deeper one ends the leg at the edge.
reset()
fill(-10, 0, -10, 10, 1, -1, "mcl_core:stone")
fill(-1, 0, 0, -1, 1, 10, "mcl_core:stone")
fill(1, 0, 0, 1, 1, 10, "mcl_core:stone")
fill(-10, -1, 2, 10, -1, 10, "air")
fill(-10, -2, 2, 10, -2, 10, "mcl_core:stone")
local descender = villager(0, 0, 0)
step(descender)
assert(descender._villages_wander.target.y == -1, "a step down is followed onto the lower floor")
fill(-10, -2, 2, 10, -2, 10, "air")
local edge = villager(0, 0, 0)
step(edge)
assert(edge.state == "stand", "a villager does not walk off a two-node drop")

-- A leg runs to its target and stops there.
reset()
local walker = villager(0, 0, 0)
step(walker)
local target = walker._villages_wander.target
for _ = 1, 200 do
	if walker.state ~= "walk" then break end
	step(walker)
end
assert(walker.state == "stand" and walker._villages_wander == nil, "a leg ends in a stop")
local here = walker.object.get_pos()
assert(math.abs(here.x - target.x) < 0.3 and math.abs(here.z - target.z) < 0.3, "the stop is at the target")

-- Blocked partway (another mob in the way): give up rather than push.
reset()
local blocked = villager(0, 0, 0)
step(blocked)
blocked.set_velocity = function(_, v) blocked.velocity = v end
step(blocked, 25)
assert(blocked.state == "stand", "a stalled leg ends in a stop")

-- A turn is made on the spot before walking.
reset()
fill(-10, 0, 1, 10, 1, 1, "mcl_core:stone")
local turner = villager(0, 0, 0)
local yaw = 0
turner.object.get_yaw = function() return yaw end
turner.turn_in_direction = function() end
step(turner)
assert(turner.velocity == 0 and turner.animation == "stand", "the villager turns before walking off")

-- Leave vanilla in charge of anything else.
reset()
local slab = villager(0, 0, 0)
fill(0, 0, 0, 0, 0, 0, "mcl_core:stone")
assert(step(slab) == nil and slab.state == "walk" and not slab._villages_wander,
	"a villager not on ordinary floor keeps vanilla's walk")
reset()
local pushed = villager(0, 0, 0)
step(pushed)
pushed.pause_timer = 0.5
assert(step(pushed) == nil and pushed._villages_wander == nil, "a knockback drops the leg")
reset()
local tripping = villager(0, 0, 0)
step(tripping)
tripping.state = "gowp"
assert(step(tripping) == nil and tripping._villages_wander == nil, "a trip drops the leg")
reset()
local watched = villager(0, 0, 0)
step(watched)
watched.walk_chance = 0
step(watched)
assert(watched.state == "stand", "a nearby player stops the walk, as vanilla's scan intends")
reset()
local sleeper = villager(0, 0, 0)
step(sleeper)
inner_result = false
assert(step(sleeper) == false and sleeper._villages_wander == nil, "an inner takeover drops the leg")
inner_result = nil

-- The leg is never written into the villager's save.
reset()
local saved = villager(0, 0, 0)
step(saved)
assert(def.get_staticdata(saved) == "without leg" and saved._villages_wander, "the leg is left out of staticdata")

print("wander tests passed")
