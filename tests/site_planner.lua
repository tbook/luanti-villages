-- Run with: lua tests/site_planner.lua
local logs = {}
minetest = {
	get_modpath = function() return "." end,
	pos_to_string = function(p) return ("(%d,%d,%d)"):format(p.x, p.y or 0, p.z) end,
	log = function(level, m) table.insert(logs, level .. ": " .. m) end,
}

-- A stand-in for PseudoRandom: a seeded generator with the same next(min, max).
local function PseudoRandom(seed)
	local state = seed % 2147483647
	return {next = function(_, lo, hi)
		state = (state * 48271) % 2147483647
		return lo + state % (hi - lo + 1)
	end}
end

-- mcl_villages' building list, as in const.lua.
local function schematics()
	return {
		{name = "belltower", hwidth = 5, hdepth = 5, hheight = 9, hsize = 14, max_num = 0},
		{name = "large_house", hwidth = 12, hdepth = 12, hheight = 9, hsize = 14, max_num = 0.08},
		{name = "blacksmith", hwidth = 8, hdepth = 11, hheight = 13, hsize = 13, max_num = 0.055},
		{name = "church", hwidth = 13, hdepth = 13, hheight = 14, hsize = 15, max_num = 0.04},
		{name = "farm", hwidth = 9, hdepth = 7, hheight = 13, hsize = 13, max_num = 0.1},
		{name = "lamp", hwidth = 3, hdepth = 4, hheight = 13, hsize = 10, max_num = 0.1},
		{name = "small_house", hwidth = 9, hdepth = 8, hheight = 8, hsize = 13, max_num = 0.7},
		{name = "tavern", hwidth = 12, hdepth = 10, hheight = 10, hsize = 13, max_num = 0.05},
		{name = "well", hwidth = 6, hdepth = 8, hheight = 6, hsize = 10, max_num = 0.045},
	}
end

local registered = {
	["air"] = {walkable = false},
	["mcl_core:dirt_with_grass"] = {walkable = true},
	["mcl_core:leaves"] = {walkable = true},
	["mcl_core:water_source"] = {walkable = false, liquidtype = "source"},
}

-- A world from a height function h(x, z) (nil: no ground) and water(x, z).
local function world(h, water)
	water = water or function() return false end
	local waits = {}
	local settlements = {schematic_table = schematics()}
	settlements.find_surface = function(pos, wait)
		if wait then waits[#waits + 1] = pos end
		local y = h(pos.x, pos.z)
		if not y or water(pos.x, pos.z) then return nil end
		return {x = pos.x, y = y, z = pos.z}, "mcl_core:dirt_with_grass"
	end
	settlements.check_distance = function(info, pos, size) -- as mcl_villages/utils.lua
		for _, built in ipairs(info) do
			local distance = math.sqrt((pos.x - built.pos.x) ^ 2 + (pos.z - built.pos.z) ^ 2)
			if distance < size or distance < built.hsize then return false end
		end
		return true
	end
	settlements.terraform = function() end
	settlements.surface_mat = {["mcl_core:dirt_with_grass"] = true}
	return {
		settlements = settlements,
		waits = waits,
		registered_nodes = registered,
		get_node = function(pos)
			local y = h(pos.x, pos.z)
			if y and water(pos.x, pos.z) and pos.y <= y + 2 then return {name = "mcl_core:water_source"} end
			if y and pos.y <= y then return {name = "mcl_core:dirt_with_grass"} end
			return {name = "air"}
		end,
		get_chunk_number = function(pos) return math.floor(pos.x / 80) .. "," .. math.floor(pos.z / 80) end,
		log = minetest.log,
	}
end

local planner = dofile("site_planner.lua")
local minp, maxp = {x = -40, y = 0, z = -40}, {x = 40, y = 40, z = 40}
local function plan(env, seed) return planner.plan(maxp, minp, PseudoRandom(seed or 1), env) end

local function box(entry, env)
	for _, s in ipairs(env.settlements.schematic_table) do
		if s.name == entry.name then
			local swap = entry.rotat == "90" or entry.rotat == "270"
			return entry.pos.x, entry.pos.z, entry.pos.x + (swap and s.hdepth or s.hwidth) - 1,
				entry.pos.z + (swap and s.hwidth or s.hdepth) - 1
		end
	end
end

-- Flat ground: a village, with the church reserved, a rounded entry shape and the belltower first.
local flat = world(function() return 10 end)
local result, why = plan(flat)
assert(result, why)
assert(#result >= planner.config.min_buildings, "at least the minimum number of buildings")
assert(result[1].name == "belltower" and result[1].pos.x == 0 and result[1].pos.z == 0)
local has_church
for _, entry in ipairs(result) do
	assert(entry.pos.y == 10 and entry.surface_mat == "mcl_core:dirt_with_grass" and entry.hsize and entry.rotat, "entry shape")
	has_church = has_church or entry.name == "church"
end
assert(has_church, "the church is reserved before the random pick")
for i = 1, #result do
	for j = i + 1, #result do
		local a, b = result[i].pos, result[j].pos
		assert(flat.settlements.check_distance({result[i]}, b, result[j].hsize), "buildings keep their distance")
	end
end
local radius_limit = planner.config.max_cells * planner.config.cell + planner.config.radius_jitter + 1
for _, entry in ipairs(result) do
	assert(math.sqrt(entry.pos.x ^ 2 + entry.pos.z ^ 2) <= radius_limit, "sites stay within 5 cells")
end
assert(#flat.waits >= 1 and flat.waits[1].x == 0, "the first sample in a chunk waits for it")
local seen = {}
for _, pos in ipairs(flat.waits) do
	local key = flat.get_chunk_number(pos)
	assert(not seen[key], "each chunk is waited for once")
	seen[key] = true
end

-- Determinism: the same seed gives the same plan; another seed differs.
local again = plan(world(function() return 10 end))
assert(#again == #result)
for i, entry in ipairs(result) do
	local other = again[i]
	assert(entry.name == other.name and entry.rotat == other.rotat
		and entry.pos.x == other.pos.x and entry.pos.y == other.pos.y and entry.pos.z == other.pos.z, "same seed, same plan")
end
local different = plan(world(function() return 10 end), 2)
assert(different and (#different ~= #result or different[2].pos.x ~= result[2].pos.x or different[2].name ~= result[2].name),
	"another seed plans differently")

-- Dry run: wait = false is passed through as no waiting.
local dry = world(function() return 10 end)
dry.wait = false
assert(plan(dry))
assert(#dry.waits == 0, "a dry run never waits for unloaded chunks")

-- Average rule: the belltower's samples are 10, 10, 11 across x, so the average
-- 10.33 rounds up to 11.
local slanted = world(function(x) return x >= 3 and 11 or 10 end)
local planned = assert(plan(slanted, 3))
assert(planned[1].pos.y == 11, "floor is the average, rounded up: " .. planned[1].pos.y)

-- Within a site: every approved footprint has its nine samples within 3 blocks,
-- here on terraces 4 blocks high every 30 blocks, so footprints across an edge are rejected.
local function terrace(x) return 10 + 4 * math.floor((x + 15) / 30) end
local terraces = world(function(x) return terrace(x) end)
planned = assert(plan(terraces, 4))
for _, entry in ipairs(planned) do
	local x0, _, x1 = box(entry, terraces)
	local xs = {x0, math.floor((x0 + x1) / 2), x1}
	local low, high = math.huge, -math.huge
	for _, x in ipairs(xs) do low, high = math.min(low, terrace(x)), math.max(high, terrace(x)) end
	assert(high - low <= planner.config.max_spread, "a footprint spans a terrace edge: " .. entry.name)
end
local _, _, report = plan(terraces, 4)
assert(report.rejects.uneven and report.rejects.uneven > 0, "uneven sites were rejected and counted")

-- Between sites: a steady slope of 1 block per 4 gives footprints that are
-- level enough (spread 3 at most), but no two neighbors may differ by 5.
-- The slope is gradual per building, so the village may still climb it.
local function slope(x) return 10 + math.floor(x / 5) end
local sloped = world(function(x) return slope(x) end)
planned = assert(plan(sloped, 5))
local neighbor_range = planner.config.neighbor_cells * planner.config.cell
for i = 1, #planned do
	for j = i + 1, #planned do
		local ax0, az0, ax1, az1 = box(planned[i], sloped)
		local bx0, bz0, bx1, bz1 = box(planned[j], sloped)
		local d = math.sqrt(((ax0 + ax1) / 2 - (bx0 + bx1) / 2) ^ 2 + ((az0 + az1) / 2 - (bz0 + bz1) / 2) ^ 2)
		if d <= neighbor_range then
			assert(math.abs(planned[i].pos.y - planned[j].pos.y) < planner.config.max_step,
				("neighbors %s and %s differ by %d"):format(planned[i].name, planned[j].name,
					math.abs(planned[i].pos.y - planned[j].pos.y)))
		end
	end
end

-- Water: a pond rejects every site with a sample in it; none of the approved
-- samples is wet. A belltower in the water means no village.
local function pond(x, z) return x >= 20 and x <= 50 and z >= -20 and z <= 20 end
local wet = world(function() return 10 end, pond)
planned = assert(plan(wet, 6))
for _, entry in ipairs(planned) do
	local x0, z0, x1, z1 = box(entry, wet)
	for _, x in ipairs({x0, math.floor((x0 + x1) / 2), x1}) do
		for _, z in ipairs({z0, math.floor((z0 + z1) / 2), z1}) do
			assert(not pond(x, z), "no sample in the water: " .. entry.name)
		end
	end
end
local _, _, wet_report = plan(wet, 6)
assert(wet_report.rejects.water and wet_report.rejects.water > 0, "water rejections are counted")

-- A pond that find_surface walks past (it finds the bed's grass) is still water.
local deep = world(function() return 10 end, pond)
deep.settlements.find_surface = function(pos)
	return {x = pos.x, y = 10, z = pos.z}, "mcl_core:dirt_with_grass"
end
planned = assert(plan(deep, 6))
for _, entry in ipairs(planned) do
	local x0, z0, x1, z1 = box(entry, deep)
	for _, x in ipairs({x0, math.floor((x0 + x1) / 2), x1}) do
		for _, z in ipairs({z0, math.floor((z0 + z1) / 2), z1}) do
			assert(not pond(x, z), "no wet sample when find_surface misses the water: " .. entry.name)
		end
	end
end

local lake = world(function() return 10 end, function(x, z) return x >= 3 and x <= 8 and z >= 0 and z <= 4 end)
local failed, reason = plan(lake)
assert(failed == false and reason:find("belltower", 1, true) and reason:find("water", 1, true), "belltower in water: " .. tostring(reason))

-- Canopy: find_surface refuses ground with leaves above it, but the ground
-- under the leaves still counts, so such columns don't reject the site.
local canopy = world(function() return 10 end)
local function covered(x, z) return (x + z) % 3 == 0 and not (x == 0 and z == 0) end
local plain_find, plain_node = canopy.settlements.find_surface, canopy.get_node
canopy.settlements.find_surface = function(pos, wait)
	if covered(pos.x, pos.z) then return nil end
	return plain_find(pos, wait)
end
canopy.get_node = function(pos)
	if covered(pos.x, pos.z) and pos.y == 11 then return {name = "mcl_core:leaves"} end
	return plain_node(pos)
end
planned = plan(canopy)
assert(planned and planned[1].pos.y == 10, "ground under a canopy is a surface")
assert(not planned.rejects)

-- No surface at the center.
failed, reason = plan(world(function() return nil end))
assert(failed == false and reason:find("center", 1, true))

-- Too few buildings: a small island of ground.
local island = world(function(x, z) return (x * x + z * z <= 20 * 20) and 10 or nil end)
logs = {}
failed, reason = plan(island)
assert(failed == false and reason:find("only", 1, true), "an island is too small: " .. tostring(reason))
local logged
for _, line in ipairs(logs) do logged = logged or (line:find("buildings found sites", 1, true) and line:find("rejected", 1, true)) end
assert(logged, "the village rejection logs its reasons")

-- No church fits: the village is still built.
local nochurch = world(function() return 10 end)
for i, s in ipairs(nochurch.settlements.schematic_table) do
	if s.name == "church" then s.hsize = 200 end
end
planned = plan(nochurch)
assert(planned, "a village without a church is still built")
for _, entry in ipairs(planned) do assert(entry.name ~= "church") end

-- Install: replaces create_site_plan, and leaves vanilla in place when upstream changed.
local function globals(env)
	local original = function() return "vanilla" end
	env.settlements.create_site_plan = original
	return {settlements = env.settlements, mcl_vars = {get_chunk_number = env.get_chunk_number},
		max_height_difference = 56}, original
end
minetest.get_node = function(pos) return {name = pos.y <= 10 and "mcl_core:dirt_with_grass" or "air"} end
minetest.registered_nodes = registered
local g, original = globals(world(function() return 10 end))
assert(planner.install(g, minetest) == true)
assert(g.settlements.create_site_plan ~= original, "installed over create_site_plan")
local replaced = g.settlements.create_site_plan(maxp, minp, PseudoRandom(1))
assert(type(replaced) == "table" and replaced[1].name == "belltower", "the installed planner returns settlement_info")

local function expect_vanilla(mutate, needle)
	local env = world(function() return 10 end)
	local gl, orig = globals(env)
	mutate(gl)
	logs = {}
	assert(planner.install(gl, minetest) == false)
	assert(gl.settlements == nil or gl.settlements.create_site_plan == orig, "vanilla stays")
	local found
	for _, line in ipairs(logs) do found = found or (line:find("[living_villages]", 1, true) and line:find(needle, 1, true)) end
	assert(found, "a warning names " .. needle .. ": " .. table.concat(logs, "|"))
end
expect_vanilla(function(gl) gl.settlements.terraform = nil end, "terraform")
expect_vanilla(function(gl) gl.settlements.find_surface = nil end, "find_surface")
expect_vanilla(function(gl) gl.settlements.check_distance = "x" end, "check_distance")
expect_vanilla(function(gl) gl.max_height_difference = nil end, "max_height_difference")
expect_vanilla(function(gl) gl.mcl_vars = {} end, "get_chunk_number")
expect_vanilla(function(gl) gl.settlements.schematic_table = {{name = "belltower"}} end, "declined")
expect_vanilla(function(gl) gl.settlements.schematic_table = nil end, "schematic_table")
expect_vanilla(function(gl) gl.settlements = nil end, "settlements")

print("site_planner ok")
