-- Run with: lua tests/follower.lua
math.atan2 = math.atan2 or math.atan
local nodes = {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end

vector = {
	new = function(a) return {x = a.x, y = a.y, z = a.z} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
}
local vanilla_ticks = 0
mcl_mobs = {mob_class = {check_gowp = function() vanilla_ticks = vanilla_ticks + 1 end}}

local objects_near = {}
local clock = 0
minetest = {
	get_modpath = function() return "." end,
	get_item_group = function() return 0 end,
	registered_nodes = {air = {walkable = false}, ["mcl_core:stone"] = {walkable = true}},
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
	get_objects_inside_radius = function() return objects_near end,
	get_us_time = function() return clock end,
	after = function() end,
}

local function reset()
	nodes = {}
	for x = -5, 10 do
		for z = -5, 10 do nodes[key({x = x, y = -1, z = z})] = "mcl_core:stone" end
	end
	objects_near = {}
end

local follower = dofile("follower.lua")
local def = {}
follower.install(def)

-- Feet cell y = 0 stands on the floor at y = -1; entity y is the floor's top.
local DT = 0.1
local function villager(x, z, path)
	local pos, velocity, yaw = {x = x, y = -0.49, z = z}, 0, 0
	local self = {
		state = "gowp", jump = true, jump_height = 4, walk_velocity = 1.2, run_velocity = 3, rotate = 0,
		actions = {}, jumps = 0, arrived = false,
	}
	self.object = {
		get_pos = function() return {x = pos.x, y = pos.y, z = pos.z} end,
		get_yaw = function() return yaw end,
		get_velocity = function() return {x = 0, y = self.vy or 0, z = 0} end,
		set_velocity = function(_, v)
			self.object_velocity = v
			if v.y == 4.3 then self.jumps = self.jumps + 1; self.jumped = v end
		end,
		set_acceleration = function() end,
	}
	self.turn_in_direction = function(_, dx, dz) yaw = -math.atan2(dx, dz) end
	self.set_velocity = function(_, v) velocity = v end
	self.set_animation = function() end
	self.do_pathfind_action = function(entity, action) table.insert(entity.actions, action) end
	self.callback_arrived = function() self.arrived = true end
	self.waypoints = {}
	for i, p in ipairs(path) do self.waypoints[i] = {pos = p, failed_attempts = 0, action = p.action} end
	self.current_target = table.remove(self.waypoints, 1)
	self._target = path[#path]
	self.walked = {}
	-- Drive one tick, then move the villager along its heading.
	self.tick = function()
		clock = clock + DT * 1e6
		def.check_gowp(self, DT)
		pos.x = pos.x - math.sin(yaw) * velocity * DT
		pos.z = pos.z + math.cos(yaw) * velocity * DT
		table.insert(self.walked, {x = pos.x, z = pos.z})
	end
	self.pos = function() return pos end
	return setmetatable(self, {__index = def})
end

local function run(self, seconds)
	for _ = 1, seconds / DT do
		if self.state ~= "gowp" then break end
		self.tick()
	end
end

local function cell(x, z, action) return {x = x, y = 0, z = z, action = action} end

-- A route that was not flagged is vanilla's.
reset()
local plain = villager(0, 0, {cell(0, 0), cell(3, 0)})
plain.tick()
assert(vanilla_ticks == 1, "unflagged routes go to check_gowp")

-- line_is_clear: open floor, and a wall in the way.
reset()
assert(follower.line_is_clear(cell(0, 0), cell(4, 3)), "open floor is clear")
nodes[key({x = 2, y = 0, z = 1})] = "mcl_core:stone"
nodes[key({x = 2, y = 1, z = 1})] = "mcl_core:stone"
assert(not follower.line_is_clear(cell(0, 0), cell(4, 2)), "a wall on the line is not clear")
assert(not follower.line_is_clear(cell(0, 0), {x = 4, y = 1, z = 0}), "different levels are never a straight line")

-- Arrival is the planned final cell, not 1.8 blocks short of it.
reset()
local v = villager(0, 0, {cell(0, 0), cell(1, 0), cell(2, 0)})
follower.begin(v)
v.object.get_pos = function() return {x = 0.5, y = -0.49, z = 0} end
for _ = 1, 3 do v.tick() end
assert(not v.arrived and v.state == "gowp", "1.5 blocks short is not arrival")
v = villager(0, 0, {cell(0, 0), cell(2, 0)})
follower.begin(v)
run(v, 6)
assert(v.arrived and v.state == "stand" and v.order == "stand", "arrives on the final cell")
assert(math.abs(v.pos().x - 2) < 0.4, "stands on the final cell, at " .. v.pos().x)

-- A clear corner is cut, a blocked one is not.
reset()
v = villager(0, 0, {cell(0, 0), cell(4, 0), cell(4, 4)})
follower.begin(v)
run(v, 8)
assert(v.arrived, "corner route arrives " .. v.state .. " " .. v.pos().x .. "," .. v.pos().z .. " " .. tostring(v._villages_follow_failed and v._villages_follow_failed.reason))
local cut = false
for _, p in ipairs(v.walked) do
	if p.x > 1 and p.x < 3 and p.z > 1 and p.z < 3 then cut = true end
end
assert(cut, "a clear corner is cut")
reset()
for y = 0, 1 do nodes[key({x = 2, y = y, z = 2})] = "mcl_core:stone" end
v = villager(0, 0, {cell(0, 0), cell(4, 0), cell(4, 4)})
follower.begin(v)
run(v, 10)
assert(v.arrived, "blocked corner route arrives")
for _, p in ipairs(v.walked) do
	assert(not (math.abs(p.x - 2) < 0.8 and math.abs(p.z - 2) < 0.8), "never enters the wall's block")
end

-- A door is a step: the action fires at the cell before it, standing there.
reset()
local open = {type = "door", action = "open", target = {x = 2, y = 0, z = 0}}
v = villager(0, 0, {cell(0, 0), cell(1, 0, open), cell(2, 0), cell(3, 0)})
follower.begin(v)
run(v, 6)
assert(v.arrived and #v.actions == 1 and v.actions[1] == open, "the door action fires once")

-- A door that cannot be crossed ends the walk with a reason.
v = villager(0, 0, {cell(0, 0), cell(1, 0, open), cell(2, 0), cell(3, 0)})
v.do_pathfind_action = function(entity) entity._villages_blocked_door = {x = 2, y = 0, z = 0} end
follower.begin(v)
run(v, 6)
assert(v.state == "stand" and v._villages_follow_failed.reason == "door cannot be crossed", "blocked door")
assert(v._villages_blocked_door == nil and v._villages_follow == nil, "state is cleared")

-- No progress ends the walk instead of waiting: pinned by a wall it cannot see.
reset()
v = villager(0, 0, {cell(0, 0), cell(4, 0)})
follower.begin(v)
v.set_velocity = function() end
run(v, 6)
assert(v._villages_follow_failed and v._villages_follow_failed.reason == "no progress along the route", "stall")

-- Another villager in the way is waited for, then planned around.
v = villager(0, 0, {cell(0, 0), cell(4, 0)})
follower.begin(v)
v.set_velocity = function() end
objects_near = {{
	is_player = function() return false end, get_pos = function() return {x = 0.7, y = 0, z = 0} end,
	get_luaentity = function() return {is_mob = true} end,
}}
run(v, 2.5)
assert(v.state == "gowp", "waits for the villager at first")
run(v, 6)
local failed = v._villages_follow_failed
assert(failed and failed.reason == "blocked by another villager" and failed.blocker.x == 0.7, "then gives up around it")

-- Shoved far off its route.
reset()
v = villager(0, 0, {cell(0, 0), cell(8, 0)})
follower.begin(v)
v.object.get_pos = function() return {x = 0, y = -0.49, z = 6} end
v.tick()
assert(v._villages_follow_failed.reason == "off the planned route", "off route")

-- A rise is a step of its own: one jump beside the step, with forward speed
-- (vanilla's jump takes its speed from the villager, which may have none), even
-- on the tick it lands, when its fall speed is still on it.
reset()
nodes[key({x = 2, y = 0, z = 0})] = "mcl_core:stone"
v = villager(0, 0, {cell(0, 0), {x = 2, y = 1, z = 0}})
follower.begin(v)
v.vy = -4
run(v, 1.2)
assert(v.jumps == 1, "jumps once toward a rise, not " .. v.jumps)
assert(v.jumped.x > 1 and math.abs(v.jumped.z) < 0.01, "with forward speed along the heading")

-- Holding for a turn stops what is moving, not just the acceleration
-- (upstream's set_velocity(0) leaves the object's velocity alone).
reset()
v = villager(0, 0, {cell(0, 0), cell(4, 0)})
follower.begin(v)
v.turn_in_direction = function() end -- the yaw lags: still facing +z
v.object_velocity = {x = 1.2, y = 0, z = 0}
v.tick()
assert(v.object_velocity.x == 0 and v.object_velocity.z == 0, "horizontal velocity is cleared while turning")

-- A detour around a villager is not shortcut back through it.
reset()
v = villager(0, 0, {cell(0, 0), cell(0, 1), cell(1, 1), cell(2, 1), cell(2, 0)})
follower.begin(v)
v._villages_follow.avoid = {{x = 1, y = 0, z = 0}}
run(v, 10)
assert(v.arrived, "detour arrives")
for _, p in ipairs(v.walked) do
	assert(math.sqrt((p.x - 1) ^ 2 + p.z ^ 2) > 0.6, "keeps clear of the blocker")
end

-- Bobbing up and down at a step it cannot climb is not progress.
reset()
v = villager(0, 0, {cell(0, 0), cell(4, 0)})
follower.begin(v)
local bob = 0
v.set_velocity = function() end
v.object.get_pos = function() bob = bob + 1; return {x = 0, y = -0.49 + (bob % 2) * 0.5, z = 0} end
run(v, 6)
assert(v._villages_follow_failed and v._villages_follow_failed.reason == "no progress along the route", "bobbing is a stall")

print("follower tests passed")
