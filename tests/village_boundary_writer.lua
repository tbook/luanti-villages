-- Run with: lua5.1 tests/village_boundary_writer.lua
local logs = {}
minetest = {get_modpath = function() return "." end, log = function(_, line) logs[#logs + 1] = line end}
local boundary = dofile("village_boundary.lua")

local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function rect(x0, z0, x1, z1) return {x0 = x0, z0 = z0, x1 = x1, z1 = z1} end
local town = {rect(0, 0, 4, 4), rect(7, 0, 9, 4)}
local function distance(x, z)
	local nearest = math.huge
	for _, r in ipairs(town) do
		local dx, dz = math.max(r.x0 - x, 0, x - r.x1), math.max(r.z0 - z, 0, z - r.z1)
		nearest = math.min(nearest, math.sqrt(dx * dx + dz * dz))
	end
	return nearest
end
local function setup()
	local world, reads, writes, cleanup = {}, {}, {}, {}
	local engine = {
		CONTENT_AIR = 0,
		registered_nodes = {
			air = {walkable = false},
			["mcl_core:dirt"] = {walkable = true},
			["mcl_core:dirt_with_grass"] = {walkable = true},
			["mcl_farming:sweet_berry_bush_3"] = {walkable = false, groups = {plant = 1}},
			["mcl_bamboo:bamboo"] = {walkable = true, groups = {plant = 1}},
		},
		get_node = function(pos)
			reads[#reads + 1] = {x = pos.x, y = pos.y, z = pos.z}
			local value = world[key(pos.x, pos.y, pos.z)]
			if value then return {name = value.name, param2 = value.param2 or 0} end
			return {name = pos.y <= 8 and "mcl_core:dirt_with_grass" or "air", param2 = 0}
		end,
		swap_node = function(pos, node)
			writes[#writes + 1] = {x = pos.x, y = pos.y, z = pos.z}
			world[key(pos.x, pos.y, pos.z)] = {name = node.name, param2 = node.param2 or 0}
		end,
	}
	local function inside(x, z)
		for _, r in ipairs(town) do
			if x >= r.x0 and x <= r.x1 and z >= r.z0 and z <= r.z1 then return true end
		end
		return false
	end
	local env = {
		engine = engine,
		load_node = function(pos) return {name = "air"} end,
		heights = function(area)
			return function(x, z)
				if x == 23 and z == 2 then return {} end -- Real heights lookup for an all-air column.
				local y = 8
				local c = {y = y, ground_y = y, ground_name = "mcl_core:dirt_with_grass",
					base_y = y, base_name = "mcl_core:dirt_with_grass"}
				if x == 13 and z == 2 then c.y = 12 end
				if x == 15 and z == 2 then c.ground_liquid, c.ground_name = true, "mcl_core:water_source" end
				if x == 16 and z == 2 then c.ground_name, c.base_name = "mcl_core:snow", "mcl_core:ice" end
				if x == 17 and z == 2 then c.ground_name, c.base_name = "mcl_bamboo:bamboo", "mcl_core:ice" end
				if x == 12 and z == 8 then c.ground_name, c.base_name = "mcl_core:snow", "mcl_core:ice" end
				if x == 22 and z == 2 then c.overhang, c.base_name = true, nil end
				return c
			end
		end,
		scan = function()
			return {find = function(x0, z0, x1, z1)
				if 20 >= x0 and 20 <= x1 and 2 >= z0 and 2 <= z1 then return "foreign:wall" end
			end}
		end,
		clear_trees = function(zones, protected)
			cleanup[#cleanup + 1] = {zones = zones, protected = protected}
			return {removed = 0, written = nil}
		end,
	}
	return {world = world, reads = reads, writes = writes, cleanup = cleanup, engine = engine, env = env, inside = inside}
end

local scene = setup()
-- The city can contain roofs and overlapping, irregular footprints. Boundary
-- cleanup receives the union; terrain writing must preserve every interior node
-- and param2 value, including cells in the recess between rectangles.
scene.world[key(2, 12, 2)] = {name = "foreign:roof", param2 = 3}
scene.world[key(8, 13, 2)] = {name = "foreign:roof", param2 = 5}
scene.world[key(5, 11, 2)] = {name = "mcl_core:tree", param2 = 1}
scene.world[key(16, 8, 2)] = {name = "mcl_core:ice", param2 = 0}
scene.world[key(17, 7, 2)] = {name = "mcl_core:ice", param2 = 0}
scene.world[key(17, 8, 2)] = {name = "mcl_bamboo:bamboo", param2 = 0}
scene.world[key(12, 8, 8)] = {name = "mcl_core:ice", param2 = 0}
scene.world[key(12, 9, 2)] = {name = "mcl_farming:sweet_berry_bush_3", param2 = 2}
for y = 9, 12 do scene.world[key(13, y, 2)] = {name = "mcl_bamboo:bamboo", param2 = 0} end
local roof_before = scene.world[key(2, 12, 2)].name .. ":" .. scene.world[key(2, 12, 2)].param2
scene.env.clear_trees = function(zones, protected)
	scene.cleanup[#scene.cleanup + 1] = {zones = zones, protected = protected}
	scene.world[key(11, 10, 2)] = {name = "air", param2 = 0}
	return {removed = 1, written = {minp = {x = 11, y = 10, z = 2}, maxp = {x = 11, y = 10, z = 2}}}
end
local interior_before = {}
for z = -2, 6 do for x = -2, 11 do
	if scene.inside(x, z) then for y = -20, 30 do
		local node = scene.engine.get_node({x = x, y = y, z = z})
		interior_before[key(x, y, z)] = node.name .. ":" .. node.param2
	end end
end end
local ok, stats = boundary.smooth(town, 0, {env = scene.env})
assert(ok and stats and stats.changed > 0, "boundary grade runs through the existing column writer: " .. tostring(stats))
assert(#scene.cleanup == 1 and scene.cleanup[1].protected == town, "tree cleanup is batched and protects the union")
assert(scene.world[key(2, 12, 2)].name .. ":" .. scene.world[key(2, 12, 2)].param2 == roof_before,
	"roof and param2 inside the city stay untouched")
assert(scene.world[key(8, 13, 2)].name == "foreign:roof" and scene.world[key(8, 13, 2)].param2 == 5,
	"overlapping footprint stays untouched")
assert(scene.engine.get_node({x = 5, y = 0, z = 2}).name ~= "air", "a recess outside the footprint union remains eligible")
assert(scene.engine.get_node({x = 15, y = 8, z = 2}).name == "mcl_core:dirt_with_grass", "water shoreline remains unchanged")
assert(scene.engine.get_node({x = 16, y = 8, z = 2}).name == "mcl_core:ice", "snow-covered ice remains unchanged")
assert(scene.engine.get_node({x = 17, y = 7, z = 2}).name == "mcl_core:ice"
	and scene.engine.get_node({x = 17, y = 8, z = 2}).name == "mcl_bamboo:bamboo",
	"growth over ice remains unchanged")
assert(scene.engine.get_node({x = 12, y = 8, z = 8}).name == "mcl_core:ice"
	and scene.engine.get_node({x = 13, y = 8, z = 8}).name == "mcl_core:dirt_with_grass",
	"snow-covered ice and directly adjacent ground remain unchanged")
assert(scene.engine.get_node({x = 14, y = 8, z = 2}).name == "mcl_core:dirt_with_grass", "ground directly beside water stays fixed")
assert(scene.engine.get_node({x = 18, y = 8, z = 2}).name == "mcl_core:dirt_with_grass"
	and scene.engine.get_node({x = 19, y = 8, z = 2}).name == "mcl_core:dirt_with_grass",
	"ground directly beside snow and growth-covered ice stays fixed")
assert(scene.engine.get_node({x = 20, y = 8, z = 2}).name == "mcl_core:dirt_with_grass", "foreign structure margin stays fixed")
assert(scene.engine.get_node({x = 22, y = 8, z = 2}).name == "mcl_core:dirt_with_grass", "overhang is not graded")
assert(scene.engine.get_node({x = 23, y = 8, z = 2}).name == "mcl_core:dirt_with_grass",
	"all-air columns with no ground or base names are skipped")
assert(scene.engine.get_node({x = 24, y = 8, z = 2}).name == "mcl_core:dirt_with_grass", "strict radius edge stays fixed")
assert(scene.engine.get_node({x = 12, y = 9, z = 2}).name == "air"
	and scene.engine.get_node({x = 12, y = 4, z = 2}).name == "mcl_farming:sweet_berry_bush_3",
	"decor moves with its graded surface")
for y = -20, 40 do
	assert(scene.engine.get_node({x = 13, y = y, z = 2}).name ~= "mcl_bamboo:bamboo", "stalk is cleared during grading")
end
assert(stats.max_movement <= 20 and stats.tree_removed == 1 and stats.written,
	"stats report capped movement and actual write envelope")
assert(stats.written.minp.x <= 11 and stats.written.maxp.x >= 11 and stats.written.minp.y <= 10
	and stats.written.maxp.y >= 10, "write envelope includes cleanup changes")
local recess_written = false
local volume = assert(boundary.volume(town, 0))
local function contained(p)
	return p.x >= volume.minp.x and p.x <= volume.maxp.x and p.y >= volume.minp.y and p.y <= volume.maxp.y
		and p.z >= volume.minp.z and p.z <= volume.maxp.z
end
for _, p in ipairs(scene.reads) do assert(contained(p), "direct read inside the queried volume") end
for _, p in ipairs(scene.writes) do
	if p.x == 5 or p.x == 6 then recess_written = true end
	assert(contained(p), "write inside the queried volume")
	assert(not scene.inside(p.x, p.z), "writer boundary excludes every town column")
	assert(distance(p.x, p.z) < 20,
		"terrain writes remain strictly inside the transition radius")
end
assert(recess_written, "the narrow gap between town rectangles is not masked as interior")
for k, before in pairs(interior_before) do
	local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
	local after = scene.engine.get_node({x = tonumber(x), y = tonumber(y), z = tonumber(z)})
	assert(after.name .. ":" .. after.param2 == before, "complete interior snapshot stays unchanged at " .. k)
end
for _, axis in ipairs({"x", "y", "z"}) do
	assert(stats.written.minp[axis] >= volume.minp[axis] and stats.written.maxp[axis] <= volume.maxp[axis],
		"reported write envelope fits the query")
end

-- Unloaded preflight runs before cleanup. A late height failure returns a
-- truthful failure after the tree stage has already made its change.
local unloaded = setup()
unloaded.env.load_node = function() return {name = "ignore"} end
local unloaded_ok = boundary.smooth(town, 0, {env = unloaded.env})
assert(unloaded_ok == false and #unloaded.cleanup == 0 and #unloaded.writes == 0,
	"unloaded preflight performs no cleanup or writes")

local late = setup()
late.env.clear_trees = function()
	late.world[key(30, 8, 2)] = {name = "air", param2 = 0}
	return {removed = 1, written = {minp = {x = 30, y = 8, z = 2}, maxp = {x = 30, y = 8, z = 2}}}
end
late.env.heights = function() error("injected height failure") end
local late_ok, late_reason = boundary.smooth(town, 0, {env = late.env})
assert(late_ok == false and late_reason:find("after tree cleanup", 1, true), "late failure is explicit about partial work")
assert(late.world[key(30, 8, 2)].name == "air", "late failure does not pretend to roll cleanup back")

local noop = setup()
local noop_ok, noop_stats = boundary.smooth(town, 0, {radius = 0, env = noop.env})
assert(noop_ok and noop_stats.changed == 0 and #noop.cleanup == 0 and #noop.writes == 0,
	"radius zero is a complete no-op")

local capped = setup()
local capped_ok, capped_stats = boundary.smooth(town, 0, {cap = 3, env = capped.env})
assert(capped_ok and capped_stats.max_movement <= 3, "explicit movement cap is honored")

print("village_boundary_writer: ok")
