-- Run with: lua tests/well.lua   (from the repository root)
-- Morning at the well (#11): finding wells by shape on the stock well and on water that
-- is not one, who goes and when, the cap on how many are at a well, the walk, the drift,
-- the skip after a failed walk and the exclusions.
local stock_world = dofile("tests/support/stock_world.lua")

local ORIGIN = 30
local PUTTER, WORK = 6000 / 24000, 7200 / 24000
local now, day = 1000, 1
local weather = "clear"
local area_calls = 0

local function round(v) return math.floor(v + 0.5) end

-- Installs the stock stubs for a world and the few extras this module needs: a real
-- find_nodes_in_area over the placed cells, a clock and the weather.
local function install(world)
	stock_world.install(world)
	minetest.get_gametime = function() return now end
	minetest.get_day_count = function() return day end
	minetest.get_timeofday = function() return world.timeofday end
	minetest.find_nodes_in_area = function(minp, maxp, names)
		area_calls = area_calls + 1
		local wanted, found = {}, {}
		for _, name in ipairs(names) do wanted[name] = true end
		for k, cell in pairs(world.cells) do
			if wanted[cell.name] then
				local x, y, z = k:match("(-?%d+):(-?%d+):(-?%d+)")
				x, y, z = tonumber(x), tonumber(y), tonumber(z)
				if x >= minp.x and x <= maxp.x and y >= minp.y and y <= maxp.y and z >= minp.z and z <= maxp.z then
					table.insert(found, {x = x, y = y, z = z})
				end
			end
		end
		table.sort(found, function(a, b)
			if a.x ~= b.x then return a.x < b.x end
			if a.y ~= b.y then return a.y < b.y end
			return a.z < b.z
		end)
		return found
	end
	mcl_weather = {get_weather = function() return weather end}
end

local function new_world(rotation, with_well)
	local world = stock_world.new()
	install(world)
	if with_well ~= false then
		world.place(dofile("tests/fixtures/buildings/well.lua"), ORIGIN, ORIGIN, {}, rotation or 0)
	end
	return world
end

local function fresh_module()
	local well = dofile("well.lua")
	return well
end

local function water_cells(world)
	local list = {}
	for k, cell in pairs(world.cells) do
		if cell.name == "mcl_core:water_source" then
			local x, y, z = k:match("(-?%d+):(-?%d+):(-?%d+)")
			table.insert(list, {x = tonumber(x), y = tonumber(y), z = tonumber(z)})
		end
	end
	return list
end

-- Detection on the stock well at every rotation.
for rotation = 0, 3 do
	local world = new_world(rotation)
	local well = fresh_module()
	well.scan({x = ORIGIN - 6, y = 1, z = ORIGIN + 3})
	local count = 0
	for _, found in pairs(well.wells) do
		count = count + 1
		assert(found.water.y == 2 and found.stand_y == 1, "the water sits one above the standing level")
		-- the water is the two by two in the middle of the 6 by 8 footprint, rotated
		local w, d = 6, 8
		if rotation % 2 == 1 then w, d = d, w end
		assert(found.center.x == ORIGIN + (w - 1) / 2 and found.center.z == ORIGIN + (d - 1) / 2,
			"the well is found in the middle of its building")
	end
	assert(count == 1, "the stock well is found once at rotation " .. rotation)
end

-- Water that is not a well.
local function scan_count(world, origin)
	local well = fresh_module()
	well.scan(origin or {x = 10, y = 1, z = 10})
	local n = 0
	for _ in pairs(well.wells) do n = n + 1 end
	return n, well
end

do
	-- A pond: a 2x2 dug into the ground, level with the grass round it.
	local world = new_world(0, false)
	for dx = 0, 1 do for dz = 0, 1 do world.set({x = 10 + dx, y = 0, z = 10 + dz}, "mcl_core:water_source") end end
	assert(scan_count(world) == 0, "a 2x2 pond in the ground is not a well")

	-- The same on the open ground with no walls: a puddle on top of the ground.
	world = new_world(0, false)
	for dx = 0, 1 do for dz = 0, 1 do world.set({x = 10 + dx, y = 1, z = 10 + dz}, "mcl_core:water_source") end end
	assert(scan_count(world) == 0, "water with no walls round it is not a well")

	-- Walls, a plinth, but a bigger body of water: a 2x3 and a lake.
	for _, size in ipairs({{2, 2}, {2, 3}, {6, 6}}) do
		world = new_world(0, false)
		for dx = -1, size[1] do for dz = -1, size[2] do
			world.set({x = 10 + dx, y = 1, z = 10 + dz}, "mcl_core:cobble")
			if dx >= 0 and dx < size[1] and dz >= 0 and dz < size[2] then
				world.set({x = 10 + dx, y = 2, z = 10 + dz}, "mcl_core:water_source")
			else
				world.set({x = 10 + dx, y = 2, z = 10 + dz}, "mcl_core:stonebrick")
			end
		end end
		if size[1] == 2 and size[2] == 2 then
			assert(scan_count(world) == 1, "control: a walled 2x2 on a plinth is a well")
		else
			assert(scan_count(world) == 0, "a " .. size[1] .. "x" .. size[2] .. " pool is not a well")
		end
	end

	-- A 2x2 well shape whose water goes down: deeper water below is a lake's top.
	world = new_world(0)
	for _, pos in ipairs(water_cells(world)) do world.set({x = pos.x, y = pos.y - 1, z = pos.z}, "mcl_core:water_source") end
	assert(scan_count(world, {x = ORIGIN - 6, y = 1, z = ORIGIN + 3}) == 0, "water over water is not a well")

	-- The stock well with water above it (a lake poured over the roof's hole).
	world = new_world(0)
	for _, pos in ipairs(water_cells(world)) do world.set({x = pos.x, y = pos.y + 1, z = pos.z}, "mcl_core:water_source") end
	assert(scan_count(world, {x = ORIGIN - 6, y = 1, z = ORIGIN + 3}) == 0, "water under water is not a well")

	-- A well in a solid block of stone has nowhere to stand.
	world = new_world(0)
	for x = ORIGIN - 6, ORIGIN + 12 do for z = ORIGIN - 6, ORIGIN + 14 do for y = 1, 3 do
		local current = world.get({x = x, y = y, z = z}).name
		if current == "air" then world.set({x = x, y = y, z = z}, "mcl_core:stone") end
	end end end
	assert(scan_count(world, {x = ORIGIN - 6, y = 1, z = ORIGIN + 3}) == 0, "a well with no standing places is not one")

	-- And with the water gone from a stock well.
	world = new_world(0)
	for _, pos in ipairs(water_cells(world)) do world.set(pos, "air") end
	assert(scan_count(world, {x = ORIGIN - 6, y = 1, z = ORIGIN + 3}) == 0, "an emptied well is not one")
end

-- The scan is remembered: many villagers, one pass; again after a while.
do
	local world = new_world(0)
	local well = fresh_module()
	area_calls = 0
	for i = 1, 20 do well.scan({x = ORIGIN - 6 + i % 3, y = 1, z = ORIGIN + 3}) end
	assert(area_calls == 1, "one scan serves the villagers of a patch of the map")
	now = now + well.SCAN_SECONDS + 1
	well.scan({x = ORIGIN - 6, y = 1, z = ORIGIN + 3})
	assert(area_calls == 2, "the area is looked at again after a while")
	now = now + well.SCAN_SECONDS + 1
end

-- Villagers.
local world, well
local def, gopaths, answer
local ids = 0

local function setup(rotation)
	world = new_world(rotation or 0)
	well = fresh_module()
	gopaths, answer = {}, true
	def = {
		on_activate = function() end,
		do_custom = function() end,
		on_die = function() end,
		get_staticdata = function(self)
			local saved = {}
			for k, v in pairs(self) do if type(v) ~= "table" or k:match("^_villages") then saved[k] = v end end
			return saved
		end,
	}
	well.install(def)
	world.timeofday = PUTTER
	day = day + 1
	if day % 4 == 0 then day = day + 1 end
end

local function villager(x, z, extra)
	ids = ids + 1
	local pos = {x = x, y = 0.51, z = z}
	local self = {_id = "v" .. ids, state = "stand", _bed = {x = x, y = 1, z = z},
		_villages_well_day = day, _villages_well_going = true}
	self.object = {get_pos = function() return pos end, set_velocity = function() end}
	self.ready_to_path = function() return true end
	self.gopath = function(s, target)
		table.insert(gopaths, {self = s, target = target})
		if answer then s.state = "gowp" end
		return answer
	end
	self.pos = pos
	for k, v in pairs(extra or {}) do self[k] = v end
	return self
end

local function tick(self, times)
	for _ = 1, times or 1 do def.do_custom(self, 0.1) end
end

local function flat(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

setup()
local site
for _, found in pairs(well.wells) do site = found end
-- Not yet scanned: the first villager's search finds it.
local first = villager(ORIGIN - 6, ORIGIN + 3)
tick(first)
for _, found in pairs(well.wells) do site = found end
assert(site, "the well is found when a villager looks")
local center = site.center
assert(#gopaths == 1 and gopaths[1].self == first, "a villager sets off for the well")
local target = gopaths[1].target
assert(target.y == site.stand_y, "it walks to the ground level beside the well, not the rim")
assert(flat(target, center) >= well.SPOT_MIN - 1e-9 and flat(target, center) <= well.SPOT_MAX + 0.71, "its spot is about the water")
assert(first._villages_wander_anchor == nil, "no anchor until it arrives")

-- The cap: three at the well, the rest putter.
local crowd = {}
for i = 1, 6 do
	crowd[i] = villager(ORIGIN - 6, ORIGIN + 3 + i)
	tick(crowd[i])
end
assert(#gopaths == well.CAP, "no more than the cap go to one well (" .. #gopaths .. ")")
assert(crowd[3]._villages_well == nil and crowd[2]._villages_well ~= nil, "the first two after the first are in; the rest are not")
-- Their spots are their own.
for i = 1, #gopaths do for j = i + 1, #gopaths do
	assert(flat(gopaths[i].target, gopaths[j].target) >= 1.5 - 1e-9, "villagers do not share a spot")
end end
-- A place frees when its villager leaves, and the next in line can take it.
local spare = crowd[6]
tick(spare)
assert(spare._villages_well == nil, "the well is still full while the others hold it")
tick(first)
assert(first._villages_well, "a villager on its way keeps its place")
first.pos.x, first.pos.z = target.x, target.z
first.state = "stand"
tick(first)
assert(first._villages_wander_anchor and first._villages_wander_anchor.radius == well.GATHER_RADIUS
	and first._villages_wander_anchor.max_y == site.stand_y and flat(first._villages_wander_anchor.pos, center) == 0,
	"arrival anchors its wander on the well, on the ground level")
assert(def.get_staticdata(first)._villages_wander_anchor == nil and first._villages_wander_anchor, "the visit is not saved")
assert(def.get_staticdata(first)._villages_well == nil, "the visit is not saved with the villager")
-- It stays a while, then goes and does not come back this morning.
local others = {crowd[1], crowd[2]}
now = now + well.STAY_MIN - 5
tick(first)
assert(first._villages_well, "it is still there part way through its stay")
now = now + well.STAY_MAX
tick(first)
assert(first._villages_well == nil and first._villages_wander_anchor == nil and first._villages_well_going == false,
	"it leaves at the end of its stay")
local before = #gopaths
now = now + 20
tick(first, 3)
assert(#gopaths == before and first._villages_well == nil, "it does not return the same morning")
tick(spare)
assert(spare._villages_well, "the freed place goes to the next villager")
-- The next morning it may.
day = day + 1
if day % 4 == 0 then day = day + 1 end
first._villages_well_day = nil
assert(first._villages_well_going == false)

-- The stage ends: everyone lets go.
world.timeofday = WORK
for _, v in ipairs({crowd[1], crowd[2], spare}) do
	v.state = "gowp"
	tick(v)
	assert(v._villages_well == nil and v._villages_wander_anchor == nil and v.state == "stand", "work time releases the villager")
end
world.timeofday = PUTTER

-- Not at night, not in a thunderstorm, not with the setting off.
setup()
local function goes(v)
	local n = #gopaths
	tick(v)
	return #gopaths > n
end
local active = villager(ORIGIN - 6, ORIGIN + 3)
assert(goes(active), "control: it goes in the Putter stage")
setup()
world.timeofday = 2000 / 24000
assert(not goes(villager(ORIGIN - 6, ORIGIN + 3)), "not at night")
world.timeofday = 7200 / 24000
assert(not goes(villager(ORIGIN - 6, ORIGIN + 3)), "not at work time")
world.timeofday = 20000 / 24000
assert(not goes(villager(ORIGIN - 6, ORIGIN + 3)), "not asleep")
world.timeofday = PUTTER
weather = "thunder"
assert(not goes(villager(ORIGIN - 6, ORIGIN + 3)), "not in a thunderstorm")
weather = "clear"
minetest.settings = {get_bool = function() return false end}
assert(not goes(villager(ORIGIN - 6, ORIGIN + 3)), "not with the setting off")
minetest.settings = nil
-- Holidays are Putter mornings too.
day = 8
assert(goes(villager(ORIGIN - 6, ORIGIN + 3, {_villages_well_day = 8})), "also on a holiday morning")
-- ...but the church and the bell take over in their stages.
world.timeofday = 8000 / 24000
assert(not goes(villager(ORIGIN - 6, ORIGIN + 3, {_villages_well_day = 8})), "not at the church service")
world.timeofday = 11000 / 24000
assert(not goes(villager(ORIGIN - 6, ORIGIN + 3, {_villages_well_day = 8})), "not at the bell gathering")
day = 1
world.timeofday = PUTTER

-- Exclusions.
setup()
for name, extra in pairs({
	child = {child = true},
	keeper = {_villages_keeper = true},
	following = {following = {}},
	asleep = {_villages_sleeping = true},
	church = {_villages_church = {}},
	bell = {_villages_bell = {}},
	seat = {_villages_seat = {}},
	fishing = {_villages_fish_session = {}},
	walking = {state = "gowp"},
	unnamed = {_id = false},
}) do
	assert(not goes(villager(ORIGIN - 6, ORIGIN + 3, extra)), name .. " does not go to the well")
end
-- A trade stops it, and the time does not count against its walk.
local trader = villager(ORIGIN - 6, ORIGIN + 3)
assert(goes(trader))
local since = trader._villages_well.since
trader._trading_players = {x = true}
tick(trader, 5)
assert(math.abs(trader._villages_well.since - since - 0.5) < 1e-9, "trading time is not counted against the walk")

-- Whether it goes is a chance, once a day.
setup()
local going, total = 0, 400
math.randomseed(11)
for i = 1, total do
	local v = villager(ORIGIN - 6, ORIGIN + 3, {_villages_well_day = false, _villages_well_going = false})
	v._villages_well_day = nil
	tick(v)
	if v._villages_well_going then going = going + 1 end
end
assert(going > total * 0.25 and going < total * 0.55, "some, not all, villagers roll to go (" .. going .. "/" .. total .. ")")
local roller = villager(ORIGIN - 6, ORIGIN + 3, {_villages_well_day = false})
roller._villages_well_day = nil
tick(roller)
local rolled = roller._villages_well_going
tick(roller, 10)
assert(roller._villages_well_going == rolled, "the roll stands for the day")

-- No well in reach: it putters, and a well far away is not walked to.
setup()
for _, pos in ipairs(water_cells(world)) do world.set(pos, "air") end
local lone = villager(ORIGIN - 6, ORIGIN + 3)
tick(lone, 5)
assert(#gopaths == 0 and lone._villages_wander_anchor == nil, "no well leaves the villager to putter")
setup()
local far = villager(ORIGIN + 300, ORIGIN + 3)
tick(far, 5)
assert(#gopaths == 0, "a well beyond the village is not walked to")
local beyond = villager(ORIGIN + well.SEARCH_RADIUS + 20, ORIGIN + 3)
tick(beyond)
assert(#gopaths == 0, "a well just out of reach is not walked to")

-- An unreachable well is given up, and passed over for a while.
setup()
answer = false
local stuck = villager(ORIGIN - 6, ORIGIN + 3)
tick(stuck, 3)
assert(stuck._villages_well == nil and stuck._villages_wander_anchor == nil, "no route gives the well up")
assert(next(stuck._villages_well_skipped), "the well is remembered as passed over")
local tries = #gopaths
now = now + 20
tick(stuck, 3)
assert(#gopaths == tries, "a well passed over is not tried again at once")
now = now + 700
answer = true
tick(stuck)
assert(#gopaths == tries + 1, "it tries again after a long while")

-- A walk that takes too long is given up.
setup()
local slow = villager(ORIGIN - 6, ORIGIN + 3)
tick(slow)
assert(slow._villages_well)
slow.state = "gowp"
now = now + 400
tick(slow)
assert(slow._villages_well == nil and next(slow._villages_well_skipped), "a walk that takes too long is given up")

-- Pushed out of the radius, it walks back.
setup()
local pushed = villager(ORIGIN - 6, ORIGIN + 3)
tick(pushed)
for _, found in pairs(well.wells) do site = found end
pushed.pos.x, pushed.pos.z = gopaths[1].target.x, gopaths[1].target.z
pushed.state = "stand"
tick(pushed)
assert(pushed._villages_wander_anchor)
local due = pushed._villages_well.leave_at
pushed.pos.x = site.center.x + well.GATHER_RADIUS + 5
local walks = #gopaths
tick(pushed)
assert(#gopaths == walks + 1 and pushed._villages_wander_anchor == nil, "a straying villager walks back")
pushed.pos.x, pushed.pos.z = gopaths[#gopaths].target.x, gopaths[#gopaths].target.z
pushed.state = "stand"
now = now + 1
tick(pushed)
assert(pushed._villages_well.leave_at == due, "walking back does not extend the stay")
-- Pushed out with its time up, it goes rather than walking back.
pushed.pos.x = site.center.x + well.GATHER_RADIUS + 5
now = due + 1
tick(pushed)
assert(pushed._villages_well == nil, "a villager out of reach whose stay is over just leaves")

-- The well removed while it is attended: the visit is dropped.
setup()
local witness = villager(ORIGIN - 6, ORIGIN + 3)
tick(witness)
for _, found in pairs(well.wells) do site = found end
witness.pos.x, witness.pos.z = gopaths[1].target.x, gopaths[1].target.z
witness.state = "stand"
tick(witness)
assert(witness._villages_wander_anchor)
for _, pos in ipairs(water_cells(world)) do world.set(pos, "air") end
tick(witness)
assert(witness._villages_well == nil and witness._villages_wander_anchor == nil, "a removed well is dropped")
assert(next(well.wells) == nil, "and forgotten")

-- Death frees the place.
setup()
local mortal = villager(ORIGIN - 6, ORIGIN + 3)
tick(mortal)
assert(mortal._villages_well)
def.on_die(mortal)
assert(mortal._villages_well == nil, "dying leaves the well")
for _, hold in pairs(well.holds) do assert(next(hold) == nil, "and frees its place") end

-- A route another wrapper starts as the stage ends is left alone.
setup()
local handoff = {
	on_activate = function() end, on_die = function() end, get_staticdata = function() return {} end,
	do_custom = function(self)
		if minetest.get_timeofday() * 24000 >= 7000 and self.state ~= "gowp" then self.state = "gowp" end
	end,
}
well.install(handoff)
local guest = villager(ORIGIN - 6, ORIGIN + 3)
handoff.do_custom(guest, 0.1)
assert(guest._villages_well, "control: it set off for the well")
guest.state = "stand"
world.timeofday = WORK
handoff.do_custom(guest, 0.1)
assert(guest.state == "gowp" and guest._villages_well == nil, "the next stage's trip survives the stage change")

print("well tests passed")
