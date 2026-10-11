-- Run with: lua tests/flock.lua
local time = 10000 / 24000
local now, day = 1000, 1
local nodes, metas = {}, {}
local settings = {}
local players = {{pos = {x = 0, y = 0, z = 0}}}
local objects = {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end
local function parse(k)
	local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end

vector = {
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	round = function(a) return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
	new = function(a, b, c)
		if type(a) == "table" then return {x = a.x, y = a.y, z = a.z} end
		return {x = a, y = b, z = c}
	end,
}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_item_group = function() return 0 end,
	settings = {get = function(_, name) return settings[name] end},
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["mcl_bells:bell"] = {walkable = false},
		["mcl_loom:loom"] = {walkable = true},
	},
	log = function() end,
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
	get_meta = function(pos)
		return {get_string = function(_, field) return (metas[key(pos)] or {})[field] or "" end}
	end,
	get_connected_players = function()
		local list = {}
		for _, p in ipairs(players) do
			table.insert(list, {get_pos = function() return p.pos end})
		end
		return list
	end,
	get_objects_inside_radius = function(pos, radius)
		local found = {}
		for _, obj in ipairs(objects) do
			local p = obj:get_pos()
			if p and vector.distance(p, pos) <= radius then table.insert(found, obj) end
		end
		return found
	end,
	find_nodes_in_area = function(minp, maxp, names)
		local found = {}
		for k, name in pairs(nodes) do
			local p = parse(k)
			if name == names[1] and p.x >= minp.x and p.x <= maxp.x and p.y >= minp.y and p.y <= maxp.y
				and p.z >= minp.z and p.z <= maxp.z then
				table.insert(found, p)
			end
		end
		table.sort(found, function(a, b) return key(a) < key(b) end)
		return found
	end,
}

local flock = dofile("flock.lua")
local common = dofile("common.lua")
common.activity_override = flock.activity_override

local function reset()
	nodes, metas, objects = {}, {}, {}
	for k in pairs(flock.registry) do flock.registry[k] = nil end
	for x = -70, 70 do
		for z = -70, 70 do nodes[key({x = x, y = -1, z = z})] = "mcl_core:stone" end
	end
end

-- A sheep entity with the parts of mcl_mobs' mob class that flock.lua uses.
local function make_sheep(x, z)
	local pos = {x = x, y = -0.49, z = z}
	local ent = {name = "mobs_mc:sheep", state = "stand", walk_velocity = 1, run_velocity = 2}
	local obj = {removed = false}
	obj.get_pos = function() if obj.removed then return nil end return pos end
	obj.set_pos = function(_, p) pos.x, pos.y, pos.z = p.x, p.y, p.z end
	obj.get_luaentity = function() return ent end
	ent.object = obj
	ent.pos = pos
	ent.velocity = 0
	ent.heading = {1, 0}
	ent.stand = function(s) s.velocity, s.state, s.animation = 0, "stand", "stand" end
	ent.set_velocity = function(s, v) s.velocity = v end
	ent.set_animation = function(s, a) s.animation = a end
	ent.turn_in_direction = function(s, dx, dz) s.heading = {dx, dz} end
	ent.is_at_cliff_or_danger = function() return false end
	table.insert(objects, obj)
	return ent, obj
end

local spawned = 0
mcl_mobs = {
	spawn = function(pos, name)
		assert(name == "mobs_mc:sheep", "only sheep are spawned")
		spawned = spawned + 1
		local _, obj = make_sheep(pos.x, pos.z)
		return obj
	end,
}

local villager_def = {do_custom = function() end, on_die = function() end}
local sheep_def = {}
sheep_def.do_custom = function() sheep_def.vanilla_ran = (sheep_def.vanilla_ran or 0) + 1 end
local bell = dofile("bell.lua")
flock.install(villager_def, sheep_def, bell)

local ids = 0
local gopaths = {}
local function shepherd(x, z, extra)
	ids = ids + 1
	local pos = {x = x, y = -0.49, z = z}
	local self = {_id = "s" .. ids, _profession = "shepherd", state = "stand",
		_bed = {x = x, y = 0, z = z}, _jobsite = {x = x + 2, y = 0, z = z}}
	nodes[key(self._jobsite)] = "mcl_loom:loom"
	metas[key(self._jobsite)] = {villager = self._id}
	self.object = {get_pos = function() return pos end, set_velocity = function() end}
	self.pos = pos
	self.player_in_active_range = function() return self.near ~= false end
	self.ready_to_path = function() return true end
	self.gopath = function(s, target)
		table.insert(gopaths, {self = s, target = target})
		s.state = "gowp"
		return true
	end
	for k, v in pairs(extra or {}) do self[k] = v end
	return self
end

local function tick(self, seconds)
	for _ = 1, seconds or 1 do villager_def.do_custom(self, 1) end
end

local function flock_of(self)
	local mine = {}
	for _, obj in ipairs(objects) do
		local ent = obj:get_luaentity()
		if ent._villages_shepherd == self._id and not obj.removed then table.insert(mine, ent) end
	end
	return mine
end

local function flat(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

-- Drive every sheep for tenths of a second, as the engine's on_step does through do_custom.
local function step_sheep(tenths)
	for _ = 1, tenths do
		for _, obj in ipairs(objects) do
			local ent = obj:get_luaentity()
			if sheep_def.do_custom(ent, 0.1) == false and ent.velocity > 0 then
				local dx, dz = ent.heading[1], ent.heading[2]
				local len = math.sqrt(dx * dx + dz * dz)
				ent.pos.x = ent.pos.x + dx / len * ent.velocity * 0.1
				ent.pos.z = ent.pos.z + dz / len * ent.velocity * 0.1
			end
		end
	end
end

local function activity_of(villager)
	local activity
	common.as_villager(villager, function() activity = common.get_activity() end)
	return activity
end

-- 1. A shepherd with a loom gets sheep one at a time, five at most, each marked with
-- its id; a day's spawns are capped.
reset()
local a = shepherd(0, 0)
tick(a, 3)
assert(#flock_of(a) == 1, "the first sheep is spawned at once, one at a time")
tick(a, 60)
assert(#flock_of(a) == 5 and spawned == 5, "five sheep, no more")
for _, ent in ipairs(flock_of(a)) do
	assert(flat(ent.pos, a.pos) <= 7, "sheep are set down beside the shepherd")
end
for _, ent in ipairs(flock_of(a)) do ent.object.removed = true end
tick(a, 60)
assert(#flock_of(a) == 0 and spawned == 5, "no more than five a day")
day = 2
tick(a, 60)
assert(#flock_of(a) == 5 and spawned == 10, "a new day allows new sheep")

-- 2. Children, non-shepherds, shepherds with no loom and shepherds nobody is near keep none.
reset(); spawned = 0
for name, extra in pairs({child = {child = true}, farmer = {_profession = "farmer"}, away = {near = false}}) do
	local s = shepherd(0, 0, extra)
	tick(s, 30)
	assert(spawned == 0, "no flock for " .. name)
end
local loomless = shepherd(0, 0)
metas[key(loomless._jobsite)] = {villager = "someone else"}
tick(loomless, 30)
assert(spawned == 0, "no flock without a claimed loom")

-- 3. The setting: a smaller number caps the flock; 0 turns it off and lets it go.
reset(); spawned = 0
local b = shepherd(0, 0)
settings.living_villages_flock_size = "3"
tick(b, 60)
assert(#flock_of(b) == 3, "the setting sets the flock size")
settings.living_villages_flock_size = "0"
tick(b, 2)
assert(#flock_of(b) == 0, "size 0 lets the flock go")
local before = spawned
tick(b, 30)
assert(spawned == before, "size 0 spawns none")
settings.living_villages_flock_size = nil

-- 4. A village keeps 15 sheep over its shepherds.
reset(); spawned = 0; day = 3
local crowd = {}
for i = 1, 4 do crowd[i] = shepherd(i * 3, 0) end
for _ = 1, 80 do for i = 1, 4 do tick(crowd[i]) end end
assert(spawned == flock.VILLAGE_CAP, "the village cap holds: " .. spawned)
for i = 1, 4 do assert(#flock_of(crowd[i]) <= 5) end

-- 5. Following: sheep beyond FAR are pulled in, those near are left alone.
reset(); spawned = 0; day = 5
local c = shepherd(0, 0)
local near_sheep = make_sheep(2, 0)
local far_sheep = make_sheep(9, 0)
local running_sheep = make_sheep(30, 0)
for _, ent in ipairs({near_sheep, far_sheep, running_sheep}) do ent._villages_shepherd = c._id end
settings.living_villages_flock_size = nil
-- Today's sheep have been made already, so no more are added.
c._villages_flock_day, c._villages_flock_made = day, 5
tick(c)
step_sheep(1)
assert(not (flock.states[near_sheep] and flock.states[near_sheep].pull), "a sheep close by is not pulled")
assert(flock.states[far_sheep].pull and not flock.states[far_sheep].pull.run, "a sheep 9 away walks")
assert(flock.states[running_sheep].pull.run, "a sheep 30 away comes running")
assert(far_sheep.state == "walk" and far_sheep.animation == "walk" and running_sheep.animation == "run")
assert(sheep_def.vanilla_ran, "vanilla's own do_custom still runs")
local start = flat(far_sheep.pos, c.pos)
step_sheep(10)
assert(flat(far_sheep.pos, c.pos) < start, "the pulled sheep gets closer")
for _ = 1, 8 do tick(c); step_sheep(10) end
assert(flat(far_sheep.pos, c.pos) <= flock.NEAR + 0.2, "and stops within NEAR")
assert(far_sheep.state == "stand" and far_sheep.velocity == 0, "it rests there")
-- Stages that take the shepherd to a building release the flock: a pull it does not
-- renew runs out, and the sheep stay where they are.
running_sheep.pos.x = 40
time = 16000 / 24000 -- tavern
tick(c, 3)
step_sheep(40)
assert(running_sheep.state == "stand" and not flock.states[running_sheep].pull, "an unrenewed pull ends")
local stay = running_sheep.pos.x
step_sheep(30)
assert(running_sheep.pos.x == stay, "released sheep stay where they are")
tick(c, 5)
assert(not flock.states[running_sheep].pull, "no pull at the tavern stage")
time = 6000 / 24000 -- putter
tick(c)
assert(flock.states[running_sheep].pull and flock.states[running_sheep].pull.run,
	"when the shepherd is free they come running")
-- Holidays: church and bell stages release them, and putter does not.
day = 8
time = 8000 / 24000
local st = flock.states[running_sheep]
st.pull = nil
tick(c, 3)
assert(not st.pull, "the church stage releases the flock")
time = 10800 / 24000
tick(c, 3)
assert(not st.pull, "so does the bell stage")
time = 6000 / 24000
tick(c)
assert(st.pull, "and the holiday putter stage does not")
day = 5

-- 6. Under a roof the flock is left alone.
st.pull = nil
tick(c, 1)
nodes[key({x = 0, y = 4, z = 0})] = "mcl_core:stone"
st.pull = nil
tick(c, 3)
assert(not st.pull, "a shepherd under a roof is not followed")
nodes[key({x = 0, y = 4, z = 0})] = nil
tick(c, 2)
assert(st.pull, "and is again in the open")

-- 7. Stuck against a fence, the sheep rests and vanilla's wander takes over.
st.pull = nil
running_sheep.pos.x, running_sheep.pos.z = 20, 0
tick(c)
assert(st.pull)
for _ = 1, 100 do sheep_def.do_custom(running_sheep, 0.1) end
assert(not st.pull and st.rest_until > now, "a stuck sheep rests")
tick(c, 2)
assert(not st.pull, "and is not pulled again while it rests")
now = now + 10
tick(c)
assert(st.pull, "but is, after the rest")

-- 8. A drop in the way stops the sheep. (Make room: drop the sheep the holiday test added.)
c._villages_flock_day, c._villages_flock_made = day, 5
near_sheep.object.removed = true
for _, ent in ipairs(flock_of(c)) do
	if ent ~= far_sheep and ent ~= running_sheep then ent.object.removed = true end
end
local edge = make_sheep(15, 0)
edge._villages_shepherd = c._id
edge.is_at_cliff_or_danger = function() return "free fall" end
tick(c, 11) -- it is found at the next scan
step_sheep(3)
assert(edge.state == "stand" and flock.states[edge].rest_until, "a sheep at a drop rests")

-- 9. Far behind: set down beside the shepherd if no one sees it, not if someone does.
local lost = make_sheep(60, 0)
lost._villages_shepherd = c._id
players = {{pos = {x = 56, y = 0, z = 0}}, {pos = {x = 0, y = 0, z = 0}}}
tick(c, 11)
assert(lost.pos.x == 60, "a lost sheep in sight is not moved")
players = {{pos = {x = 0, y = 0, z = 0}}}
tick(c, 2)
assert(flat(lost.pos, c.pos) <= 7, "out of sight it is set down by the shepherd")
players = {{pos = {x = 0, y = 0, z = 0}}}

-- 10. The shepherd reloaded: a new entity with the same id finds the flock again.
reset(); spawned = 0; day = 9
settings.living_villages_flock_size = nil
local d = shepherd(0, 0)
tick(d, 60)
local kept = flock_of(d)
assert(#kept == 5)
local reloaded = shepherd(0, 0)
reloaded._id = d._id
reloaded._jobsite = d._jobsite
metas[key(d._jobsite)] = {villager = d._id}
reloaded._villages_flock_day, reloaded._villages_flock_made = d._villages_flock_day, d._villages_flock_made
local before_spawn = spawned
tick(reloaded, 20)
assert(spawned == before_spawn, "a reloaded shepherd does not spawn a second flock")
assert(#flock.sessions[reloaded].sheep == 5, "it found its sheep again")
-- Persistence: the sheep carry a plain string, and nothing session-only is on them.
for _, ent in ipairs(kept) do
	assert(type(ent._villages_shepherd) == "string")
	for k in pairs(ent) do assert(not tostring(k):find("pull"), "no pull state on the entity") end
end

-- 11. A lost claim lets them go, after the grace period; death at once.
metas[key(d._jobsite)] = {villager = "other"}
tick(d, flock.GRACE - 5)
assert(#flock_of(d) == 5, "a missing claim is waited out")
tick(d, 10)
assert(#flock_of(d) == 0, "a lost claim releases the flock")
local e = shepherd(0, 0)
tick(e, 20)
assert(#flock_of(e) >= 1)
villager_def.on_die(e, e.pos, nil)
assert(#flock_of(e) == 0, "a dead shepherd's sheep are released")

-- 12. Herding in the work stage: grazing stops about the bell, and no pull to the loom.
reset(); spawned = 0; day = 6; time = 10000 / 24000
gopaths = {}
nodes[key({x = 15, y = 5, z = 0})] = "mcl_bells:bell"
local center = bell.center_of({x = 15, y = 5, z = 0})
local f = shepherd(0, 0)
tick(f, 3)
assert(#gopaths >= 1, "the shepherd sets off for a grazing stop")
local stop = gopaths[1].target
assert(flat(stop, center) <= 20 and flat(stop, center) >= 5 - 1e-9, "the stop is about the bell")
assert(activity_of(f) == "herd", "vanilla is told the shepherd is not at work")
assert(activity_of(shepherd(40, 40, {_profession = "farmer"})) == "work", "others are unaffected")
-- It arrives and lingers with its wander about the stop.
f.pos.x, f.pos.z = stop.x, stop.z
f.state = "stand"
tick(f)
assert(f._villages_wander_anchor and f._villages_wander_anchor.radius == 3
	and flat(f._villages_wander_anchor.pos, stop) == 0, "it grazes about the stop")
local walks = #gopaths
tick(f, 10)
assert(#gopaths == walks, "it lingers before the next stop")
tick(f, 41)
assert(#gopaths == walks + 1 and f._villages_wander_anchor == nil, "then goes to another")
-- After HERD_OUT it goes back to the loom, where vanilla's work resumes.
f.state = "stand"
tick(f, flock.HERD_OUT - 50)
assert(activity_of(f) == "work", "back to the loom after a while")
local walks2 = #gopaths
tick(f, 10)
assert(#gopaths == walks2, "no grazing walks while at the loom")
-- The flock does not follow it there.
for _, ent in ipairs(flock_of(f)) do ent.pos.x = 30 end
tick(f, 3)
step_sheep(40)
for _, ent in ipairs(flock_of(f)) do
	assert(not (flock.states[ent] and flock.states[ent].pull), "no flock at the loom")
end
tick(f, flock.HERD_LOOM)
assert(activity_of(f) == "herd", "and out again")
-- The tavern stage ends the herd and stops its walk.
f.state = "gowp"
f._villages_herd_probe = nil
time = 16000 / 24000
villager_def.do_custom(f, 1)
assert(f.state == "stand", "the herd walk ends with the stage")
assert(activity_of(f) ~= "herd")

-- 13. No bell: it grazes about the loom. A bell too near vanilla's limit is passed over.
reset(); gopaths = {}; time = 10000 / 24000
local h = shepherd(0, 0)
tick(h, 3)
assert(#gopaths == 1 and flat(gopaths[1].target, h._jobsite) <= 12, "no bell: about the loom")
reset(); gopaths = {}
nodes[key({x = 45, y = 5, z = 0})] = "mcl_bells:bell"
local far_home = shepherd(0, 0)
tick(far_home, 3)
assert(#gopaths == 1 and flat(gopaths[1].target, far_home._jobsite) <= 12,
	"a bell near vanilla's 50 node limit is passed over")

-- 14. Trading holds the herd.
reset(); gopaths = {}
local t = shepherd(0, 0, {_trading_players = {x = true}})
tick(t, 5)
assert(#gopaths == 0, "no herding while someone is trading")

print("flock: ok")
