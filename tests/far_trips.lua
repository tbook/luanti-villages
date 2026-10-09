-- Run with: lua tests/far_trips.lua
-- #216: vanilla's do_activity sends a villager more than 50 nodes from its bed
-- home before it looks at the schedule. far_trips.call hides the bed from that
-- test while the villager has an errand elsewhere.
local ticks = 9600 -- work stage
local weather = "none"
local holiday = false
local claims = {}

local function key(pos) return ("%d,%d,%d"):format(pos.x, pos.y, pos.z) end

local nodes = {}
minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return ticks / 24000 end,
	get_day_count = function() return 1 end,
	get_node_or_nil = function(pos) return nodes[key(pos)] end,
	get_item_group = function() return 0 end,
	get_meta = function(pos)
		return {get_string = function() return claims[key(pos)] or "" end}
	end,
}
mcl_weather = {get_weather = function() return weather end}
mcl_moon = {get_moon_phase = function()
	if not holiday then return 1 end
	return minetest.get_timeofday() <= 0.5 and 3 or 0 -- mcl_moon turns the phase at midday
end}
vector = {
	distance = function(a, b)
		return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
	end,
}

local far = dofile("far_trips.lua")

local bed = {x = 0, y = 0, z = 0}
local jobsite = {x = 60, y = 0, z = 0}
nodes[key(jobsite)] = {name = "mcl_cartography_table:cartography_table"}
claims[key(jobsite)] = "v1"

local function villager(x, extra)
	local self = {
		_id = "v1", _bed = bed, _jobsite = jobsite,
		object = {get_pos = function() return {x = x, y = 0, z = 0} end},
	}
	for k, v in pairs(extra or {}) do self[k] = v end
	return self
end

-- vanilla's do_activity (mobs_mc/villager.lua), in its order: the bed test
-- first, then what get_activity says. jobsite_valid is the claim on _jobsite.
local common = dofile("common.lua")
local function do_activity(self)
	local jobsite_valid = self._jobsite and minetest.get_meta(self._jobsite):get_string("villager") == self._id
	if self._bed and vector.distance(self.object:get_pos(), self._bed) > 50 then
		return "go_home"
	end
	local activity = common.get_activity()
	if activity == "sleep" then return "go_home_sleep" end
	if activity == "work" and jobsite_valid then return "work" end
	if activity == "gathering" then return "bell" end
	return "none"
end

local function run(self) return far.call(self, do_activity, self) end

local function check(name, got, want)
	if got ~= want then
		error(("%s: got %s, wanted %s"):format(name, tostring(got), tostring(want)), 0)
	end
end

-- Work stage, 60 nodes from the bed, jobsite claimed: vanilla goes on to the stage.
local v = villager(60)
check("far worker works", run(v), "work")
check("bed is back", v._bed, bed)

-- Within 50 nodes nothing changes.
check("near worker", run(villager(30)), "work")

-- No claimed jobsite: vanilla's walk home stays.
check("no jobsite", run(villager(60, {_jobsite = false})), "go_home")
claims[key(jobsite)] = "someone else"
check("jobsite lost", run(villager(60)), "go_home")
claims[key(jobsite)] = "v1"

-- A child has no errand.
check("child", run(villager(60, {child = true})), "go_home")

-- Putter stage and the free morning: vanilla's rule stands.
ticks = 6800
check("putter", run(villager(60)), "go_home")
ticks = 9600

-- Home and sleep stages, and a thunderstorm, send everyone home as ever.
ticks = 18000
check("home stage", run(villager(60)), "go_home")
ticks = 20000
check("sleep stage", run(villager(60)), "go_home")
ticks = 9600
weather = "thunder"
check("thunder", run(villager(60)), "go_home")
weather = "none"

-- Evening at the tavern: only with a target.
ticks = 16000
check("tavern, no target", run(villager(60)), "go_home")
check("tavern target", run(villager(60, {_villages_tavern_target = {x = 55, y = 0, z = 0}})), "none")

-- Holiday church and bell: an errand only once the villager has found a pulpit
-- or bell (church.lua and bell.lua record it); with none in reach it is a lost
-- villager and goes home.
holiday = true
ticks = 8000
check("church, no pulpit", run(villager(60)), "go_home")
check("church", run(villager(60, {_villages_church = {role = "member"}})), "none")
ticks = 11000
check("bell, no bell", run(villager(60)), "go_home")
check("bell", run(villager(60, {_villages_bell = {}})), "none")
check("bell stage ignores a church target", run(villager(60, {_villages_church = {}})), "go_home")
holiday = false
ticks = 9600

-- A keeper staffing the tavern: its jukebox is the claimed jobsite.
local juke = {x = 70, y = 0, z = 0}
nodes[key(juke)] = {name = "mcl_jukebox:jukebox"}
claims[key(juke)] = "v1"
ticks = 15000
local function keeper(extra)
	local t = {_villages_keeper = true, _jobsite = juke}
	for k, v in pairs(extra or {}) do t[k] = v end
	return villager(60, t)
end
check("keeper staffs", run(keeper()), "work")
check("keeper without claim", run(keeper({_id = "v2"})), "go_home")
check("keeper not marked", run(keeper({_villages_keeper = false})), "go_home")
ticks = 9600

-- An error in vanilla still gives the bed back.
local broken = villager(60)
local ok = pcall(far.call, broken, function() error("boom") end)
check("error propagates", ok, false)
check("bed back after error", broken._bed, bed)

-- A bed vanilla set during the call is kept.
local rebedded = villager(60)
local other = {x = 5, y = 0, z = 0}
far.call(rebedded, function(self) self._bed = other end, rebedded)
check("new bed kept", rebedded._bed, other)

-- init.lua runs vanilla's do_custom through it (its wrappers need the whole
-- engine, so this only checks the wiring).
local init = io.open("init.lua"):read("*a")
check("wired into init.lua", init:find("far_trips.call(self, common.as_villager", 1, true) ~= nil, true)

print("far_trips: ok")
