-- The tavern's music (#101): on a holiday the keeper on duty starts the disc
-- a player left in the jukebox when dinner begins, and stops it at close.
--
-- mcl_jukebox exposes no play or stop function: its own playing is private to
-- the player who clicks (to_player, tracked per player name). So this plays
-- the disc's registered sound at the jukebox for everyone nearby, and remembers
-- the handle itself. Nothing is ever put in or taken out of the jukebox.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
-- Dinner begins at 15:30 and the tavern closes at 17:30 (common.lua's Home).
local START = 15500
local STOP = 17500
local HEAR_DISTANCE = 24
-- The keeper checks at this interval, in seconds.
local CHECK_SECONDS = 2

-- By jukebox position: {handle, record, day}, only for music this module began.
local playing = {}
-- The day each jukebox last had its music started, so a disc that ends is not
-- restarted, and one a player removed is not replaced.
local started_day = {}

local function key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

-- The sound name of the disc in the jukebox, or nil if there is none.
local function disc_sound(pos)
	if not (mcl_jukebox and mcl_jukebox.registered_records) then return end
	local stack = core.get_meta(pos):get_inventory():get_stack("main", 1)
	if not stack or stack:is_empty() then return end
	local name = stack:get_name()
	name = core.registered_aliases and core.registered_aliases[name] or name
	local record = mcl_jukebox.registered_records[name]
	return record and record[5], name
end

local function stop(pos)
	local current = playing[key(pos)]
	if not current then return end
	playing[key(pos)] = nil
	if current.handle then core.sound_stop(current.handle) end
end

local function in_window()
	local ticks = (core.get_timeofday() * 24000) % 24000
	return common.is_holiday() and ticks >= START and ticks < STOP
end

-- Called each step by a keeper standing at its claimed jukebox.
local function tick(self, jukebox)
	local pos = key(jukebox)
	local now = core.get_gametime()
	if now < (self._villages_music_check or 0) then return end
	self._villages_music_check = now + CHECK_SECONDS
	local current = playing[pos]
	if not in_window() then
		stop(jukebox)
		return
	end
	local sound, record = disc_sound(jukebox)
	if current then
		-- A player took the disc out or swapped it: theirs now.
		if record ~= current.record then stop(jukebox) end
		return
	end
	local day = core.get_day_count()
	if not sound or started_day[pos] == day then return end
	started_day[pos] = day
	playing[pos] = {
		record = record,
		handle = core.sound_play(sound, {pos = jukebox, gain = 1, max_hear_distance = HEAR_DISTANCE}),
	}
end

return {
	tick = tick,
	stop = stop,
	is_playing = function(jukebox) return playing[key(jukebox)] ~= nil end,
}
