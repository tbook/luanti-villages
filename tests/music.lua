-- Run with: lua tests/music.lua
local time = 15600 / 24000
local now, day, holiday = 0, 4, true
local disc, played, stopped = nil, {}, {}
local players = {}
local logs = {}
local node = "mcl_jukebox:jukebox"

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
	get_node_or_nil = function() return node and {name = node} end,
	registered_nodes = {["mcl_jukebox:jukebox"] = {on_rightclick = function(pos, _, _, itemstack)
		if disc == nil and itemstack then disc = itemstack end
		return itemstack
	end}},
	override_item = function(name, changes)
		for k, v in pairs(changes) do minetest.registered_nodes[name][k] = v end
	end,
	sound_stop = function(handle) table.insert(stopped, handle) end,
	log = function(level, msg) table.insert(logs, msg) end,
	get_connected_players = function()
		local list = {}
		for name, pos in pairs(players) do
			list[#list + 1] = {get_player_name = function() return name end, get_pos = function() return pos end}
		end
		return list
	end,
}
vector = {distance = function(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end}
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
music.watch_player_inserts()
local jukebox = {x = 1, y = 2, z = 3}
local keeper = {}
local function tick()
	now = now + 3
	music.tick(keeper, jukebox)
	music.check()
end
-- The cleanup runs without any keeper present.
local function tick_alone()
	now = now + 3
	music.check()
end

-- No disc: the day's default record starts, but nothing is played with nobody near.
tick()
check(music.is_playing(jukebox) and #played == 0, "empty jukebox starts, nobody near, no sound")
players.far = {x = 100, y = 2, z = 3}
tick()
check(#played == 0, "a distant player hears nothing")
-- A player who walks in later gets the track, once.
players.ann = {x = 5, y = 2, z = 3}
tick(); tick()
check(#played == 1 and played[1].name == "mcl_jukebox_track_1", "default record (day 4 of 2) plays")
check(played[1].spec.to_player == "ann" and played[1].spec.pos.x == 1, "positional, to the one player")
check(played[1].spec.max_hear_distance == 40, "hear distance")
players.bob = {x = 1, y = 2, z = 20}
tick()
check(#played == 2 and played[2].spec.to_player == "bob", "second player gets their own")
-- Going just out of range keeps the handle; going well out stops it and re-entry restarts.
players.ann = {x = 50, y = 2, z = 3}
tick()
check(#stopped == 0 and #played == 2, "margin keeps the handle")
players.ann = {x = 70, y = 2, z = 3}
tick()
check(stopped[1] == 1, "stopped for the player who left")
players.ann = {x = 5, y = 2, z = 3}
tick()
check(#played == 3, "restarted on return")
players.bob = nil
tick()
check(stopped[2] == 2, "forgotten when a player leaves the game")
stopped = {}
-- A disc the keeper replaced by a player's removal/insert ends it.
time = 17600 / 24000
tick_alone()
check(#stopped == 1 and not music.is_playing(jukebox), "stops at close")
time = 15600 / 24000
players = {}
played, stopped = {}, {}

day = 5
players.ann = {x = 5, y = 2, z = 3}
disc = "mcl_jukebox:record_1"
tick()
check(#played == 1 and played[1].name == "mcl_jukebox_track_1", "aliased disc plays its sound")
tick(); tick()
check(#played == 1, "plays once")

time = 17600 / 24000
tick_alone()
check(#stopped == 1 and stopped[1] == 1 and not music.is_playing(jukebox), "stops at close")
time = 15600 / 24000
tick()
check(#played == 1, "not restarted the same day")

day = 15
disc = "mcl_jukebox:record_far"
tick()
check(#played == 2 and music.is_playing(jukebox), "plays again the next holiday")
disc = nil
tick_alone()
check(#stopped == 2 and not music.is_playing(jukebox), "stops when a player takes the disc")
played, stopped = {}, {}

day = 16
disc = "mcl_jukebox:record_far"
holiday = false
tick()
check(#played == 0, "silent on an ordinary day")
holiday = true
time = 15000 / 24000
tick()
check(#played == 0, "silent before dinner")

-- A disc a player put in during dinner is already playing to them.
day = 17
disc = nil
time = 15600 / 24000
minetest.registered_nodes["mcl_jukebox:jukebox"].on_rightclick(jukebox, nil, nil, "mcl_jukebox:record_far")
tick(); tick()
check(#played == 0 and not music.is_playing(jukebox), "no second copy of a player's disc")

-- An unloaded block is unknown, not gone: keep playing, no second start.
day = 18
disc = nil
players.ann = {x = 5, y = 2, z = 3}
tick()
check(music.is_playing(jukebox) and #played == 1, "plays the next holiday")
node = nil
tick(); tick_alone()
check(#stopped == 0 and music.is_playing(jukebox), "unloaded block keeps the music")
node = "mcl_jukebox:jukebox"
tick(); tick_alone()
check(#played == 1 and #stopped == 0, "loaded again: same handle, no second start")
players.bob = {x = 3, y = 2, z = 3}
tick()
check(#played == 2 and played[2].spec.to_player == "bob", "a newcomer still gets it after the gap")

-- A player puts a disc in while the keeper's default track plays.
minetest.registered_nodes["mcl_jukebox:jukebox"].on_rightclick(jukebox, nil, nil, "mcl_jukebox:record_far")
tick(); tick_alone()
check(#stopped == 2 and not music.is_playing(jukebox), "keeper's sounds stop for the player's disc")
tick(); tick()
check(#played == 2 and not music.is_playing(jukebox), "no double playback")
players.bob = nil

-- Digging the jukebox ends the music with no keeper about.
day = 19
disc = nil
played, stopped = {}, {}
tick()
check(music.is_playing(jukebox) and #played == 1, "plays the next holiday")
node = "air"
tick_alone()
check(#stopped == 1 and not music.is_playing(jukebox), "stops when the jukebox is gone")
node = "mcl_jukebox:jukebox"
tick()
check(#played == 1, "not restarted the same day")
day = 20
tick()
check(#played == 2 and music.is_playing(jukebox), "plays again on the next holiday")
time = 17600 / 24000
tick_alone()
check(#stopped == 2, "stops at close")

-- No records at all: one warning, no music.
time = 15600 / 24000
day = 21
local saved = mcl_jukebox.registered_records
mcl_jukebox.registered_records = {}
tick(); day = 22; tick()
check(#logs == 1 and logs[1]:find("%[living_villages%]") and not music.is_playing(jukebox), "one warning")
mcl_jukebox.registered_records = saved
print("music tests passed")
