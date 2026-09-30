-- Run with: lua tests/village_index.lua
local stored, logs = "", {}
local function vec(x, y, z) return {x = x, y = y, z = z} end
vector = {
	new = function(p) return vec(p.x, p.y, p.z) end,
	offset = function(p, x, y, z) return vec(p.x + x, p.y + y, p.z + z) end,
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
}
local command
local player_pos = vec(0, 0, 0)
local player = {get_pos = function() return player_pos end, set_pos = function(_, p) player_pos = p end}
minetest = {
	get_mod_storage = function()
		return {get_string = function() return stored end, set_string = function(_, _, v) stored = v end}
	end,
	serialize = function(v) return v end,
	deserialize = function(v) return v ~= "" and v or nil end,
	pos_to_string = function(p) return ("(%d,%d,%d)"):format(p.x, p.y, p.z) end,
	log = function(_, m) table.insert(logs, m) end,
	register_chatcommand = function(name, def) assert(name == "villages_goto"); command = def end,
	get_player_by_name = function() return player end,
}
local placed = 0
settlements = {place_schematics = function() placed = placed + 1 end}
dofile("village_index.lua")

local ok, message = command.func("p", "")
assert(not ok and message:find("0 village"), message)

settlements.place_schematics({{name = "belltower", pos = vec(100, 5, 0)}, {name = "small_house", pos = vec(110, 5, 0)}})
settlements.place_schematics({{name = "belltower", pos = vec(500, 7, 0)}, {name = "tavern", pos = vec(510, 7, 4)}})
assert(placed == 2, "the original placement still runs")
assert(logs[1]:find("no tavern") and logs[2]:find("tavern at %(510,7,4%)"))

ok, message = command.func("p", "")
assert(ok and player_pos.x == 516 and player_pos.y == 19 and player_pos.z == 9, message)
player_pos = vec(0, 0, 0)
ok = command.func("p", "any")
assert(ok and player_pos.x == 100 and player_pos.y == 17, "any picks the nearest village, tavern or not")

print("village_index.lua: ok")
