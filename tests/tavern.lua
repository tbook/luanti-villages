-- Run with: lua tests/tavern.lua
table.copy = table.copy or function(value)
	local result = {}
	for k, v in pairs(value) do result[k] = v end
	return result
end
local time = 15600 / 24000
local now, day = 0, 3
local nodes, metas = {}, {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end
local function parse(k)
	local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end

vector = {
	equals = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	add = function(a, n) return {x = a.x + n, y = a.y + n, z = a.z + n} end,
	subtract = function(a, n) return {x = a.x - n, y = a.y - n, z = a.z - n} end,
	round = function(a) return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_item_group = function(name, group)
		return (name == "chair" and group == "chair" or name == "table" and group == "table") and 1 or 0
	end,
	facedir_to_dir = function() return {x = 0, y = 0, z = 1} end,
	registered_nodes = {
		["mcl_jukebox:jukebox"] = {}, air = {walkable = false}, floor = {walkable = true},
		chair = {walkable = false}, table = {walkable = true},
	},
	serialize = function(value) return value end,
	deserialize = function(value) return value end,
	log = function() end,
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or (pos.y == -1 and "floor" or "air"), param2 = 0} end,
	get_meta = function(pos)
		local k = key(pos)
		metas[k] = metas[k] or {}
		return {
			get_string = function(_, field) return metas[k][field] or "" end,
			set_string = function(_, field, value) metas[k][field] = value end,
		}
	end,
	find_node_near = function() end,
	find_nodes_in_area = function(minp, maxp, names)
		local found = {}
		for k, name in pairs(nodes) do
			local p = parse(k)
			if (name == names[1] or "group:" .. name == names[1]) and p.x >= minp.x and p.x <= maxp.x and p.z >= minp.z and p.z <= maxp.z then
				table.insert(found, p)
			end
		end
		return found
	end,
}

local jukebox = {x = 20, y = 0, z = 0}
local far = {x = 200, y = 0, z = 0}
local smoker = {x = -5, y = 0, z = 0}
nodes[key(jukebox)] = "mcl_jukebox:jukebox"
nodes[key(far)] = "mcl_jukebox:jukebox"

local gopaths = {}
local def = {
	on_activate = function() end,
	do_custom = function() end,
	get_staticdata = function() return "" end,
	set_animation = function() end,
	gopath = function(self, target, callback)
		table.insert(gopaths, {self = self, target = target, callback = callback})
		self.state = "gowp"
		return true
	end,
}
-- One seat.lua, so the test and tavern.lua share its reservations.
local real_dofile, loaded = dofile, {}
dofile = function(path)
	loaded[path] = loaded[path] or real_dofile(path)
	return loaded[path]
end
dofile("tavern.lua")(def)

local function villager(id, pos, extra)
	local self = {_id = id, _profession = "farmer", state = "stand", _bed = {x = 0, y = 0, z = 0}}
	for k, v in pairs(extra or {}) do self[k] = v end
	self.object = {
		get_pos = function() return pos end,
		set_pos = function(_, p) pos = p end,
		set_velocity = function() end,
	}
	return setmetatable(self, {__index = def})
end

-- At 15:30 a villager heads for its own village's tavern, not a farther one.
local alice = villager("alice", {x = 2, y = 0, z = 0}, {_jobsite = smoker})
metas[key(smoker)] = {villager = "alice"}
def.do_custom(alice, 0.1)
assert(#gopaths == 1 and vector.equals(gopaths[1].target, jukebox))
assert(vector.equals(alice._villages_tavern_target, jukebox))

-- Arriving at a tavern with no keeper, an untraded worker takes it over,
-- leaving its old jobsite free.
alice.state = "stand"
alice.object:set_pos({x = 19, y = 0, z = 0})
gopaths[1].callback(alice)
assert(alice._villages_keeper and alice._profession == "butcher", "first arrival keeps the tavern")
assert(vector.equals(alice._jobsite, jukebox) and metas[key(jukebox)].villager == "alice")
assert(metas[key(smoker)].villager == "", "the old jobsite is released")
-- A keeper keeps its own hours from here: no longer a guest.
def.do_custom(alice, 0.1)
assert(alice._villages_tavern_target == nil)

-- The next guest finds the tavern kept, stays as a guest, and holds still.
local bob = villager("bob", {x = 18, y = 0, z = 1})
def.do_custom(bob, 0.1)
assert(bob._villages_tavern_arrived and not bob._villages_keeper and bob.order == "stand")
assert(bob._profession == "farmer")

-- A traded villager never takes over, even at an empty tavern.
local empty = {x = 40, y = 0, z = 0}
nodes[key(empty)] = "mcl_jukebox:jukebox"
local carol = villager("carol", {x = 39, y = 0, z = 0}, {
	_bed = {x = 40, y = 0, z = 2}, _trades = {{traded_once = true}},
})
def.do_custom(carol, 0.1)
assert(carol._villages_tavern_arrived and not carol._villages_keeper and carol._profession == "farmer")
assert((metas[key(empty)] or {}).villager == nil)

-- Unloaded and reloaded on the way (a player walked out of range): the
-- villager resumes the same trip instead of idling until Home.
local frank = villager("frank", {x = 60, y = 0, z = 0}, {_bed = {x = 25, y = 0, z = 0}})
def.do_custom(frank, 0.1)
assert(vector.equals(frank._villages_tavern_target, jukebox))
frank._villages_tavern_route = {status = "travelling"}
def.on_activate(frank, "", 0)
frank.state = "stand"
local before = #gopaths
def.do_custom(frank, 0.1)
assert(#gopaths == before + 1 and vector.equals(gopaths[#gopaths].target, jukebox), "resumes after reload")
-- Reloaded while inside: back in place and holding, not stranded.
def.on_activate(bob, "", 0)
assert(bob.order == nil and not bob._villages_tavern_arrived)
def.do_custom(bob, 0.1)
assert(bob._villages_tavern_arrived and bob.order == "stand", "a reloaded guest settles back in")

-- Pushed back out of the tavern: the guest walks back in.
bob.object:set_pos({x = 10, y = 0, z = 0})
before = #gopaths
def.do_custom(bob, 0.1)
assert(not bob._villages_tavern_arrived and #gopaths == before + 1, "walks back in")
bob.state = "stand"
bob.object:set_pos({x = 18, y = 0, z = 1})
def.do_custom(bob, 0.1)
assert(bob._villages_tavern_arrived)

-- A fisherman taking over sheds its old job entirely, or fisherman.lua would
-- send the keeper fishing during Staff (work time).
local third = {x = -30, y = 0, z = 0}
nodes[key(third)] = "mcl_jukebox:jukebox"
local gina = villager("gina", {x = -29, y = 0, z = 0}, {
	_bed = {x = -30, y = 0, z = 3}, _profession = "fisherman", _villages_fisherman = true,
	_villages_fish_target = {x = -40, y = 0, z = 0}, _villages_fish_route = {status = "arrived"},
})
def.do_custom(gina, 0.1)
assert(gina._villages_keeper and gina._profession == "butcher")
assert(gina._villages_fisherman == nil and gina._villages_fish_target == nil and gina._villages_fish_route == nil)

-- Leave-by 17:00: a villager still on the way goes home instead.
local dave = villager("dave", {x = 100, y = 0, z = 0}, {_bed = {x = 30, y = 0, z = 0}})
def.do_custom(dave, 0.1)
assert(dave._villages_tavern_target and dave.state == "gowp")
dave._villages_tavern_route = {status = "travelling"}
dave._villages_follow = {final = jukebox}
time = 17100 / 24000
def.do_custom(dave, 0.1)
assert(dave._villages_tavern_target == nil and dave.state == "stand", "abandons the trip")
assert(dave._villages_follow == nil, "and the follower's flag with it (#230)")
local common = dofile("common.lua")
assert(common.schedule_stage(nil, dave) == "home" and common.is_home_time(dave), "and heads home")
assert(common.get_activity() == "tavern" and common.as_villager(dave, common.get_activity) == "sleep",
	"vanilla's go_home takes it to bed")
assert(common.schedule_stage(nil, bob) == "tavern", "others stay at dinner")
def.do_custom(dave, 0.1)
assert(dave._villages_tavern_target == nil, "and does not start another today")
day = day + 1
assert(common.schedule_stage(nil, dave) == "tavern", "only for that day")
day = day - 1
-- Guests already inside stay until Home.
def.do_custom(bob, 0.1)
assert(bob._villages_tavern_arrived and bob.order == "stand")

-- Home (17:30) ends the visit and releases the hold.
time = 17600 / 24000
def.do_custom(bob, 0.1)
assert(bob._villages_tavern_target == nil and bob.order == nil)

-- No tavern in reach: nothing to do, decided once for the day.
time, day = 15600 / 24000, 4
local erin = villager("erin", {x = -500, y = 0, z = 0}, {_bed = {x = -500, y = 0, z = 0}})
local count = #gopaths
def.do_custom(erin, 0.1)
assert(#gopaths == count and erin._villages_tavern_target == nil and erin._villages_tavern_day == 4)
assert(common.is_home_time(erin), "no tavern: straight to Home")

-- A guest that has finished its meal gets up and gives the chair back, and
-- does not sit again that day (#115).
time, day = 15600 / 24000, 5
local chair, table_pos = {x = 21, y = 0, z = 2}, {x = 21, y = 0, z = 1}
nodes[key(chair)], nodes[key(table_pos)] = "chair", "table"
local seat = dofile("./seat.lua")
local function diner(id)
	local d = villager(id, {x = 21, y = 0, z = 3}, {_bed = {x = 30, y = 0, z = 0}, _villages_tavern_target = jukebox})
	d.set_animation = function() end
	d.set_yaw = function() end
	d.collisionbox = {-0.3, 0, -0.3, 0.3, 1.8, 0.3}
	d.object.set_bone_override = function() end
	d.object.set_properties = function() end
	d.object.set_acceleration = function() end
	return d
end
local hal, ida = diner("hal"), diner("ida")
mcl_mobs = {mob_class = {set_yaw = function() end}}
assert(seat.reserve(hal, jukebox) and seat.sit(hal), "hal sits")
hal.order = nil
def.do_custom(hal, 0.1)
assert(hal._villages_seated, "still eating or waiting: stays seated")
hal._villages_meal_day = day
def.do_custom(hal, 0.1)
assert(not hal._villages_seated and not hal._villages_seat, "done eating: gets up")
assert(seat.reserve(ida, jukebox), "the chair is free for the next guest")
seat.stand(ida)
def.do_custom(hal, 0.1)
assert(not hal._villages_seat and not hal._villages_seated, "does not take a chair again")

-- Holiday evening (#128): guests head for the tavern from 13:30, not 15:30,
-- and the 17:00 leave-by is unchanged. Day 8 is a holiday; day 7 is not.
time, day = 13400 / 24000, 8
local jo = villager("jo", {x = 2, y = 0, z = 0}, {_bed = {x = 0, y = 0, z = 0}})
count = #gopaths
def.do_custom(jo, 0.1)
assert(#gopaths == count and jo._villages_tavern_target == nil, "not before 13:30")
time = 13600 / 24000
assert(common.schedule_stage(nil, jo) == "tavern")
def.do_custom(jo, 0.1)
assert(#gopaths == count + 1 and vector.equals(jo._villages_tavern_target, jukebox), "holiday guests set out at 13:30")
time = 17100 / 24000
def.do_custom(jo, 0.1)
assert(jo._villages_tavern_target == nil and jo._villages_skip_tavern == 8, "holiday leave-by is still 17:00")
-- The same hour on an ordinary day is still the afternoon.
day = 7
assert(common.schedule_stage(13600 / 24000, villager("kay", {x = 0, y = 0, z = 0})) == "work")

print("tavern.lua: ok")
