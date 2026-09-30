-- Run with: lua tests/keeper.lua
local time = 10000 / 24000
local now = 0
local nodes, metas, logs, shown = {}, {}, {}, {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end

vector = {
	equals = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	add = function(a, n) return {x = a.x + n, y = a.y + n, z = a.z + n} end,
	subtract = function(a, n) return {x = a.x - n, y = a.y - n, z = a.z - n} end,
}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_item_group = function() return 0 end,
	registered_nodes = {["mcl_jukebox:jukebox"] = {}},
	get_translator = function(domain)
		return function(message) return "<" .. domain .. ":" .. message .. ">" end
	end,
	get_color_escape_sequence = function(color) return "{" .. color .. "}" end,
	formspec_escape = function(text) return (text:gsub("[%[%];,]", "\\%0")) end,
	serialize = function(value) return value end,
	log = function(_, message) table.insert(logs, message) end,
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
	get_meta = function(pos)
		local k = key(pos)
		metas[k] = metas[k] or {}
		return {
			get_string = function(_, field) return metas[k][field] or "" end,
			set_string = function(_, field, value) metas[k][field] = value end,
		}
	end,
	find_node_near = function(pos, radius, names)
		for k, name in pairs(nodes) do
			if name == names[1] then
				local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
				local site = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
				if math.abs(site.x - pos.x) <= radius and math.abs(site.y - pos.y) <= radius
					and math.abs(site.z - pos.z) <= radius then return site end
			end
		end
	end,
	find_nodes_in_area = function(_, _, names)
		local found = {}
		for k, name in pairs(nodes) do
			if name == names[1] then
				local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
				table.insert(found, {x = tonumber(x), y = tonumber(y), z = tonumber(z)})
			end
		end
		return found
	end,
	show_formspec = function(name, formname, formspec) shown[name] = {formname, formspec} end,
}

local keeper = dofile("keeper.lua")
local jukebox = {x = 5, y = 0, z = 0}
local smoker = {x = -5, y = 0, z = 0}
nodes[key(jukebox)] = "mcl_jukebox:jukebox"
nodes[key(smoker)] = "mcl_smoker:smoker"

local vanilla_custom = function() end
local gopaths = {}
local def = {
	on_activate = function() end,
	do_custom = function(self, dtime) return vanilla_custom(self, dtime) end,
	gopath = function(self, target, callback) table.insert(gopaths, {self = self, target = target, callback = callback}) return true end,
	on_rightclick = function() end,
}
keeper.install(def)

local function villager(id, pos, profession)
	local self = {_id = id, _profession = profession or "unemployed", state = "stand"}
	self.object = {get_pos = function() return pos end, set_pos = function(_, p) pos = p end}
	return setmetatable(self, {__index = def})
end

-- An unemployed adult beside a free jukebox takes it, with the keeper menu.
local alice = villager("alice", {x = 4, y = 0, z = 0})
def.do_custom(alice, 0.1)
assert(alice._villages_keeper and alice._profession == "butcher")
assert(vector.equals(alice._jobsite, jukebox))
assert(minetest.get_meta(jukebox):get_string("villager") == "alice")
assert(alice._trades[1].offered.name == "mcl_farming:bread" and alice._trades[1].tier == 1)
assert(keeper.claimed_jukebox(alice))

-- Exactly one keeper per jukebox: a second villager finds nothing to claim.
local bob = villager("bob", {x = 6, y = 0, z = 0})
def.do_custom(bob, 0.1)
assert(not bob._villages_keeper and bob._profession == "unemployed" and #gopaths == 0)

-- A distant villager walks to a free jukebox and claims it on arrival, but
-- not if someone took it first.
local second = {x = 30, y = 0, z = 0}
nodes[key(second)] = "mcl_jukebox:jukebox"
metas[key(second)] = nil
local carol = villager("carol", {x = 10, y = 0, z = 0})
def.do_custom(carol, 0.1)
assert(#gopaths == 1 and vector.equals(gopaths[1].target, second))
assert(not carol._villages_keeper, "no claim before arriving")
carol.object:set_pos({x = 29, y = 0, z = 0})
gopaths[1].callback(carol)
assert(carol._villages_keeper and vector.equals(carol._jobsite, second))

-- After vanilla's 17:30 night begins, its do_activity clears the work order
-- and skips do_work; the keeper must still hold its post until 18:30.
time = 18000 / 24000
vanilla_custom = function(self) if self.order == "work" then self.order = nil end end
alice.order = "work"
def.do_custom(alice, 0.1)
assert(alice.order == "work", "keeper keeps working through vanilla's night")
assert(keeper.status(alice) == "staffing the tavern")
local count = #gopaths
alice.object:set_pos({x = 12, y = 0, z = 0})
now = now + 10
def.do_custom(alice, 0.1)
assert(#gopaths == count + 1 and vector.equals(gopaths[#gopaths].target, jukebox), "a drifted keeper walks back")
assert(alice.order == nil)
alice.object:set_pos({x = 4, y = 0, z = 0})
time = 19500 / 24000
alice.order = nil
def.do_custom(alice, 0.1)
assert(alice.order == nil, "no hold once service ends")
time = 10000 / 24000
vanilla_custom = function() end

-- A keeper refuses vanilla trips to any other workstation.
minetest.get_item_group = function(name, group) return 0 end
local common = dofile("common.lua")
assert(common.is_workstation_node("mcl_smoker:smoker"))
assert(def.gopath(alice, smoker) == false)

-- A traded keeper that loses its jukebox keeps the role and its trades, and
-- any smoker vanilla hands it is released again.
alice._trades[1].traded_once = true
nodes[key(jukebox)] = nil
vanilla_custom = function(self)
	self._jobsite = {x = smoker.x, y = smoker.y, z = smoker.z}
	minetest.get_meta(smoker):set_string("villager", self._id)
end
def.do_custom(alice, 0.1)
assert(alice._villages_keeper and alice._profession == "butcher" and alice._jobsite == nil)
assert(minetest.get_meta(smoker):get_string("villager") == "")

-- An untraded keeper that loses its jukebox is unemployed again.
vanilla_custom = function(self) self._jobsite, self._profession, self._trades = nil, "unemployed", nil end
nodes[key(second)] = nil
def.do_custom(carol, 0.1)
assert(not carol._villages_keeper and carol._profession == "unemployed")

-- The trade window names the keeper, not the butcher it is layered on.
local player = {is_player = function() return true end, get_player_name = function() return "p" end}
nodes[key(second)] = "mcl_jukebox:jukebox"
metas[key(second)] = nil
local dave = villager("dave", {x = 30, y = 1, z = 0})
def.do_custom(dave, 0.1)
assert(dave._villages_keeper)
def.on_rightclick(dave, player)
local title = "label[3,0;" .. minetest.formspec_escape("{#313131}<mobs_mc:Butcher> - <mobs_mc:Novice>{#ffffff}") .. "]"
minetest.show_formspec("p", "mobs_mc:trade_p", "size[9,8.75]" .. title)
assert(shown.p[2]:find("<villages:Tavern Keeper> - <mobs_mc:Novice>", 1, true), shown.p[2])
assert(not shown.p[2]:find("Butcher", 1, true))
-- An ordinary butcher's window is left alone.
local erin = villager("erin", {x = 0, y = 0, z = 9}, "butcher")
def.on_rightclick(erin, player)
minetest.show_formspec("p", "mobs_mc:trade_p", "size[9,8.75]" .. title)
assert(shown.p[2]:find("Butcher", 1, true))

-- A keeper reactivating without the flag is recognized from its claim.
dave._villages_keeper = nil
def.on_activate(dave, "", 0)
assert(dave._villages_keeper)

print("keeper.lua: ok")
