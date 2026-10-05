-- Run with: lua tests/village_fragments.lua
local logs = {}
minetest = {get_modpath = function() return "." end}

local names = {"air", "mcl_core:stone", "mcl_core:tree", "mcl_core:leaves", "mcl_core:water_source",
	"mcl_flowers:tallgrass", "mcl_core:bedrock", "mcl_core:cobble", "mcl_nether:obsidian_x",
	"mcl_portals:portal_frame", "mcl_chests:chest", "mcl_core:dirt", "mcl_core:vine_x", "mcl_fences:fence"}
local ids = {}
for i, n in ipairs(names) do ids[n] = i end
local registered = {
	["air"] = {},
	["mcl_core:stone"] = {is_ground_content = true},
	["mcl_core:dirt"] = {},
	["mcl_core:tree"] = {is_ground_content = false, groups = {tree = 1}},
	["mcl_core:leaves"] = {groups = {leaves = 1}},
	["mcl_core:water_source"] = {is_ground_content = false, liquidtype = "source"},
	["mcl_flowers:tallgrass"] = {is_ground_content = false, groups = {plant = 1}},
	["mcl_core:bedrock"] = {is_ground_content = false},
	["mcl_core:cobble"] = {is_ground_content = false},
	["mcl_portals:portal_frame"] = {is_ground_content = false},
	["mcl_chests:chest"] = {is_ground_content = false, groups = {deco_block = 1, container = 2}},
	["mcl_fences:fence"] = {is_ground_content = false, groups = {deco_block = 1, fence = 1}},
	["mcl_core:vine_x"] = {is_ground_content = false},
}

VoxelArea = {new = function(_, e)
	local a = {MinEdge = e.MinEdge, MaxEdge = e.MaxEdge}
	local dx = e.MaxEdge.x - e.MinEdge.x + 1
	local dy = e.MaxEdge.y - e.MinEdge.y + 1
	function a:index(x, y, z)
		return (z - e.MinEdge.z) * dx * dy + (y - e.MinEdge.y) * dx + (x - e.MinEdge.x) + 1
	end
	return a
end}

-- A sparse map of "x,y,z" -> node name over air; a VoxelManip reads and writes it.
local map, reads, writes
local function engine()
	reads, writes = 0, 0
	return {
		CONTENT_AIR = ids.air, CONTENT_IGNORE = 99,
		registered_nodes = registered,
		get_name_from_content_id = function(id) return names[id] end,
		log = function(_, m) logs[#logs + 1] = m end,
		get_voxel_manip = function()
			local vm, area = {}, nil
			function vm:read_from_map(a, b) reads = reads + 1; area = {a, b}; return a, b end
			function vm:get_data()
				local a, b = area[1], area[2]
				local va = VoxelArea:new({MinEdge = a, MaxEdge = b})
				local data = {}
				for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do
					data[va:index(x, y, z)] = ids[map[x .. "," .. y .. "," .. z] or "air"]
				end end end
				return data
			end
			function vm:set_data(data)
				local a, b = area[1], area[2]
				local va = VoxelArea:new({MinEdge = a, MaxEdge = b})
				for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do
					local name = names[data[va:index(x, y, z)]]
					local key = x .. "," .. y .. "," .. z
					if name ~= (map[key] or "air") then map[key] = name ~= "air" and name or nil end
				end end end
			end
			function vm:write_to_map() writes = writes + 1 end
			return vm
		end,
	}
end
local function put(x, y, z, name) map[x .. "," .. y .. "," .. z] = name end
local function at(x, y, z) return map[x .. "," .. y .. "," .. z] end
local function box(x0, y0, z0, x1, y1, z1)
	return {minp = {x = x0, y = y0, z = z0}, maxp = {x = x1, y = y1, z = z1}}
end

-- A tree: a trunk at (x, z) from y=1 to 5, leaves around y=5..6 within 2.
local function tree(x, z, height)
	height = height or 5
	for y = 1, height do put(x, y, z, "mcl_core:tree") end
	for dx = -2, 2 do for dz = -2, 2 do
		for y = height, height + 1 do
			if not at(x + dx, y, z + dz) then put(x + dx, y, z + dz, "mcl_core:leaves") end
		end
	end end
end
local function count(name)
	local n = 0
	for _, v in pairs(map) do if v == name then n = n + 1 end end
	return n
end

local fragments = dofile("village_fragments.lua")

-- Structure test: not ground content and not natural.
local e = engine()
local test = fragments.structure_test(e)
for _, name in ipairs({"air", "mcl_core:stone", "mcl_core:dirt", "mcl_core:tree", "mcl_core:leaves",
		"mcl_core:water_source", "mcl_flowers:tallgrass", "mcl_core:bedrock", "mcl_core:vine_x", "unknown:node"}) do
	assert(not test(name), name .. " is not a structure")
end
for _, name in ipairs({"mcl_core:cobble", "mcl_portals:portal_frame", "mcl_chests:chest", "mcl_fences:fence"}) do
	assert(test(name), name .. " is a structure")
end
assert(fragments.structure_test(e, {"cobble"})("mcl_core:cobble") == false, "extra whitelist words")

-- Unloaded columns: clear unless strict, when they count as blocked.
map = {}
local ignoring = engine()
local plain_get = ignoring.get_voxel_manip
ignoring.get_voxel_manip = function()
	local vm = plain_get()
	local plain_data = vm.get_data
	function vm:get_data()
		local data = plain_data(vm)
		local va = VoxelArea:new({MinEdge = {x = -20, y = 0, z = -20}, MaxEdge = {x = 20, y = 10, z = 20}})
		-- everything at x >= 5 is unloaded
		for z = -20, 20 do for y = 0, 10 do for x = 5, 20 do data[va:index(x, y, z)] = 99 end end end
		return data
	end
	return vm
end
local loose = fragments.scan_structures(box(-20, 0, -20, 20, 10, 20), test, ignoring)
assert(loose.count == 0 and loose.find(-20, -20, 20, 20) == nil, "unloaded is clear when not strict")
local strict = fragments.scan_structures(box(-20, 0, -20, 20, 10, 20), test, ignoring, true)
assert(strict.at(10, 0) == "unloaded" and strict.at(0, 0) == nil, "unloaded columns block when strict")
assert(strict.find(-20, -20, 4, 20) == nil)

-- Scan: finds structure columns in one read, and ignores natural nodes.
map = {}
tree(0, 0)
put(5, 3, 5, "mcl_core:water_source")
put(10, 2, 10, "mcl_portals:portal_frame")
put(10, 4, 10, "mcl_core:cobble")
put(11, 4, 10, "mcl_chests:chest")
reads = 0
local scan = fragments.scan_structures(box(-20, 0, -20, 20, 10, 20), test, e)
assert(reads == 1, "one VoxelManip pass")
assert(scan.count == 2, "two structure columns, got " .. scan.count)
local name, y = scan.at(10, 10)
assert(name == "mcl_core:cobble" and y == 4, "the top structure node of a column is reported")
assert(scan.at(0, 0) == nil and scan.at(5, 5) == nil, "trees and water are not structures")
assert(scan.find(-5, -5, 9, 9) == nil, "nothing in a clear rectangle")
local fname, fx, fy, fz = scan.find(8, 8, 12, 12)
assert(fname and fx and fy and fz, "find reports a hit in the rectangle")
assert(scan.find(11, 10, 11, 10) == "mcl_chests:chest", "single column rectangle")
assert(scan.find(12, 10, 20, 20) == nil, "outside the rectangle")

-- A single tree: removed whole, even where it sticks out of the zone.
map = {}
tree(0, 0)
local total = count("mcl_core:tree") + count("mcl_core:leaves")
local stats = fragments.clear_trees({box(-1, 0, -1, 1, 6, 1)}, nil, engine())
assert(stats.seeds == 1 and stats.clipped == 0, "one fill, " .. stats.seeds)
assert(stats.removed == total, "all " .. total .. " nodes removed, got " .. stats.removed)
assert(count("mcl_core:tree") == 0 and count("mcl_core:leaves") == 0, "no stub or floating leaf")
assert(writes == 1)

-- Only a leaf of the tree inside the zone still removes the whole tree.
map = {}
tree(0, 0)
fragments.clear_trees({box(2, 5, 2, 2, 6, 2)}, nil, engine())
assert(count("mcl_core:tree") == 0 and count("mcl_core:leaves") == 0, "a canopy edge in the zone clears the tree")

-- A tree outside the zone is untouched, and so are other nodes.
map = {}
tree(0, 0)
tree(30, 0)
put(0, 0, 0, "mcl_core:stone")
local before = count("mcl_core:leaves")
stats = fragments.clear_trees({box(-1, 0, -1, 1, 6, 1)}, nil, engine())
assert(stats.seeds == 1)
assert(at(30, 3, 0) == "mcl_core:tree" and count("mcl_core:tree") == 5, "the far tree stands")
assert(count("mcl_core:leaves") == before / 2, "its leaves stay")
assert(at(0, 0, 0) == "mcl_core:stone", "ground stays")

-- Two touching trees are cleared in one fill; the second seed is not counted again.
map = {}
tree(0, 0)
tree(3, 0)
stats = fragments.clear_trees({box(-1, 0, -1, 4, 6, 1)}, nil, engine())
assert(count("mcl_core:tree") == 0 and count("mcl_core:leaves") == 0)
assert(stats.seeds == 1 and stats.clipped == 0, "touching trees are one fill")

-- No trees in the zone: nothing written.
map = {}
put(0, 0, 0, "mcl_core:stone")
local quiet = engine()
stats = fragments.clear_trees({box(-3, 0, -3, 3, 6, 3)}, nil, quiet)
assert(stats.removed == 0 and writes == 0, "no write without a change")

-- The cap: a canopy linking a row of trees is clipped to the zone.
map = {}
for i = 0, 11 do tree(i * 3, 0) end
local small = {cap_nodes = 60, cap_radius = 10, cap_height = 40}
local zone = box(-1, 0, -1, 1, 6, 1)
local linked = count("mcl_core:tree") + count("mcl_core:leaves")
logs = {}
stats = fragments.clear_trees({zone}, small, engine())
assert(stats.clipped == 1, "the fill hit the cap")
assert(at(0, 3, 0) == nil, "the tree in the zone is gone")
assert(count("mcl_core:tree") + count("mcl_core:leaves") > linked - small.cap_nodes * 2, "the rest of the row stays")
assert(count("mcl_core:tree") >= 11 * 5 - 5, "the other trunks stand")
assert(#logs == 1 and logs[1]:find("%[living_villages%]") and logs[1]:find("clipped"), logs[1])
-- Each fill removes at most the cap.
assert(stats.removed <= small.cap_nodes, "a capped fill removes at most the cap, got " .. stats.removed)

-- The default cap holds on a long row, too.
map = {}
for i = 0, 39 do tree(i * 3, 0) end
stats = fragments.clear_trees({box(-1, 0, -1, 1, 6, 1)}, nil, engine())
assert(stats.clipped >= 1 and stats.removed <= fragments.config.cap_nodes, "default cap, removed " .. stats.removed)

-- A tree that strays past the sideways limit is clipped to the zone.
map = {}
for i = 0, 20 do put(i, 3, 0, "mcl_core:tree") end -- one trunk line 20 long
stats = fragments.clear_trees({box(-1, 0, -1, 1, 6, 1)}, nil, engine())
assert(stats.clipped == 1 and at(0, 3, 0) == nil and at(1, 3, 0) == nil
	and at(2, 3, 0) == "mcl_core:tree" and at(20, 3, 0) == "mcl_core:tree", "only the zone part of a runaway tree goes")

-- Empty zone.
assert(fragments.clear_trees({}, nil, engine()).removed == 0)

print("village_fragments: ok")
