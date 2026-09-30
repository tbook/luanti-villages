-- Run with: lua tests/schedule.lua
local time = 0
local weather = "clear"
minetest = {
	get_timeofday = function() return time end,
	get_item_group = function() return 0 end,
}
mcl_weather = {get_weather = function() return weather end}
local common = dofile("common.lua")

local function at(ticks) return ticks / 24000 end

-- Each stage boundary from #22, checked on both sides.
for _, case in ipairs({
	{0, "sleep"}, {5499, "sleep"}, {5500, "putter"}, {6999, "putter"},
	{7000, "work"}, {12000, "work"}, {15499, "work"}, {15500, "tavern"},
	{17499, "tavern"}, {17500, "home"}, {18499, "home"}, {18500, "sleep"},
	{23999, "sleep"},
}) do
	local stage = common.schedule_stage(at(case[1]))
	assert(stage == case[2], ("%d: expected %s, got %s"):format(case[1], case[2], stage))
end

-- Vanilla only understands work/sleep/gathering; the rest must be unknown to it.
assert(common.get_activity(at(10000)) == "work")
assert(common.get_activity(at(20000)) == "sleep")
assert(common.get_activity(at(18000)) == "sleep", "home walks the villager to its bed")
assert(common.get_activity(at(16000)) == "tavern")
assert(common.get_activity(at(6000)) == "putter")
time = at(12000)
assert(common.get_activity() == "work", "no argument reads the current time")
assert(common.get_activity() ~= "gathering", "the bell lunch is dropped")

time = at(18000)
assert(common.is_home_time() and not common.is_sleep_time() and not common.is_work_time())
time = at(20000)
assert(common.is_home_time() and common.is_sleep_time())
time = at(10000)
assert(common.is_work_time() and not common.is_home_time())

weather = "thunder"
assert(common.schedule_stage(at(10000)) == "sleep")
assert(common.get_activity(at(10000)) == "sleep")
assert(common.is_sleep_time() and not common.is_work_time())

print("schedule.lua: ok")
