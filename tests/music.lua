-- Run with: lua tests/music.lua
local time = 15600 / 24000
local now, day, holiday = 0, 4, true
local disc, played, stopped = nil, {}, {}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	registered_aliases = {["mcl_jukebox:record_1"] = "mcl_jukebox:record_13"},
	get_meta = function()
		return {get_inventory = function()
			return {get_stack = function()
				return {
					is_empty = function() return disc == nil end,
					get_name = function() return disc end,
				}
			end}
		end}
	end,
	sound_play = function(name, spec)
		table.insert(played, {name = name, spec = spec})
		return #played
	end,
	sound_stop = function(handle) table.insert(stopped, handle) end,
}
mcl_jukebox = {registered_records = {
	["mcl_jukebox:record_13"] = {"Evil", "Sound", "13", "img", "mcl_jukebox_track_1"},
	["mcl_jukebox:record_far"] = {"Far", "Jordach", "far", "img", "mcl_jukebox_track_4"},
}}
-- common.lua is only asked whether it is a holiday.
local real_dofile = dofile
dofile = function(path)
	if path:find("common.lua", 1, true) then return {is_holiday = function() return holiday end} end
	return real_dofile(path)
end
local music = real_dofile("music.lua")
dofile = real_dofile

local function check(condition, message)
	if not condition then error("FAIL: " .. message, 2) end
end
local jukebox = {x = 1, y = 2, z = 3}
local keeper = {}
local function tick()
	now = now + 3
	music.tick(keeper, jukebox)
end

tick()
check(#played == 0 and not music.is_playing(jukebox), "no disc, no music")

disc = "mcl_jukebox:record_1"
tick()
check(#played == 1 and played[1].name == "mcl_jukebox_track_1", "aliased disc plays its sound")
check(played[1].spec.pos == jukebox and not played[1].spec.to_player, "played at the jukebox for everyone")
tick(); tick()
check(#played == 1, "plays once")

time = 17600 / 24000
tick()
check(#stopped == 1 and stopped[1] == 1 and not music.is_playing(jukebox), "stops at close")
time = 15600 / 24000
tick()
check(#played == 1, "not restarted the same day")

day = 5
disc = "mcl_jukebox:record_far"
tick()
check(#played == 2 and music.is_playing(jukebox), "plays again the next holiday")
disc = nil
tick()
check(#stopped == 2 and not music.is_playing(jukebox), "stops when a player takes the disc")

day = 6
disc = "mcl_jukebox:record_far"
holiday = false
tick()
check(#played == 2, "silent on an ordinary day")
holiday = true
time = 15000 / 24000
tick()
check(#played == 2, "silent before dinner")

-- A disc a player started leaves nothing of ours to stop at close.
time = 17600 / 24000
tick()
check(#stopped == 2, "nothing to stop that it did not start")
print("music tests passed")
