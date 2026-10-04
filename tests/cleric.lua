-- Run with: lua tests/cleric.lua
local time = 10000 / 24000
local now, day = 0, 3
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
	get_day_count = function() return day end,
	get_item_group = function() return 0 end,
	registered_nodes = {["living_villages:pulpit"] = {}},
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

local cleric = dofile("cleric.lua")
local pulpit = {x = 5, y = 0, z = 0}
nodes[key(pulpit)] = "living_villages:pulpit"

local vanilla_custom = function() end
local gopaths = {}
local def = {
	do_custom = function(self, dtime) return vanilla_custom(self, dtime) end,
	gopath = function(self, target, callback) table.insert(gopaths, {self = self, target = target, callback = callback}) return true end,
}
cleric.install(def)

local function villager(id, pos, profession)
	local self = {_id = id, _profession = profession or "unemployed", state = "stand"}
	self.object = {get_pos = function() return pos end, set_pos = function(_, p) pos = p end}
	return setmetatable(self, {__index = def})
end

-- An unemployed adult beside a free pulpit claims it and becomes a cleric
-- with vanilla's own (unset) trades.
local alice = villager("alice", {x = 4, y = 0, z = 0})
def.do_custom(alice, 0.1)
assert(alice._profession == "cleric" and alice._trades == nil)
assert(vector.equals(alice._jobsite, pulpit) and cleric.claimed_pulpit(alice))
assert(minetest.get_meta(pulpit):get_string("villager") == "alice")
assert(cleric.status(alice):find("works at the pulpit", 1, true))

-- One cleric per pulpit.
local bob = villager("bob", {x = 6, y = 0, z = 0})
def.do_custom(bob, 0.1)
assert(bob._profession == "unemployed" and #gopaths == 0)

-- Librarians, children, and anyone with a jobsite never claim one.
local free = {x = 30, y = 0, z = 0}
nodes[key(free)] = "living_villages:pulpit"
local lib = villager("lib", {x = 29, y = 0, z = 0}, "librarian")
now = now + 20
def.do_custom(lib, 0.1)
assert(lib._profession == "librarian" and not lib._jobsite and #gopaths == 0)
local kid = villager("kid", {x = 29, y = 0, z = 0})
kid.child = true
def.do_custom(kid, 0.1)
assert(kid._profession == "unemployed" and #gopaths == 0)
local employed = villager("emp", {x = 29, y = 0, z = 0}, "cleric")
employed._jobsite = {x = 99, y = 0, z = 0}
def.do_custom(employed, 0.1)
assert(not vector.equals(employed._jobsite, free) and #gopaths == 0)

-- A distant villager walks to a free pulpit and claims it on arrival, unless
-- someone took it first.
local carol = villager("carol", {x = 10, y = 0, z = 0})
def.do_custom(carol, 0.1)
assert(#gopaths == 1 and vector.equals(gopaths[1].target, free))
assert(carol._profession == "unemployed", "no claim before arriving")
minetest.get_meta(free):set_string("villager", "someone")
carol.object:set_pos({x = 29, y = 0, z = 0})
gopaths[1].callback(carol)
assert(carol._profession == "unemployed" and not carol._jobsite)
minetest.get_meta(free):set_string("villager", "")
gopaths[1].callback(carol)
assert(carol._profession == "cleric" and vector.equals(carol._jobsite, free))

-- A traded cleric that lost its jobsite takes a free pulpit and keeps its trades.
local dave = villager("dave", {x = 29, y = 0, z = 1}, "cleric")
dave._trades = "traded"
minetest.get_meta(free):set_string("villager", "")
carol._jobsite = nil
nodes[key(free)] = nil
nodes[key(free)] = "living_villages:pulpit"
minetest.get_meta(free):set_string("villager", "")
now = now + 20
def.do_custom(dave, 0.1)
assert(dave._profession == "cleric" and dave._trades == "traded" and vector.equals(dave._jobsite, free))

-- Another trip already under way is left alone.
local busy = villager("busy", {x = 10, y = 0, z = 0})
busy.state = "gowp"
local count = #gopaths
now = now + 20
def.do_custom(busy, 0.1)
assert(#gopaths == count)
local keeping = villager("keeping", {x = 10, y = 0, z = 0})
keeping._villages_keeper_target = {x = 1, y = 0, z = 0}
def.do_custom(keeping, 0.1)
assert(#gopaths == count)

-- An unreachable nearest pulpit does not starve a reachable one, and is not
-- retried straight away.
local sealed, open = {x = 60, y = 0, z = 0}, {x = 70, y = 0, z = 0}
nodes[key(sealed)] = "living_villages:pulpit"
nodes[key(open)] = "living_villages:pulpit"
metas[key(sealed)], metas[key(open)] = nil, nil
nodes[key(free)], nodes[key(pulpit)] = nil, nil
local base_gopath = def.gopath
local attempted = {}
def.gopath = function(self, target)
	table.insert(attempted, target.x)
	return target.x ~= sealed.x
end
local erin = villager("erin", {x = 55, y = 0, z = 0})
erin._villages_job_search_route = {status = "retry"}
now = now + 20
def.do_custom(erin, 0.1)
assert(attempted[1] == sealed.x and attempted[2] == open.x, "the reachable pulpit is tried after the sealed one")
assert(erin._villages_job_search_route == nil, "the first failure's backoff does not block the next pulpit")
now = now + 20
def.do_custom(erin, 0.1)
assert(attempted[3] == open.x and #attempted == 3, "the sealed pulpit is skipped on later polls")
-- A busy pathfinder (nil, not false) is not a verdict on the pulpit.
def.gopath = function(self, target) table.insert(attempted, target.x) end
local frank = villager("frank", {x = 55, y = 0, z = 0})
now = now + 20
def.do_custom(frank, 0.1)
assert(#attempted == 4 and attempted[4] == sealed.x, "a nil gopath stops the search without skipping")
def.gopath = base_gopath

-- Vanilla's verdicts are untouched: a cleric whose pulpit is gone is
-- whatever vanilla made of it, and the claim is not kept.
nodes[key(pulpit)] = nil
assert(not cleric.claimed_pulpit(alice))
assert(cleric.status(alice) == "no pulpit")

print("cleric.lua: ok")
