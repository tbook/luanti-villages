-- Run with: lua tests/wander.lua
-- Lua 5.3+ folded atan2 into atan; the game runs LuaJIT, which has both.
math.atan2 = math.atan2 or math.atan
local nodes = {}
local lookups = 0
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
	get_item_group = function(name, group)
		local groups = {["mcl_fences:fence_gate"] = {fence_gate = 1}, ["mcl_walls:cobble"] = {wall = 1}}
		return (groups[name] or {})[group] or 0
	end,
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["mcl_fences:fence"] = {walkable = true},
		["mcl_fences:fence_gate"] = {walkable = true, collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.125, 0.5, 1, 0.125}}},
		["mcl_walls:cobble"] = {walkable = true, collision_box = {type = "fixed", fixed = {-0.25, -0.5, -0.25, 0.25, 1, 0.25}}},
		["mcl_core:water_source"] = {walkable = false, liquidtype = "source"},
	},
	get_node_or_nil = function(pos)
		lookups = lookups + 1
		return {name = nodes[key(pos)] or "air"}
	end,
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

-- A closed gate or a wall across the way is one node high with air above,
-- but do_jump will not jump either, so it is not a step to climb.
for _, barrier in ipairs({"mcl_fences:fence_gate", "mcl_walls:cobble"}) do
	reset()
	fill(-10, 0, -10, 10, 1, -1, "mcl_core:stone")
	fill(-1, 0, 0, -1, 1, 10, "mcl_core:stone")
	fill(1, 0, 0, 1, 1, 10, "mcl_core:stone")
	fill(0, 0, 1, 0, 0, 1, barrier)
	local penned = villager(0, 0, 0)
	step(penned)
	assert(penned.state == "stand", "a villager does not plan to climb " .. barrier)
end

-- A fully open heading ends the search: the other headings are not sampled.
reset()
local open = villager(0, 0, 0)
lookups = 0
step(open)
assert(lookups < 1000, "an open heading is planned without trying every other (" .. lookups .. " lookups)")

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

-- An anchor keeps every leg within its radius, from the middle or from the rim.
math.randomseed(5)
for _, start in ipairs({{0, 0}, {3.4, 0}, {0, -3.5}}) do
	for _ = 1, 30 do
		reset()
		local anchored = villager(start[1], start[2], math.random() * 6.28)
		anchored._villages_wander_anchor = {pos = {x = 0, y = -1, z = 0}, radius = 4}
		step(anchored)
		local leg = anchored._villages_wander
		if leg then
			assert(math.sqrt(leg.target.x ^ 2 + leg.target.z ^ 2) <= 4 + 1e-9, "an anchored leg ends within the radius")
		end
	end
end

-- Outside the radius, legs lead back in rather than going farther out.
reset()
for _ = 1, 20 do
	local outside = villager(8, 0, math.pi / 2)
	outside._villages_wander_anchor = {pos = {x = 0, y = -1, z = 0}, radius = 4}
	step(outside)
	local leg = outside._villages_wander
	assert(leg and leg.target.x <= 8 + 1e-9, "a villager outside the radius is not led farther out")
end

-- An anchor's max_y keeps legs off a step up (the well's rim, #11): without it
-- some legs climb the block, with it none does.
local function climbs(max_y)
	local climbed = false
	math.randomseed(9)
	for _ = 1, 60 do
		reset()
		fill(2, 0, -10, 3, 0, 10, "mcl_core:stone")
		local anchored = villager(0, 0, math.random() * 6.28)
		anchored._villages_wander_anchor = {pos = {x = 0, y = 0, z = 0}, radius = 6, max_y = max_y}
		step(anchored)
		local leg = anchored._villages_wander
		if leg and leg.target.y > 0 then climbed = true end
	end
	return climbed
end
assert(climbs(nil), "legs climb a step with no height limit")
assert(not climbs(0), "an anchor's max_y keeps legs on the level")

print("wander tests passed")
