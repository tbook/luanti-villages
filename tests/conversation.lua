-- Run with: lua tests/conversation.lua
local time = 6000 / 24000
local now, day = 1000, 1
local setting = true
local logged = {}

vector = {
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	round = function(a) return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
}

local objects = {}
minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_item_group = function() return 0 end,
	registered_nodes = {},
	settings = {get_bool = function(_, name, default)
		assert(name == "living_villages_conversation", "the setting is read by its name")
		return setting
	end},
	log = function(_, message) logged[#logged + 1] = message end,
	get_objects_inside_radius = function(pos, radius)
		local found = {}
		for _, object in ipairs(objects) do
			if vector.distance(pos, object:get_pos()) <= radius then found[#found + 1] = object end
		end
		return found
	end,
}

local conversation = dofile("conversation.lua")
local def = {
	on_activate = function() end,
	do_custom = function() end,
	on_die = function() end,
	get_staticdata = function(self)
		local saved = {}
		for k, v in pairs(self) do if type(v) ~= "table" or k:match("^_villages") then saved[k] = v end end
		return saved
	end,
}
conversation.install(def)

local count = 0
local function villager(x, z, y)
	count = count + 1
	local self = {name = "mobs_mc:villager", _id = "v" .. count, state = "stand", pos = {x = x, y = y or 0, z = z}}
	self.object = {get_pos = function() return self.pos end}
	self.set_velocity = function(s) s.moving = false end
	self.set_animation = function(s, name) s.animation = name end
	self.set_yaw = function(s, yaw, delay) s.target_yaw, s.turn_delay = yaw, delay end
	local object = {get_pos = function() return self.pos end, get_luaentity = function() return self end}
	objects[#objects + 1] = object
	self.handle = object
	return self
end

local function clear()
	objects = {}
end

local function tick(self, dtime)
	return def.do_custom(self, dtime or 0.1)
end

-- Ticks everyone, a scan interval at a time, until a conversation forms (or 400 tries).
local function run_until_talking(group)
	for _ = 1, 400 do
		for _, v in ipairs(group) do tick(v, conversation.SCAN_MAX + 1) end
		for _, v in ipairs(group) do if v._villages_talk then return true end end
	end
	return false
end

local function talking(group)
	local n = 0
	for _, v in ipairs(group) do if v._villages_talk then n = n + 1 end end
	return n
end

local function yaw_to(from, to)
	-- A mob's forward is (-sin yaw, cos yaw): facing along (dx, dz).
	local dx, dz = to.x - from.x, to.z - from.z
	return math.atan2(-dx, dz)
end

local function same_angle(a, b)
	return math.abs((a - b + math.pi) % (2 * math.pi) - math.pi) < 1e-6
end

math.randomseed(7)
-- A pair forms, faces each other, and the yaw really points at the partner: a
-- partner due north (+z) gives yaw 0, due east (+x) gives -pi/2.
do
	clear()
	local a, b = villager(0, 0), villager(3, 0)
	assert(run_until_talking({a, b}), "two idle neighbours converse")
	assert(talking({a, b}) == 2, "a pair is two")
	tick(a); tick(b)
	assert(a.order == "stand" and b.order == "stand", "they hold with order stand")
	assert(same_angle(a.target_yaw, yaw_to(a.pos, b.pos)) and same_angle(a.target_yaw, -math.pi / 2), "a faces b (east)")
	assert(same_angle(b.target_yaw, yaw_to(b.pos, a.pos)) and same_angle(b.target_yaw, math.pi / 2), "b faces a (west)")
	assert(tick(a) == false, "vanilla's states are skipped while talking")
	a.order = nil
	tick(a)
	assert(a.order == "stand", "an order vanilla cleared is set again")
	-- The hold is 8-25 s.
	local left = a._villages_talk.group.until_time - now
	assert(left >= conversation.HOLD_MIN and left <= conversation.HOLD_MAX, "hold time is within bounds")
	-- Nothing of it is saved.
	local saved = def.get_staticdata(a)
	assert(saved._villages_talk == nil and saved._villages_talk_next == nil and a._villages_talk, "nothing is saved")
	-- It ends after the hold, order cleared, with a cooldown.
	now = now + 30
	tick(a); tick(b)
	assert(not a._villages_talk and not b._villages_talk and a.order == nil and b.order == nil, "it ends cleanly")
	assert(a._villages_talk_next > now, "a cooldown follows")
	for _ = 1, 50 do tick(a, conversation.SCAN_MAX + 1); tick(b, conversation.SCAN_MAX + 1) end
	assert(talking({a, b}) == 0, "no new conversation within the cooldown")
	now = now + 400
	assert(run_until_talking({a, b}), "after the cooldown they talk again")
end

-- A trio faces the mean of the other two; the group never exceeds three.
do
	clear()
	local group = {}
	for i = 1, 6 do group[i] = villager((i % 3) * 2, math.floor(i / 3) * 2) end
	local sizes = {}
	for round = 1, 30 do
		now = now + 1000
		for _, v in ipairs(group) do v._villages_talk, v._villages_talk_next, v.order = nil, nil, nil end
		if run_until_talking(group) then
			local seen = {}
			for _, v in ipairs(group) do
				if v._villages_talk then seen[v._villages_talk.group] = (seen[v._villages_talk.group] or 0) + 1 end
			end
			for _, n in pairs(seen) do
				assert(n <= conversation.MAX_GROUP, "a group is at most three")
				sizes[n] = true
			end
		end
	end
	assert(sizes[2] and sizes[3], "both pairs and trios occur")
	for _, v in ipairs(group) do
		tick(v)
		if v._villages_talk then
			local ox, oz, n = 0, 0, 0
			for _, m in ipairs(v._villages_talk.group.members) do
				if m ~= v then ox, oz, n = ox + m.pos.x, oz + m.pos.z, n + 1 end
			end
			assert(same_angle(v.target_yaw, yaw_to(v.pos, {x = ox / n, z = oz / n})), "a trio member faces the others")
		end
	end
end

-- Nobody forms a group alone, with a villager too far or on another level, or with a child.
do
	clear()
	local a = villager(0, 0)
	assert(not run_until_talking({a}), "a lone villager does not talk")
	local far, high, child = villager(conversation.RADIUS + 3, 0), villager(2, 0, 4), villager(1, 1)
	child.child = true
	assert(not run_until_talking({a, far, high, child}), "far, high and child villagers are no company")
end

-- Not when another system has the villager.
local function blocked(label, change)
	clear()
	local a, b = villager(0, 0), villager(2, 0)
	change(a)
	assert(not run_until_talking({a, b}), label .. ": no conversation")
end
blocked("planned route", function(v) v._villages_goto_route = {status = "planning"} end)
blocked("walking route", function(v) v._villages_bed_route = {status = "travelling"} end)
blocked("on a walk", function(v) v.state = "gowp" end)
blocked("asleep", function(v) v._villages_sleeping = true end)
blocked("sleep order", function(v) v.order = "sleep" end)
blocked("church", function(v) v._villages_church = {} end)
blocked("seat", function(v) v._villages_seat = {} end)
blocked("tavern trip", function(v) v._villages_tavern_target = {} end)
blocked("keeper", function(v) v._villages_keeper = true end)
blocked("following", function(v) v.following = {} end)
blocked("trading", function(v) v._trading_players = {p = true} end)
blocked("on the way to the well", function(v) v._villages_well = {} end)
blocked("on the way to the bell", function(v) v._villages_bell = {} end)
blocked("work stage", function() time = 9000 / 24000 end)
time = 6000 / 24000
blocked("night", function() time = 22000 / 24000 end)
time = 6000 / 24000

-- At the well or the bell, arrived, villagers do talk.
do
	clear()
	local a, b = villager(0, 0), villager(2, 1)
	a._villages_well, b._villages_bell = {arrived = true}, {arrived = true}
	time = 12000 / 24000
	day = 4
	assert(run_until_talking({a, b}), "arrived villagers about the bell talk in the bell stage")
	time, day = 6000 / 24000, 1
end

-- Another system takes a member: it leaves at once, and a pair ends.
local function taken(label, change, expect_leave_all)
	clear()
	local a, b = villager(0, 0), villager(2, 0)
	assert(run_until_talking({a, b}))
	tick(a); tick(b)
	change(a)
	tick(a)
	assert(not a._villages_talk and a.order == nil, label .. ": the member leaves and its order is cleared")
	tick(b)
	assert(not b._villages_talk and b.order == nil, label .. ": the partner is left alone, so it ends")
end
taken("route", function(v) v._villages_goto_route = {status = "planning"} end)
taken("walk", function(v) v.state = "gowp" end)
taken("trade", function(v) v._trading_players = {p = true} end)
taken("seat", function(v) v._villages_seat = {} end)
taken("sleep", function(v) v._villages_sleeping, v.state = true, "stand" end)
taken("stage over", function() time = 9000 / 24000 end)
time = 6000 / 24000

-- A member of a trio taken: the other two go on.
do
	clear()
	local group = {villager(0, 0), villager(2, 0), villager(1, 2)}
	repeat
		for _, v in ipairs(group) do v._villages_talk, v._villages_talk_next = nil, nil end
		now = now + 1000
		run_until_talking(group)
	until talking(group) == 3
	for _, v in ipairs(group) do tick(v) end
	group[1]._villages_tendency = nil
	group[1].state = "gowp"
	tick(group[1])
	for _, v in ipairs(group) do tick(v) end
	assert(not group[1]._villages_talk and group[2]._villages_talk and group[3]._villages_talk, "two carry on")
	-- A pushed member leaves; so does one an inner wrapper took.
	group[2].pos.x = 40
	tick(group[2])
	assert(not group[2]._villages_talk, "a member pushed away leaves")
end

-- A wrapper that takes the tick (returns false) also ends it.
do
	clear()
	local inner = {on_activate = function() end, on_die = function() end, get_staticdata = function() return {} end}
	local takes = false
	inner.do_custom = function() if takes then return false end end
	conversation.install(inner)
	local a, b = villager(0, 0), villager(2, 0)
	assert(run_until_talking({a, b}))
	takes = true
	inner.do_custom(a, 0.1)
	assert(not a._villages_talk, "a tick another wrapper took ends it")
end

-- Death and the setting.
do
	clear()
	local a, b = villager(0, 0), villager(2, 0)
	assert(run_until_talking({a, b}))
	def.on_die(a, nil, nil)
	assert(not a._villages_talk and a.order == nil, "a death leaves cleanly")
	tick(b)
	assert(not b._villages_talk, "the partner of the dead ends too")
	setting = false
	now = now + 1000
	local c, d = villager(0, 0), villager(1, 1)
	assert(not run_until_talking({c, d}), "with the setting off nobody talks")
	setting = true
	now = now + 1000
	assert(run_until_talking({c, d}))
	setting = false
	tick(c); tick(d)
	assert(not c._villages_talk and not d._villages_talk and c.order == nil, "turning the setting off ends talks")
	setting = true
end

-- Reactivation: a reloaded villager starts with nothing.
do
	clear()
	local a = villager(0, 0)
	a._villages_talk, a._villages_talk_next = {}, 5
	def.on_activate(a, "", 0)
	assert(a._villages_talk == nil and a._villages_talk_next == nil, "nothing carries over a reload")
end

print("conversation tests passed")
