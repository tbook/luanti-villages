-- The tavern's music (#101): on a holiday the keeper on duty starts the disc
-- a player left in the jukebox when dinner begins, and stops it at close.
--
-- mcl_jukebox exposes no play or stop function: its own playing is private to
-- the player who clicks (to_player, tracked per player name). So this plays
-- the disc's registered sound at the jukebox for everyone nearby, and remembers
-- the handle itself. Nothing is ever put in or taken out of the jukebox.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local JUKEBOX = "mcl_jukebox:jukebox"
-- Dinner begins at 15:30 and the tavern closes at 17:30 (common.lua's Home).
local START = 15500
local STOP = 17500
local HEAR_DISTANCE = 24
-- The keeper checks at this interval, in seconds.
local CHECK_SECONDS = 2

-- By jukebox position: {pos, handle, record}, only for music this module began.
local playing = {}
-- The day each jukebox last had its music started, so a disc that ends is not
-- restarted, and one a player removed is not replaced.
local started_day = {}
-- The day a player last put a disc into each jukebox.
local player_day = {}

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

-- Whether music this module began should keep going: inside the window, the
-- jukebox still there, and still holding the disc that was started. This runs
-- on its own timer, not from the keeper, whose staffing may lapse (a dug
-- jukebox, a death, a storm sending it home) while the sound plays on.
local function check_playing()
	for pos, current in pairs(playing) do
		local node = core.get_node_or_nil(current.pos)
		local _, record
		if node and node.name == JUKEBOX then _, record = disc_sound(current.pos) end
		if not in_window() or not node or node.name ~= JUKEBOX or record ~= current.record then
			stop(current.pos)
		end
	end
end

-- Called each step by a keeper standing at its claimed jukebox: starts the
-- music. Stopping is check_playing's.
local function tick(self, jukebox)
	local pos = key(jukebox)
	local now = core.get_gametime()
	if now < (self._villages_music_check or 0) then return end
	self._villages_music_check = now + CHECK_SECONDS
	if playing[pos] or not in_window() then return end
	local day = core.get_day_count()
	-- A disc a player put in today is playing to that player already.
	if player_day[pos] == day or started_day[pos] == day then return end
	local sound, record = disc_sound(jukebox)
	if not sound then return end
	started_day[pos] = day
	playing[pos] = {
		pos = {x = jukebox.x, y = jukebox.y, z = jukebox.z},
		record = record,
		handle = core.sound_play(sound, {pos = jukebox, gain = 1, max_hear_distance = HEAR_DISTANCE}),
	}
end

-- mcl_jukebox starts a player's disc privately inside on_rightclick, with no
-- hook of its own. Note a click that leaves a disc in an empty jukebox, so the
-- keeper does not start a second copy for everyone.
local function watch_player_inserts()
	local def = core.registered_nodes[JUKEBOX]
	if not (def and def.on_rightclick and core.override_item) then return end
	local original = def.on_rightclick
	core.override_item(JUKEBOX, {on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		local was_empty = not disc_sound(pos)
		local result = original(pos, node, clicker, itemstack, pointed_thing)
		if was_empty and disc_sound(pos) then player_day[key(pos)] = core.get_day_count() end
		return result
	end})
end

if core.register_on_mods_loaded then core.register_on_mods_loaded(watch_player_inserts) end
if core.register_globalstep then
	local elapsed = 0
	core.register_globalstep(function(dtime)
		elapsed = elapsed + dtime
		if elapsed < CHECK_SECONDS then return end
		elapsed = 0
		check_playing()
	end)
end

return {
	tick = tick,
	stop = stop,
	check = check_playing,
	watch_player_inserts = watch_player_inserts,
	is_playing = function(jukebox) return playing[key(jukebox)] ~= nil end,
}
