-- Run with: lua tests/bell_hangout.lua   (from the repository root)
-- Morning at the bell (#329): the well's visit at the village bell in the Putter stage.
-- Who goes and when, the bells in reach, the spots about the bell, the cap, the stay,
-- the walk, a bell taken down, and the morning shared with the well.
local PUTTER, WORK = 6000 / 24000, 7200 / 24000
local time = PUTTER
local now, day = 1000, 5
local nodes = {}
local weather = "clear"
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end
local function parse(k)
	local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end

vector = {
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	round = function(a) return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_item_group = function() return 0 end,
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["mcl_bells:bell"] = {walkable = false},
	},
	log = function() end,
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
	find_nodes_in_area = function(minp, maxp, names)
		local found = {}
		for k, name in pairs(nodes) do
			local p = parse(k)
			if name == names[1] and p.x >= minp.x and p.x <= maxp.x and p.y >= minp.y and p.y <= maxp.y
				and p.z >= minp.z and p.z <= maxp.z then
				table.insert(found, p)
			end
		end
		table.sort(found, function(a, b) return key(a) < key(b) end)
		return found
	end,
}
mcl_weather = {get_weather = function() return weather end}

local function reset()
	nodes = {}
	for x = -60, 60 do
		for z = -60, 60 do nodes[key({x = x, y = -1, z = z})] = "mcl_core:stone" end
	end
end

local bell = dofile("bell.lua")
local hangout = dofile("bell_hangout.lua")
local common = dofile("common.lua")
local gopaths, answer = {}, true
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
hangout.install(def, bell)

local ids = 0
local function villager(x, z, extra)
	ids = ids + 1
	local pos = {x = x, y = -0.49, z = z}
	local self = {
		_id = "v" .. ids, state = "stand", _bed = {x = x, y = 0, z = z},
		_villages_bell_hangout_day = day, _villages_bell_hangout_going = true,
	}
	self.object = {
		get_pos = function() return pos end,
		set_velocity = function() end,
	}
	self.ready_to_path = function() return true end
	self.gopath = function(s, target)
		table.insert(gopaths, {self = s, target = target})
		if answer then s.state = "gowp" end
		return answer
	end
	self.pos = pos
	for k, v in pairs(extra or {}) do self[k] = v end
	return self
end

local function tick(self, times)
	for _ = 1, times or 1 do def.do_custom(self, 0.1) end
end

local function flat(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

-- A fresh morning: the bell at (10,5,0), its floor at (10,0,0), in the Putter stage.
local BELL_AT = {x = 10, y = 5, z = 0}
local function setup()
	reset()
	gopaths, answer = {}, true
	nodes[key(BELL_AT)] = "mcl_bells:bell"
	time = PUTTER
	weather = "clear"
	minetest.settings = nil
	now = now + 1000
end

setup()
local center = bell.center_of(BELL_AT)
assert(center.x == 10 and center.y == 0 and center.z == 0, "the bell's floor is the gathering point")

-- Bells within 42 nodes of the bed are found, the nearest first; a farther one is not.
do
	local found = hangout.nearest_bell({_id = "x"}, {x = -20, y = 0, z = 0})
	assert(found and found.x == 10, "a bell 30 nodes from the bed is found")
	assert(hangout.nearest_bell({_id = "x"}, {x = -32, y = 0, z = 0}) == nil,
		"a bell 42 or more nodes from the bed is not found")
	nodes[key({x = -20, y = 5, z = 0})] = "mcl_bells:bell"
	assert(hangout.nearest_bell({_id = "x"}, {x = 0, y = 0, z = 0}).x == 10, "the nearest bell is chosen")
	nodes[key({x = -20, y = 5, z = 0})] = nil
end
assert(hangout.SEARCH_RADIUS == 42, "the bell is looked for within 42 nodes")

-- Skipped without a bell in range: the villager putters, and no walk is started.
setup()
nodes[key(BELL_AT)] = nil
local lone = villager(-8, 0)
tick(lone, 5)
assert(#gopaths == 0 and lone._villages_wander_anchor == nil and lone._villages_bell_hangout == nil,
	"no bell in reach leaves the villager to putter")
setup()
local far = villager(-40, 0)
tick(far, 3)
assert(#gopaths == 0 and far._villages_bell_hangout == nil, "a bell beyond reach is not walked to")

-- A villager walks to a spot of its own about the bell, and villagers take different spots.
setup()
math.randomseed(3)
local spots_taken = {}
for i = 1, 3 do
	local v = villager(-5, i)
	tick(v)
	local goal = gopaths[#gopaths]
	assert(goal and goal.self == v, "a villager sets off for the bell")
	local dist = flat(goal.target, center)
	assert(dist >= 1.5 - 1e-9 and dist <= hangout.SEARCH_RADIUS, "its spot is about the bell")
	for _, other in ipairs(spots_taken) do
		assert(flat(other, goal.target) >= 1.5 - 1e-9, "villagers do not share a spot")
	end
	table.insert(spots_taken, goal.target)
	assert(v._villages_wander_anchor == nil, "no anchor until it arrives")
end

-- The cap: three at the bell at once, the rest putter.
setup()
local crowd = {}
for i = 1, 6 do
	crowd[i] = villager(-5, i)
	tick(crowd[i])
end
assert(#gopaths == hangout.CAP, "no more than the cap go to one bell (" .. #gopaths .. ")")
assert(crowd[4]._villages_bell_hangout == nil, "the fourth finds it full and does not go")

-- Arrival: the wander legs are kept about the bell, and the visit is not saved.
setup()
local arriver = villager(-8, 0)
tick(arriver)
local target = gopaths[#gopaths].target
arriver.pos.x, arriver.pos.z = target.x, target.z
arriver.state = "stand"
tick(arriver)
local anchor = arriver._villages_wander_anchor
assert(anchor and anchor.radius == bell.GATHER_RADIUS and flat(anchor.pos, center) == 0,
	"arrival anchors its wander on the bell")
assert(anchor.max_y == nil, "the bell's anchor has no rim to keep off")
assert(def.get_staticdata(arriver)._villages_wander_anchor == nil, "the visit is not saved")
assert(def.get_staticdata(arriver)._villages_bell_hangout == nil, "the visit is not saved with the villager")

-- It stays STAY_MIN to STAY_MAX, then goes and does not come back this morning.
now = now + hangout.STAY_MIN - 5
tick(arriver)
assert(arriver._villages_bell_hangout, "it is still there part way through its stay")
now = now + hangout.STAY_MAX
tick(arriver)
assert(arriver._villages_bell_hangout == nil and arriver._villages_wander_anchor == nil
	and arriver._villages_bell_hangout_going == false, "it leaves at the end of its stay")
local before = #gopaths
now = now + 20
tick(arriver, 3)
assert(#gopaths == before and arriver._villages_bell_hangout == nil, "it does not come back the same morning")

-- Pushed out of the radius, it walks back, and walking back does not extend the stay.
setup()
local pushed = villager(-8, 0)
tick(pushed)
target = gopaths[#gopaths].target
pushed.pos.x, pushed.pos.z = target.x, target.z
pushed.state = "stand"
tick(pushed)
local due = pushed._villages_bell_hangout.leave_at
pushed.pos.x = center.x + bell.GATHER_RADIUS + 5
local walks = #gopaths
tick(pushed)
assert(#gopaths == walks + 1 and pushed._villages_wander_anchor == nil, "a straying villager walks back")
pushed.pos.x, pushed.pos.z = gopaths[#gopaths].target.x, gopaths[#gopaths].target.z
pushed.state = "stand"
now = now + 1
tick(pushed)
assert(pushed._villages_bell_hangout.leave_at == due, "walking back does not extend the stay")
pushed.pos.x = center.x + bell.GATHER_RADIUS + 5
now = due + 1
tick(pushed)
assert(pushed._villages_bell_hangout == nil, "a villager out of reach whose stay is over just leaves")

-- The stage ends: everyone lets go.
setup()
local leaver = villager(-8, 0)
tick(leaver)
leaver.pos.x, leaver.pos.z = gopaths[#gopaths].target.x, gopaths[#gopaths].target.z
leaver.state = "stand"
tick(leaver)
assert(leaver._villages_wander_anchor, "control: it is about the bell")
time = WORK
tick(leaver)
assert(leaver._villages_bell_hangout == nil and leaver._villages_wander_anchor == nil, "work time releases the villager")
time = PUTTER

-- Not at night, not at work time, not in a thunderstorm, not with the setting off.
local function goes(v)
	local n = #gopaths
	tick(v)
	return #gopaths > n
end
setup()
assert(goes(villager(-8, 0)), "control: it goes in the Putter stage")
setup()
time = 2000 / 24000
assert(not goes(villager(-8, 0)), "not at night")
time = WORK
assert(not goes(villager(-8, 0)), "not at work time")
time = PUTTER
weather = "thunder"
assert(not goes(villager(-8, 0)), "not in a thunderstorm")
weather = "clear"
minetest.settings = {get_bool = function() return false end}
assert(not goes(villager(-8, 0)), "not with the setting off")
minetest.settings = nil

-- Exclusions.
setup()
for name, extra in pairs({
	child = {child = true},
	keeper = {_villages_keeper = true},
	following = {following = {}},
	asleep = {_villages_sleeping = true},
	church = {_villages_church = {}},
	bell_gathering = {_villages_bell = {}},
	well = {_villages_well = {}},
	seat = {_villages_seat = {}},
	fishing = {_villages_fish_session = {}},
	walking = {state = "gowp"},
	unnamed = {_id = false},
}) do
	assert(not goes(villager(-8, 0, extra)), name .. " does not go to the bell")
end

-- A trade stops it, and the time does not count against its walk.
setup()
local trader = villager(-8, 0)
assert(goes(trader))
local since = trader._villages_bell_hangout.since
trader._trading_players = {x = true}
tick(trader, 5)
assert(math.abs(trader._villages_bell_hangout.since - since - 0.5) < 1e-9, "trading time is not counted against the walk")

-- Whether it goes is a chance, once a day: about 40%.
setup()
local going, total = 0, 400
math.randomseed(11)
for _ = 1, total do
	local v = villager(-8, 0, {_villages_bell_hangout_going = false})
	v._villages_bell_hangout_day = nil
	tick(v)
	if v._villages_bell_hangout_going then going = going + 1 end
end
assert(going > total * 0.3 and going < total * 0.5, "some, not all, villagers roll to go (" .. going .. "/" .. total .. ")")
local roller = villager(-8, 0)
roller._villages_bell_hangout_day = nil
roller._villages_bell_hangout_going = nil
tick(roller)
local rolled = roller._villages_bell_hangout_going
tick(roller, 10)
assert(roller._villages_bell_hangout_going == rolled, "the roll stands for the day")
assert(hangout.PROBABILITY == 0.4, "the share going on a morning is 40%")

-- One of the two mornings: a villager who went to the well today does not go to the bell,
-- and one who went to the bell does not go to the well (well.lua reads the same claim).
setup()
local well_first = villager(-8, 0, {_villages_morning = {day = day, place = "well"}})
assert(not goes(well_first), "a villager who went to the well this morning does not go to the bell")
local bell_first = villager(-5, 1)
assert(goes(bell_first), "control: it goes to the bell")
assert(common.morning_claimed_by_other(bell_first, "well"), "the bell visit claims the morning for the bell")
assert(not common.morning_claimed_by_other(bell_first, "bell"), "and not for anywhere else")
assert(not common.morning_claimed_by_other({}, "well"), "a villager with no visit has nothing claimed")
-- The claim is for the day: the next morning it may go.
day = day + 1
local next_morning = villager(-5, 2, {_villages_morning = {day = day - 1, place = "well"}, _villages_bell_hangout_day = day})
assert(goes(next_morning), "a claim from another day does not stop the bell")
day = day - 1

-- A reload does not roll again, and keeps the claim.
setup()
local reloaded = villager(-8, 0, {_villages_bell_hangout_going = false})
tick(reloaded)
local saved = def.get_staticdata(reloaded)
assert(saved._villages_bell_hangout_day == day and saved._villages_bell_hangout_going == false, "the day's roll is saved")
def.on_activate(reloaded, "", 0)
assert(reloaded._villages_bell_hangout_day == day and reloaded._villages_bell_hangout_going == false, "a reload keeps the roll")
local n = #gopaths
tick(reloaded, 5)
assert(#gopaths == n, "a villager done for the day does not go again after a reload")
local claimed = villager(-5, 3, {_villages_morning = {day = day, place = "bell"}})
local goes_back = goes(claimed)
assert(goes_back, "the claim of this morning is the bell's, and it may keep to it")
assert(def.get_staticdata(claimed)._villages_morning.place == "bell", "the claim is saved with the villager")

-- Unreachable: a route that fails gives the bell up, passed over for a long while.
setup()
answer = false
local stuck = villager(-8, 0)
tick(stuck, 3)
assert(stuck._villages_bell_hangout == nil and stuck._villages_wander_anchor == nil, "no route gives the bell up")
assert(next(stuck._villages_bell_hangout_skipped), "the bell is remembered as passed over")
local tries = #gopaths
now = now + 20
tick(stuck, 3)
assert(#gopaths == tries, "a bell passed over is not tried again at once")
now = now + 700
answer = true
tick(stuck)
assert(#gopaths == tries + 1, "it tries again after a long while")

-- A walk that takes too long is given up.
setup()
local slow = villager(-8, 0)
tick(slow)
assert(slow._villages_bell_hangout)
slow.state = "gowp"
now = now + 400
tick(slow)
assert(slow._villages_bell_hangout == nil and next(slow._villages_bell_hangout_skipped), "a walk that takes too long is given up")

-- The bell taken down while it is attended: the visit is dropped, and another bell is found.
setup()
local witness = villager(-8, 0)
tick(witness)
witness.pos.x, witness.pos.z = gopaths[#gopaths].target.x, gopaths[#gopaths].target.z
witness.state = "stand"
tick(witness)
assert(witness._villages_wander_anchor)
nodes[key(BELL_AT)] = nil
nodes[key({x = -10, y = 5, z = 0})] = "mcl_bells:bell"
tick(witness)
assert(witness._villages_bell_hangout and witness._villages_bell_hangout.pos.x == -10
	and witness._villages_wander_anchor == nil, "a removed bell is replaced by another")
nodes[key({x = -10, y = 5, z = 0})] = nil
setup()
local lost = villager(-8, 0)
tick(lost)
nodes[key(BELL_AT)] = nil
tick(lost)
assert(lost._villages_bell_hangout == nil and lost._villages_wander_anchor == nil, "a bell gone is dropped")

-- Death frees the place.
setup()
local mortal = villager(-8, 0)
tick(mortal)
assert(mortal._villages_bell_hangout)
def.on_die(mortal)
assert(mortal._villages_bell_hangout == nil, "dying leaves the bell")
for _, list in pairs(hangout.holds) do assert(next(list) == nil or list[mortal._id] == nil, "and frees its place") end

-- A route still being planned when the visit ends is dropped; another's is not.
setup()
local planner = villager(-8, 0)
planner.gopath = function(s, target)
	s.state = "stand"
	s._villages_goto_route = {status = "planning", goal = {x = target.x, y = target.y, z = target.z}}
	return true
end
tick(planner)
assert(planner._villages_goto_route and planner._villages_goto_route.status == "planning", "control: a route is being planned")
time = WORK
tick(planner)
assert(planner._villages_goto_route == nil and planner._villages_bell_hangout == nil,
	"a route in planning is dropped when the visit ends")

print("bell hangout tests passed")
