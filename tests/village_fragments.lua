-- Run with: lua tests/village_fragments.lua
local logs = {}
minetest = {get_modpath = function() return "." end}

local names = {"air", "mcl_core:stone", "mcl_core:tree", "mcl_core:leaves", "mcl_core:water_source",
	"mcl_flowers:tallgrass", "mcl_core:bedrock", "mcl_core:cobble", "mcl_nether:obsidian_x",
	"mcl_portals:portal_frame", "mcl_chests:chest", "mcl_core:dirt", "mcl_core:vine_x", "mcl_fences:fence", "mcl_core:snow", "mcl_core:snow_3", "mcl_core:snowblock",
	"mcl_bamboo:bamboo", "mcl_core:cactus", "mcl_core:vine", "mcl_bamboo:bamboo_plank", "mcl_flowers:double_fern_top", "mcl_flowers:double_fern"}
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
	["mcl_core:snow"] = {}, ["mcl_core:snow_3"] = {}, ["mcl_core:snowblock"] = {},
	["mcl_bamboo:bamboo"] = {walkable = true, groups = {plant = 1}},
	["mcl_bamboo:bamboo_plank"] = {walkable = true, groups = {wood = 1}},
	["mcl_core:cactus"] = {walkable = true}, ["mcl_core:vine"] = {walkable = false},
	["mcl_flowers:double_fern_top"] = {walkable = false, groups = {plant = 1, double_plant = 2}},
	["mcl_flowers:double_fern"] = {walkable = false, groups = {plant = 1, double_plant = 1}},
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
local param2 = {} -- "x,y,z" -> param2 of a node, default 0
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
			function vm:get_param2_data()
					local a, b = area[1], area[2]
					local va = VoxelArea:new({MinEdge = a, MaxEdge = b})
					local data = {}
					for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do
						data[va:index(x, y, z)] = param2[x .. "," .. y .. "," .. z] or 0
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

-- Snow layers resting on a removed leaf go too (they would float, #211); snow on
-- the ground, snow blocks and snow on a tree outside the zone stay.
map = {}
tree(0, 0)
put(0, 7, 0, "mcl_core:snow")
put(1, 7, 1, "mcl_core:snow_3")
put(2, 7, 2, "mcl_core:snowblock")
put(0, 1, 5, "mcl_core:snow")
tree(30, 0)
put(30, 7, 0, "mcl_core:snow")
stats = fragments.clear_trees({box(-1, 0, -1, 1, 6, 1)}, nil, engine())
assert(at(0, 7, 0) == nil and at(1, 7, 1) == nil and stats.snow == 2, "snow on the leaves goes, got " .. stats.snow)
assert(at(2, 7, 2) == "mcl_core:snowblock", "a snow block is not a layer")
assert(at(0, 1, 5) == "mcl_core:snow", "snow on the ground stays")
assert(at(30, 7, 0) == "mcl_core:snow", "snow on a tree that stands stays")

-- Snow on a bare trunk node, and on a leaf in the middle of the canopy.
map = {}
for y = 1, 8 do put(10, y, 0, "mcl_core:tree") end
put(10, 9, 0, "mcl_core:snow")
put(20, 1, 0, "mcl_core:tree"); put(20, 2, 0, "mcl_core:tree"); put(20, 3, 0, "mcl_core:tree")
put(21, 2, 0, "mcl_core:leaves")
put(21, 3, 0, "mcl_core:snow_3")
stats = fragments.clear_trees({box(9, 0, -1, 11, 10, 1), box(19, 0, -1, 21, 4, 1)}, nil, engine())
assert(at(10, 9, 0) == nil and at(21, 3, 0) == nil and stats.snow == 2, "snow on a trunk and on a side leaf goes, got " .. stats.snow)

-- A capped fill leaves the leaves outside the zone, and the snow on them.
map = {}
for i = 0, 11 do tree(i * 3, 0) end
put(15, 7, 0, "mcl_core:snow") -- on the canopy of a tree outside the zone
put(0, 7, 0, "mcl_core:snow") -- on the canopy of the tree in the zone
stats = fragments.clear_trees({box(-1, 0, -1, 1, 6, 1)}, {cap_nodes = 60, cap_radius = 10, cap_height = 40}, engine())
assert(stats.clipped == 1 and at(0, 7, 0) == nil, "snow goes with the leaves that were removed")
assert(at(15, 7, 0) == "mcl_core:snow" and at(15, 6, 0) == "mcl_core:leaves", "leaves left by the cap keep their snow")

-- Empty zone.
assert(fragments.clear_trees({}, nil, engine()).removed == 0)

-- Bamboo and cactus in the zone are cleared like trees (#224); outside it they stand, and
-- bamboo planks are a building, not growth.
map = {}
for y = 1, 4 do put(0, y, 0, "mcl_bamboo:bamboo") end
for y = 1, 3 do put(1, y, 0, "mcl_core:cactus") end
for y = 1, 4 do put(30, y, 0, "mcl_bamboo:bamboo") end
put(2, 1, 0, "mcl_bamboo:bamboo_plank")
stats = fragments.clear_trees({box(-1, 0, -1, 3, 6, 1)}, nil, engine())
assert(stats.growth == 7 and stats.seeds == 0, "seven stalk nodes cleared, got " .. stats.growth)
assert(count("mcl_bamboo:bamboo") == 4 and at(30, 4, 0) == "mcl_bamboo:bamboo", "stalks outside the zone stand")
assert(count("mcl_core:cactus") == 0)
assert(at(2, 1, 0) == "mcl_bamboo:bamboo_plank", "bamboo planks stay")
assert(writes == 1, "written once")

-- A vine on a removed trunk and the vines under a removed leaf go; a vine elsewhere stays (#225).
map = {}
tree(0, 0)
param2 = {}
for y = 2, 4 do put(1, y, 0, "mcl_core:vine"); param2["1," .. y .. ",0"] = 3 end -- on the trunk (support at -x)
for y = 1, 4 do put(-2, y, 1, "mcl_core:vine") end -- hangs from a leaf at y=5, param2 0: support above
put(2, 4, 2, "mcl_core:vine"); param2["2,4,2"] = 2; put(3, 4, 2, "mcl_core:stone") -- on a standing stone, leaf above goes
-- a chain on the trunk side at z=-1 (support +z... the trunk is at z=0 so p2 4): the top is on the
-- trunk (y=4), the two under it hang with nothing beside them, the lowest has a stone beside it
for y = 1, 4 do put(0, y, -1, "mcl_core:vine"); param2["0," .. y .. ",-1"] = 4 end
put(0, 1, 0, "mcl_core:stone") -- the trunk is stone at y=1: the vine at y=1 is on a standing node
put(20, 3, 3, "mcl_core:vine") -- on something else, far away
stats = fragments.clear_trees({box(-1, 0, -1, 1, 6, 1)}, nil, engine())
assert(stats.vines == 10, "ten vines removed, got " .. stats.vines)
assert(at(0, 1, -1) == "mcl_core:vine" and at(0, 2, -1) == nil and at(0, 3, -1) == nil and at(0, 4, -1) == nil,
	"trunk vines go with the trunk, their hanging neighbours too; the one on a stone stays")
assert(count("mcl_core:vine") == 3 and at(20, 3, 3) == "mcl_core:vine", "the far vine stays")
assert(at(2, 4, 2) == "mcl_core:vine", "a vine on a standing node stays when the leaf above it goes")
param2 = {}

-- The top half of a double fern left over a tree's leaves floats once they go; a whole
-- fern next to the tree stays.
map = {}
tree(0, 0)
put(0, 7, 0, "mcl_flowers:double_fern_top") -- on the leaf at (0, 6, 0)
put(-2, 7, 0, "mcl_flowers:double_fern_top") -- on a leaf too
put(10, 1, 10, "mcl_flowers:double_fern"); put(10, 2, 10, "mcl_flowers:double_fern_top")
stats = fragments.clear_trees({box(-1, 0, -1, 1, 6, 1)}, nil, engine())
assert(stats.plant_tops == 2, "two floating tops removed, got " .. stats.plant_tops)
assert(at(0, 7, 0) == nil and at(-2, 7, 0) == nil and at(10, 2, 10) == "mcl_flowers:double_fern_top", "the whole fern stays")

print("village_fragments: ok")
