-- The tavern's music (#101, #187): on a holiday the keeper on duty starts a
-- disc when dinner begins and stops it at close. A disc a player left in the
-- jukebox plays; a jukebox with none (every newly generated tavern's) plays
-- the day's record from mcl_jukebox, chosen by day count. Nothing is ever put
-- in or taken out of the jukebox.
--
-- mcl_jukebox exposes no play or stop function: its own playing is private to
-- the player who clicks (to_player, tracked per player name). So this plays
-- the sound at the jukebox itself. A positional sound reaches only the players
-- in range when it starts, so it is started per player (to_player plus pos)
-- as each comes within hearing distance, and the handles are remembered here.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local JUKEBOX = "mcl_jukebox:jukebox"
-- Dinner begins at 15:30 and the tavern closes at 17:30 (common.lua's Home).
local START = 15500
local STOP = 17500
-- A positional sound is attenuated by the client (OpenAL inverse distance):
-- the `gain` given is the gain at 3 nodes, and it falls as 3 * gain / distance,
-- clamped to 1. Gain 1 was audible only beside the jukebox (playtest of #187).
-- A gain above 1 is honoured and widens the radius of full volume to about
-- 3 * GAIN nodes (12), still falling smoothly beyond it (0.3 at 40 nodes).
local GAIN = 4
-- Who gets the track when it starts (max_hear_distance only filters at start).
local HEAR_DISTANCE = 40
-- A player who walks this much farther out is forgotten, so coming back
-- restarts the track. Past it the sound is already about 0.2.
local FORGET_MARGIN = 16
-- The keeper checks at this interval, in seconds.
local CHECK_SECONDS = 2

-- By jukebox position: {pos, heard = {player name = handle}, record, sound}, only
-- for music this module began.
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

-- The day's record when the jukebox holds none, or nil if there are no records.
-- The rotation shifts when discs are added. A restart forgets the day state
-- below, so a disc a player put in earlier may overlap the keeper's copy.
local warned_records = false
local function default_sound()
	local names = {}
	for name in pairs(mcl_jukebox and mcl_jukebox.registered_records or {}) do names[#names + 1] = name end
	if #names == 0 then
		if not warned_records then
			warned_records = true
			core.log("warning", "[living_villages] mcl_jukebox.registered_records is missing or empty; no tavern music")
		end
		return
	end
	table.sort(names)
	return mcl_jukebox.registered_records[names[core.get_day_count() % #names + 1]][5]
end

local function stop(pos)
	local current = playing[key(pos)]
	if not current then return end
	playing[key(pos)] = nil
	for _, handle in pairs(current.heard) do core.sound_stop(handle) end
end

-- Start the sound for each player now in range who is not hearing it, and
-- forget those who have gone well out of range or left.
local function sync_listeners(current)
	local near = {}
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local distance = vector.distance(player:get_pos(), current.pos)
		if distance <= HEAR_DISTANCE then
			near[name] = true
			if not current.heard[name] then
				current.heard[name] = core.sound_play(current.sound, {
					to_player = name, pos = current.pos, gain = GAIN, max_hear_distance = HEAR_DISTANCE,
				})
			end
		elseif distance <= HEAR_DISTANCE + FORGET_MARGIN then
			near[name] = true
		end
	end
	for name, handle in pairs(current.heard) do
		if not near[name] then
			core.sound_stop(handle)
			current.heard[name] = nil
		end
	end
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
		if not in_window() or (node and (node.name ~= JUKEBOX or record ~= current.record)) then
			stop(current.pos)
		elseif node then
			sync_listeners(current)
		end -- else the block is unloaded: unknown, keep state
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
	sound = sound or (not record and default_sound())
	if not sound then return end
	started_day[pos] = day
	playing[pos] = {
		pos = {x = jukebox.x, y = jukebox.y, z = jukebox.z},
		record = record,
		sound = sound,
		heard = {},
	}
	sync_listeners(playing[pos])
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
