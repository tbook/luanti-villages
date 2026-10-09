-- Keeps vanilla's wandered_too_far rule from undoing a trip this mod's
-- schedule sent a villager on (#216).
--
-- VoxeLibre's do_activity (mobs_mc/villager.lua) measures the villager's
-- distance to its claimed bed before it looks at the schedule, and past 50
-- nodes it calls go_home and skips everything else: do_work, the bell. A
-- jobsite, church, bell or tavern more than 50 nodes from a villager's bed
-- therefore sent it back home each time it got there, and from home out
-- again, all day. go_home and do_activity are local to villager.lua, so the
-- only handle on that test is the bed it reads: while the schedule has a
-- villager somewhere other than home, for the length of one vanilla do_custom
-- call, the bed is not there to measure from. Vanilla then takes its ordinary
-- branch for the stage, so do_work still sets the order and unlocks trades.
--
-- Only in daylight (vanilla's night branch re-validates the bed and would take
-- another), only past 50 nodes, and only while the villager has an errand:
-- a claimed jobsite at the work stage, the dinner at the tavern, the service
-- or the bell on a holiday (once they have found a pulpit or bell). Anyone else far from home, a lost putterer or
-- an unemployed villager, still gets vanilla's walk back.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")

-- Vanilla's limit in do_activity.
local RANGE = 50

local JUKEBOX = "mcl_jukebox:jukebox"

-- Vanilla's is_night is tod > 17500 or tod < 6500 (24000 ticks to the day).
local function by_day()
	local ticks = (core.get_timeofday() * 24000) % 24000
	return ticks >= 6500 and ticks <= 17500
end

-- A keeper's jukebox is its claimed jobsite (keeper.lua), though no workstation.
local function has_claimed_jukebox(self)
	local pos = self._jobsite
	local node = pos and core.get_node_or_nil(pos)
	return node ~= nil and node.name == JUKEBOX
		and core.get_meta(pos):get_string("villager") == self._id
end

-- Somewhere the schedule wants the villager, other than its bed, and a real
-- place to be: the villager has a claim or a target there. Church and bell
-- record theirs when the villager finds a pulpit or bell in reach; without
-- one it is an ordinary lost villager and goes home as in vanilla.
local function has_errand(self)
	if self.child or not self._id then return false end
	local stage = common.schedule_stage(nil, self)
	if stage == "work" then return common.has_claimed_jobsite(self) end
	if stage == "staff" then return self._villages_keeper == true and has_claimed_jukebox(self) end
	if stage == "tavern" then return self._villages_tavern_target ~= nil end
	if stage == "bell" then return self._villages_bell ~= nil end
	if stage == "church" or stage == "pulpit" or stage == "service" then
		return self._villages_church ~= nil
	end
	return false
end

-- Whether vanilla's wandered_too_far test should find nothing to measure.
local function holds(self)
	local bed, pos = self._bed, self.object:get_pos()
	if not bed or not pos or vector.distance(pos, bed) <= RANGE then return false end
	return by_day() and has_errand(self)
end

-- Runs fn(...) with the bed out of vanilla's sight when holds(self) says so.
-- fn is vanilla's do_custom (through init.lua's wrappers below this one), and
-- nothing in it may lose the bed for good: the only code there that clears
-- _bed is check_bed/validate_bed (bed gone, resettled), which vanilla reaches
-- by day only through the test this hides, and by night (not hidden). So a
-- nil _bed afterwards means "still hidden", and putting it back is right. A
-- wrapper outside this call that clears the bed on purpose acts after it
-- returns and is not affected; one that ran inside fn would have its clear
-- undone, and a bed set during fn (not nil afterwards) is kept.
local function call(self, fn, ...)
	if not holds(self) then return fn(...) end
	local bed = self._bed
	self._bed = nil
	local ok, result = pcall(fn, ...)
	if self._bed == nil then self._bed = bed end
	if not ok then error(result) end
	return result
end

return {call = call, holds = holds, RANGE = RANGE}
