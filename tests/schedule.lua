-- Run with: lua tests/schedule.lua
local time = 0
local weather = "clear"
local day = 1
minetest = {
	get_timeofday = function() return time end,
	get_day_count = function() return day end,
	get_item_group = function() return 0 end,
	get_modpath = function() return "." end,
}
mcl_weather = {get_weather = function() return weather end}
local common = dofile("common.lua")
-- Day 1 is an ordinary day without mcl_moon: 1 % 4 ~= 0.

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

-- Tavern keepers (#15) keep their own hours.
local keeper = {_villages_keeper = true}
for _, case in ipairs({
	{6999, "sleep"}, {7000, "putter"}, {8000, "free"}, {13999, "free"}, {14000, "staff"},
	{18499, "staff"}, {18500, "home"}, {19000, "sleep"}, {2000, "sleep"},
}) do
	local stage = common.schedule_stage(at(case[1]), keeper)
	assert(stage == case[2], ("keeper %d: expected %s, got %s"):format(case[1], case[2], stage))
end
time = at(17000)
assert(common.is_work_time(keeper) and not common.is_work_time(), "keeper staffs while others dine")
time = at(18000)
assert(not common.is_home_time(keeper) and common.is_home_time())
assert(common.get_activity() == "sleep")
assert(common.as_villager(keeper, common.get_activity) == "work", "get_activity answers for the named villager")
assert(common.get_activity() == "sleep", "and forgets it afterwards")
time = at(10000)
assert(common.as_villager(keeper, common.get_activity) == "free")

weather = "thunder"
assert(common.schedule_stage(at(10000)) == "sleep")
assert(common.get_activity(at(10000)) == "sleep")
assert(common.is_sleep_time() and not common.is_work_time())

-- Holidays (#124).
weather = "clear"
local offset = 3
mcl_moon = {get_moon_phase = function() return (day + offset + (time > 0.5 and 1 or 0)) % 8 end}
local function holiday_on(d, ticks)
	day, time = d, at(ticks)
	return common.is_holiday()
end
-- With offset 3 the evening phase is (day + 4) % 8: day 0 is full, day 4 new.
for d = 0, 7 do
	local expected = d % 4 == 0
	for _, ticks in ipairs({0, 1000, 6000, 12000, 12001, 13000, 18000, 23999}) do
		assert(holiday_on(d, ticks) == expected, ("day %d at %d: holiday should be %s"):format(d, ticks, tostring(expected)))
	end
end
-- The phase flips at midday but the holiday does not.
day, time = 0, at(11999)
local morning_phase = mcl_moon.get_moon_phase()
time = at(12001)
assert(mcl_moon.get_moon_phase() ~= morning_phase)
assert(holiday_on(0, 11999) and holiday_on(0, 12001))

-- Without mcl_moon the day count decides.
mcl_moon = nil
for d = 0, 8 do assert(holiday_on(d, 9000) == (d % 4 == 0)) end
mcl_moon = {get_moon_phase = function() return (day + offset + (time > 0.5 and 1 or 0)) % 8 end}

local cleric = {_profession = "cleric"}
local villager = {_profession = "farmer"}
day = 4
for _, case in ipairs({
	{5499, "sleep", "sleep", "sleep"}, {5500, "putter", "pulpit", "sleep"},
	{6999, "putter", "pulpit", "sleep"}, {7000, "church", "service", "putter"},
	{7999, "church", "service", "putter"}, {8000, "church", "service", "free"},
	{10499, "church", "service", "free"}, {10500, "bell", "bell", "free"},
	{12999, "bell", "bell", "free"}, {13000, "bell", "bell", "staff"},
	{13499, "bell", "bell", "staff"}, {13500, "tavern", "tavern", "staff"},
	{17499, "tavern", "tavern", "staff"}, {17500, "home", "home", "staff"},
	{18499, "home", "home", "staff"}, {18500, "sleep", "sleep", "home"},
	{18999, "sleep", "sleep", "home"}, {19000, "sleep", "sleep", "sleep"},
	{23999, "sleep", "sleep", "sleep"},
}) do
	local tod = at(case[1])
	for i, who in ipairs({villager, cleric, keeper}) do
		local stage = common.schedule_stage(tod, who)
		assert(stage == case[i + 1], ("holiday %d role %d: expected %s, got %s"):format(case[1], i, case[i + 1], stage))
	end
end
-- Tavern skip and thunder still apply; vanilla sees only unknown activities.
villager._villages_skip_tavern = 4
assert(common.schedule_stage(at(15000), villager) == "home")
villager._villages_skip_tavern = nil
assert(common.get_activity(at(8000)) == "church")
assert(common.get_activity(at(6000)) == "putter")
assert(common.get_activity(at(20000)) == "sleep")
assert(common.get_activity(at(18000)) == "sleep")
weather = "thunder"
assert(common.schedule_stage(at(8000), villager) == "sleep")
weather = "clear"
-- Next day is ordinary again.
day = 5
assert(common.schedule_stage(at(8000), villager) == "work")
assert(common.schedule_stage(at(14500), keeper) == "staff" and common.schedule_stage(at(13500), keeper) == "free")

print("schedule.lua: ok")
