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

local edge = setup()
local cleanup_called, edge_protected = false, nil
edge.env.clear_trees = function(_, protected)
	cleanup_called, edge_protected = true, protected
	return {removed = 0}
end
edge.env.scan = function(_, ignore_at, conservative)
	assert(conservative, "safe contract scans trees as ambiguous structures")
	return {find = function(x0, z0, x1, z1)
		if x0 <= 9 and x1 >= 9 and z0 <= 2 and z1 >= 2 and not ignore_at(9, 10, 2) then return "building" end
		if x0 <= 14 and x1 >= 14 and z0 <= 3 and z1 >= 3 then return "foreign" end
	end}
end
local edge_ok = boundary.smooth(town, 0, {env = edge.env,
	structure_boxes = {{min={x=9,y=8,z=2}, max={x=9,y=13,z=2}}},
	is_protected = function(p) return p.x == 11 and p.y == 30 and p.z == 2 end})
assert(edge_ok and cleanup_called, "structure boxes do not skip tree clearing (#334)")
assert(type(edge_protected) == "function" and edge_protected(2, 2) and edge_protected(9, 2)
	and edge_protected(-1, 2) == false and edge_protected(11, 2) and not edge_protected(20, 9),
	"clearing protects the rectangles, the structure box footprint and options.is_protected columns")
assert(edge.engine.get_node({x=10,y=8,z=2}).name ~= "mcl_core:dirt_with_grass",
	"town building beside edge does not block exterior grading")
assert(edge.engine.get_node({x=11,y=8,z=2}).name == "mcl_core:dirt_with_grass",
	"a protected node anywhere in write envelope blocks the column")
assert(edge.engine.get_node({x=13,y=8,z=3}).name == "mcl_core:dirt_with_grass",
	"foreign structure margin remains protected")

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

-- With structure boxes the real fragments.clear_trees runs (no injected stub, #334). A
-- building's logs are trunks like any tree, so they must survive, while trees outside
-- the boxes go. The VoxelManip here is a sparse stand-in for the engine's.
VoxelArea = {new = function(_, e)
	local a = {MinEdge = e.MinEdge, MaxEdge = e.MaxEdge}
	local dx, dy = e.MaxEdge.x - e.MinEdge.x + 1, e.MaxEdge.y - e.MinEdge.y + 1
	function a:index(x, y, z)
		return (z - e.MinEdge.z) * dx * dy + (y - e.MinEdge.y) * dx + (x - e.MinEdge.x) + 1
	end
	return a
end}
local AIR, TREE, LEAVES, STONE, IGNORE = 0, 1, 2, 3, 4
local content = {[0] = "air", "mcl_core:tree", "mcl_core:leaves", "mcl_core:stone", "ignore"}
local function voxel_manip(nodes)
	local vm, area = {}, nil
	function vm:read_from_map(a, b) area = {a, b}; return a, b end
	function vm:get_data()
		local a, b = area[1], area[2]
		local va, data = VoxelArea:new({MinEdge = a, MaxEdge = b}), {}
		for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do
			data[va:index(x, y, z)] = nodes[key(x, y, z)] or AIR
		end end end
		return data
	end
	function vm:set_data(data)
		local a, b = area[1], area[2]
		local va = VoxelArea:new({MinEdge = a, MaxEdge = b})
		for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do
			local id = data[va:index(x, y, z)]
			nodes[key(x, y, z)] = id ~= AIR and id or nil
		end end end
	end
	function vm:write_to_map() end
	return vm
end
-- A 6-high trunk on stone with a 5x5 canopy at y 6..7.
local function sapling(nodes, x, z)
	nodes[key(x, 0, z)] = STONE
	for y = 1, 6 do nodes[key(x, y, z)] = TREE end
	for dx = -2, 2 do for dz = -2, 2 do for y = 6, 7 do
		if not nodes[key(x + dx, y, z + dz)] then nodes[key(x + dx, y, z + dz)] = LEAVES end
	end end end
end
local function canopy_count(nodes)
	local n = 0
	for _, id in pairs(nodes) do if id == TREE or id == LEAVES then n = n + 1 end end
	return n
end
local function real_clear(nodes)
	local s = setup()
	local engine = s.engine
	engine.CONTENT_IGNORE = IGNORE
	engine.get_name_from_content_id = function(id) return content[id] end
	engine.registered_nodes["mcl_core:stone"] = {is_ground_content = true}
	engine.registered_nodes["mcl_core:tree"] = {is_ground_content = false, groups = {tree = 1}}
	engine.registered_nodes["mcl_core:leaves"] = {groups = {leaves = 1}}
	engine.get_voxel_manip = function() return voxel_manip(nodes) end
	s.env.clear_trees = nil
	s.env.scan = function() return {find = function() end} end
	return s
end

-- One town rectangle {0..2} x {0..2} and radius 6: the zone is x -6..8, z -6..8, y +-48.
-- Ground is stone at y = 0. Each ID below is a trunk on stone with a canopy at y 6..7.
--   A: outside the boxes and the zone's middle; must be cleared.
--   D: its trunk column is protected only by options.is_protected; the trunk must stay,
--      its other leaves must go.
--   B: its canopy touches the building column; must be cleared.
--   building: a column of logs at x = 9, z = 0 (the structure box); must stay.
--   C: beyond the zone (x >= 10), reachable only by a fill that runs into the building;
--      must stay, which is what the protected building column buys.
local real_nodes = {}
local town_small = {rect(0, 0, 2, 2)}
sapling(real_nodes, -3, 0)  -- A
sapling(real_nodes, -3, 5)  -- D
sapling(real_nodes, 6, 0)   -- B
sapling(real_nodes, 12, 0)  -- C
local building_x = 9
for y = 1, 6 do real_nodes[key(building_x, y, 0)] = TREE end
real_nodes[key(building_x, 0, 0)] = STONE
local canopy_before = canopy_count(real_nodes)

local real = real_clear(real_nodes)
local real_ok, real_stats = boundary.smooth(town_small, 0, {env = real.env, radius = 6,
	structure_boxes = {{min = {x = building_x, y = 1, z = 0}, max = {x = building_x, y = 6, z = 0}}},
	is_protected = function(p) return p.x == -3 and p.y == 3 and p.z == 5 end})
assert(real_ok, "boundary smooth with boxes and the real clear: " .. tostring(real_stats))
local function any_canopy(x0, x1, z0, z1)
	for x = x0, x1 do for z = z0, z1 do for y = 1, 7 do
		local id = real_nodes[key(x, y, z)]
		if id == TREE or id == LEAVES then return key(x, y, z) end
	end end end
	return nil
end
assert(any_canopy(-5, -1, -2, 2) == nil, "tree A outside the boxes is cleared, left at " .. tostring(any_canopy(-5, -1, -2, 2)))
assert(any_canopy(4, 8, -2, 2) == nil, "tree B touching the box is cleared")
for y = 1, 6 do
	assert(real_nodes[key(-3, y, 5)] == TREE, "protected trunk of tree D stays at y=" .. y)
	assert(real_nodes[key(building_x, y, 0)] == TREE, "building log inside the box stays at y=" .. y)
	assert(real_nodes[key(12, y, 0)] == TREE, "tree C beyond the building stays at y=" .. y)
end
assert(real_nodes[key(-5, 6, 5)] == nil and real_nodes[key(-1, 6, 3)] == nil,
	"the rest of tree D's canopy goes")
assert(real_nodes[key(10, 6, 0)] == LEAVES, "tree C's canopy beside the building stays")
assert(real_nodes[key(building_x, 0, 0)] == STONE, "ground under the building stays")
local canopy_after = canopy_count(real_nodes)
assert(real_stats.tree_removed == canopy_before - canopy_after and real_stats.tree_removed > 0,
	"tree_removed reports the real count: " .. tostring(real_stats.tree_removed) .. " vs " .. (canopy_before - canopy_after))
assert(real_stats.written and real_stats.written.minp.x <= -3 and real_stats.written.maxp.x >= -1,
	"the tree clearing's writes are in the boundary's envelope")

print("village_boundary_writer: ok")
