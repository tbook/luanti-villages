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
-- Vanilla's do_jump (mcl_mobs/movement.lua), as far as it matters here: from where
-- it stands it hops straight up when a solid node is about to be walked into
-- (within 0.8 nodes ahead at knee height), stopping what it was doing. It runs
-- after check_gowp on every step. Off unless a test turns it on.
local vanilla_jump
mcl_mobs = {mob_class = {
	check_gowp = function() vanilla_ticks = vanilla_ticks + 1 end,
	do_jump = function(self)
		if not vanilla_jump then return end
		local pos, yaw = self.object:get_pos(), self.object:get_yaw() + self.rotate
		local ahead = {x = math.floor(pos.x - math.sin(yaw) * 0.8 + 0.5), y = 0, z = math.floor(pos.z + math.cos(yaw) * 0.8 + 0.5)}
		if nodes[ahead.x .. "," .. ahead.y .. "," .. ahead.z] then
			self.hops = (self.hops or 0) + 1
			self:set_velocity(0)
		end
	end,
}}

local objects_near = {}
local clock = 0
local pending = {}
minetest = {
	get_modpath = function() return "." end,
	get_item_group = function() return 0 end,
	registered_nodes = {air = {walkable = false}, ["mcl_core:stone"] = {walkable = true}},
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
	get_objects_inside_radius = function() return objects_near end,
	get_us_time = function() return clock end,
	log = function() end,
	get_day_count = function() return 3 end,
	get_timeofday = function() return 0.5 end,
	pos_to_string = function(pos) return "(" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")" end,
	after = function(_, callback, ...) table.insert(pending, {callback, ...}) end,
}

local function reset()
	nodes = {}
	for x = -5, 10 do
		for z = -5, 10 do nodes[key({x = x, y = -1, z = z})] = "mcl_core:stone" end
	end
	objects_near = {}
end

local follower = dofile("follower.lua")
local def = setmetatable({}, {__index = mcl_mobs.mob_class})
follower.install(def)

-- Feet cell y = 0 stands on the floor at y = -1; entity y is the floor's top.
local DT = 0.1
local function villager(x, z, path)
	local pos, velocity, yaw = {x = x, y = -0.49, z = z}, 0, 0
	local self = {
		state = "gowp", jump = true, jump_height = 4, walk_velocity = 1.2, run_velocity = 2.4, rotate = 0,
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
		set_acceleration = function(_, a) self.acceleration = a end,
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
		self:do_jump()
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
assert(v._villages_last_walk_failure.reason == "no progress along the route" and v._villages_last_walk_failure.day == 3, "failure kept for the diagnostic")

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

-- Vanilla's own jump must not run on a followed walk: it hops straight up in
-- place near a rise (while the villager turns to face it, or stands just outside
-- the distance the follower's own jump starts at) and never gets anywhere (#194).
-- The villager starts 1.3 nodes from the step, as the stalled ones were.
reset()
vanilla_jump = true
nodes[key({x = 2, y = 0, z = 0})] = "mcl_core:stone"
v = villager(0.7, 0.3, {cell(1, 0), {x = 2, y = 1, z = 0}})
follower.begin(v)
run(v, 1)
assert((v.hops or 0) == 0, "vanilla's hops do not run on a followed walk, " .. tostring(v.hops))
assert(v.jumps >= 1, "its own jump does")
-- Off the follower it is vanilla's, and it hops.
local plain_walk = villager(0.7, 0.3, {cell(1, 0), {x = 2, y = 1, z = 0}})
plain_walk:turn_in_direction(1, 0)
plain_walk.tick()
assert((plain_walk.hops or 0) > 0, "control: without the follower the villager hops at the step")

-- In water vanilla's hop stays (it is how a villager swims out).
local real_group = minetest.get_item_group
minetest.get_item_group = function(name, group) return (name == "default:water" and group == "water") and 1 or 0 end
nodes[key({x = 1, y = 0, z = 0})] = "default:water"
local swimmer = villager(0.7, 0.3, {cell(1, 0), {x = 2, y = 1, z = 0}})
follower.begin(swimmer)
swimmer.object.get_pos = function() return {x = 0.7, y = 0, z = 0.3} end
swimmer:turn_in_direction(1, 0)
swimmer:do_jump()
assert((swimmer.hops or 0) > 0, "in water vanilla's jump still runs on a followed walk")
nodes[key({x = 1, y = 0, z = 0})] = nil
minetest.get_item_group = real_group

-- Once the walk is over (arrived or given up) the wrapper is vanilla's again.
reset()
nodes[key({x = 2, y = 0, z = 0})] = "mcl_core:stone"
local ended = villager(0.7, 0.3, {cell(1, 0), {x = 2, y = 1, z = 0}})
follower.begin(ended)
ended:turn_in_direction(1, 0)
ended:do_jump()
assert((ended.hops or 0) == 0, "followed: suppressed")
ended.object.get_pos = function() return {x = 0, y = -0.49, z = 6} end
ended.tick()
assert(ended._villages_follow_failed.reason == "off the planned route", "gave up")
ended.object.get_pos = function() return {x = 0.7, y = -0.49, z = 0.3} end
ended:do_jump()
assert((ended.hops or 0) > 0, "after give_up vanilla's jump runs again")
reset()
local done = villager(0, 0, {cell(0, 0), cell(1, 0)})
follower.begin(done)
done.object.get_pos = function() return {x = 1, y = -0.49, z = 0} end
done.tick()
assert(done.arrived, "arrived")
done.object.get_pos = function() return {x = 0.7, y = -0.49, z = 0.3} end
done:turn_in_direction(1, 0)
nodes[key({x = 2, y = 0, z = 0})] = "mcl_core:stone"
done:do_jump()
assert((done.hops or 0) > 0, "after arrive vanilla's jump runs again")
vanilla_jump = false

-- The pushes scheduled with a jump end with the walk: after arriving on the
-- raised final cell, a late callback does not move the villager again.
reset()
nodes[key({x = 2, y = 0, z = 0})] = "mcl_core:stone"
v = villager(0, 0, {cell(0, 0), {x = 2, y = 1, z = 0}})
v.object.get_luaentity = function() return v end
follower.begin(v)
pending = {}
run(v, 1.2)
assert(#pending == 3, "a jump schedules three pushes")
v.acceleration = nil
v.object.get_pos = function() return {x = 2, y = 0.51, z = 0} end
v.tick()
assert(v.state == "stand" and v.arrived, "arrived on the raised cell")
v.acceleration = {x = 0, y = 0, z = 0}
for _, p in ipairs(pending) do p[1](v) end
assert(v.acceleration.x == 0 and v.acceleration.z == 0, "stale pushes do nothing after arrival")

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

-- On a descent the waypoint is not reached while the body is still above its
-- floor: the villager keeps on, and a stall there ends the walk (#173). The feet
-- cell rounds up a quarter node early, so height is judged on the floor's top.
reset()
for x = -5, 10 do for z = -5, 10 do nodes[key({x = x, y = -2, z = z})] = "mcl_core:stone" end end
local function descent(x, y)
	local d = villager(0, 0, {{x = 1, y = -1, z = 0}, {x = 1, y = -1, z = 1}})
	follower.begin(d)
	d.object.get_pos = function() return {x = x, y = y, z = 0} end
	d.set_velocity = function() end
	return d
end
v = descent(1, -0.49)
run(v, 1)
assert(v.current_target.pos.z == 0, "still heading for the lower waypoint while high on the stair")
run(v, 6)
assert(v._villages_follow_failed and v._villages_follow_failed.reason == "no progress along the route", "a stall on the stair ends the walk")
-- Halfway down: the feet cell already reads -1, the body is still 0.5 high.
v = descent(0.75, -0.99)
v.tick()
assert(v.current_target.pos.z == 0, "half a node above the landing does not turn yet")
v = descent(1, -1.49)
v.tick()
assert(v.current_target.pos.z == 1, "moves on once down")

-- A hop down carries the villager on past the lower waypoint (it leaves the
-- ledge at walking or running speed and falls with that speed still on it), and
-- one that lands more than REACH beyond the centre used to turn round and walk
-- back to it before going on down the stair (#186). On a stair of one-block drops
-- nothing shortcuts the next waypoint, so every hop could turn it round. Having
-- landed on the lower level beyond the waypoint, along the leg, counts as there.
-- Each case runs on its own so that one failure does not hide the others.
local planner = dofile("planner.lua")
local failures = {}
local function case(name, fn)
	local ok, err = pcall(fn)
	if not ok then table.insert(failures, name .. ": " .. tostring(err)) end
end
reset()
for x = -5, 20 do
	for z = -5, 10 do
		nodes[key({x = x, y = -1, z = z})] = x <= 0 and "mcl_core:stone" or nil
		nodes[key({x = x, y = -2, z = z})] = x == 1 and "mcl_core:stone" or nil
		nodes[key({x = x, y = -3, z = z})] = x >= 2 and "mcl_core:stone" or nil
	end
end
-- Cells (0,0,0) -> (1,-1,0) -> (2,-2,0), then `more` further cells on the level.
local function stair(x, y, more, path_overrides)
	local path = {{x = 1, y = -1, z = 0}, {x = 2, y = -2, z = 0}}
	for i = 1, more or 0 do path[#path + 1] = {x = 2 + i, y = -2, z = 0} end
	for i, p in pairs(path_overrides or {}) do path[i] = p end
	local d = villager(0, 0, path)
	follower.begin(d)
	d.object.get_pos = function() return {x = x, y = y, z = 0} end
	d.set_velocity = function(_, speed) d.speed = speed end
	return d
end
case("lands past: goes on", function()
	local d = stair(1.45, -1.49)
	d.tick()
	assert(d.current_target.pos.x == 2, "goes on to the next waypoint, not back (at " .. d.current_target.pos.x .. ")")
	d.tick()
	assert(d.object.get_yaw() < 0, "and faces on down the stair, not back")
end)
case("short of the waypoint: heads for it", function()
	local d = stair(0.55, -1.49)
	d.tick()
	assert(d.current_target.pos.x == 1)
end)
case("falling past: dropped straight down", function()
	local d = stair(1.45, -0.8)
	d.vy = -4
	d.tick()
	assert(d.current_target.pos.x == 1, "not reached yet")
	assert(d.object.get_yaw() == 0, "does not swing round to the waypoint")
	assert(d.object_velocity and d.object_velocity.x == 0 and d.speed == 0, "drops straight down")
end)
case("held up past: faces on", function()
	local d = stair(1.45, -0.8)
	d.tick()
	assert(d.object.get_yaw() < 0, "faces the next waypoint, not back")
end)
case("a small fall is not held (stair treads)", function()
	-- Half a node above the floor and falling: on a stair this happens at every
	-- step, and it must keep walking.
	local d = stair(1.2, -1.0)
	d.vy = -2
	d.tick()
	assert(d.speed ~= 0, "keeps its speed down a half-block tread")
end)
case("final cell: walks back", function()
	local d = villager(0, 0, {{x = 1, y = -1, z = 0}})
	follower.begin(d)
	d.object.get_pos = function() return {x = 1.45, y = -1.49, z = 0} end
	d.set_velocity = function() end
	d.tick()
	assert(d.state == "gowp" and not d.arrived, "not reached from beyond it")
	assert(d.object.get_yaw() > 0, "turns back to the final cell")
end)
case("a door step is not skipped", function()
	local d = stair(1.45, -1.49, 0, {[1] = {x = 1, y = -1, z = 0, action = {type = "door", action = "open", target = {x = 1, y = -1, z = 0}}}})
	d.waypoints[1].action = nil
	d.current_target.action = {type = "door", action = "open", target = {x = 1, y = -1, z = 0}}
	d.tick()
	assert(d.current_target.pos.x == 1 and #d.actions == 0, "the door waypoint stays current")
end)
case("a sharp turn beside a wall is walked from the centre", function()
	-- Landed 0.4 past (1,-1,0); the next waypoint (2,-2,1) is diagonally on, past a
	-- wall corner at (2,*,1) that the straight line from the landing spot clips.
	local function landed_past()
		local d = villager(0, 0, {{x = 1, y = -1, z = 0}, {x = 2, y = -2, z = 1}})
		follower.begin(d)
		d.object.get_pos = function() return {x = 1.4, y = -1.49, z = 0} end
		d.set_velocity = function() end
		d.tick()
		return d
	end
	assert(landed_past().current_target.pos.x == 2, "control: open ground goes on")
	for _, yy in ipairs({-1, 0}) do nodes[key({x = 2, y = yy, z = 1})] = "mcl_core:stone" end
	local d = landed_past()
	for _, yy in ipairs({-1, 0}) do nodes[key({x = 2, y = yy, z = 1})] = nil end
	assert(d.current_target.pos.x == 1, "with a wall on the line it walks back to the centre first")
end)
case("a staircase routed by the planner is walked on down", function()
	local function stand(pos)
		return pos.z == 0 and pos.x >= 0 and pos.x <= 3 and pos.y == 1 - pos.x
			and nodes[key({x = pos.x, y = pos.y - 1, z = 0})] == "mcl_core:stone"
	end
	for x = 0, 3 do nodes[key({x = x, y = -x, z = 0})] = "mcl_core:stone" end
	local route = planner.find_path({x = 0, y = 1, z = 0}, stand, function(p) return p.x == 3 end, {range = 8})
	assert(route and #route == 4)
	local d = villager(0, 0, {route[2], route[3], route[4]})
	follower.begin(d)
	d.set_velocity = function(_, speed) d.speed = speed end
	-- Half a node above each tread as it walks down: never held.
	for _, wp in ipairs({route[2], route[3]}) do
		d.object.get_pos = function() return {x = wp.x + 0.2, y = wp.y - 0.99 + 0.5, z = 0} end
		d.vy = -2
		d.speed = nil
		d.tick()
		assert(d.speed ~= 0, "a stair descent is not stopped step by step")
	end
end)
case("at run speed the next hop is walked at run speed", function()
	local d = stair(1.45, -1.49, 16)
	d.tick()
	d.tick()
	assert(d.speed == 2.4, "runs on with " .. #d.waypoints .. " waypoints left, speed " .. tostring(d.speed))
end)
if #failures > 0 then error(table.concat(failures, "\n"), 0) end

print("follower tests passed")
