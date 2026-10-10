-- Run with: lua tests/village_smoothing.lua
local logs = {}
minetest = {
	get_modpath = function() return "." end,
	log = function(level, m) table.insert(logs, level .. ": " .. m) end,
}
local smoothing = dofile("village_smoothing.lua")
local cfg = smoothing.config

local schematics = {{name = "house", hwidth = 4, hdepth = 4, hheight = 6}}
local function plan_of(...)
	local plan = {}
	for _, p in ipairs({...}) do
		plan[#plan + 1] = {name = "house", pos = {x = p[1], y = p[3], z = p[2]}, rotat = "0", surface_mat = p[4]}
	end
	return plan
end
local function pads_of(...)
	local pads = assert(smoothing.pads(plan_of(...), schematics))
	return pads
end

-- Pads: footprint, yard and unknown buildings.
local pads = pads_of({0, 0, 10})
assert(pads[1].x1 == 3 and pads[1].yx0 == -2 and pads[1].yx1 == 5 and pads[1].y == 10, "pad geometry")
assert(select(2, smoothing.pads({{name = "nope", pos = {x = 0, y = 0, z = 0}, rotat = "0"}}, schematics)), "unknown building")

local function flat(y) return function() return y end end

-- Flat ground at the pad height: nothing changes.
local t = smoothing.targets(pads, flat(10), cfg)
for z = t.z0, t.z1 do for x = t.x0, t.x1 do assert(t.at(x, z) == 10 and t.was(x, z) == 10) end end
assert(t.violations == 0)

-- Hill: ground 4 above the pad. Footprint and yard are exact, the skirt slopes
-- down to nothing at the radius, and nothing past it changes.
t = smoothing.targets(pads, flat(14), cfg)
assert(t.at(1, 1) == 10 and t.kind(1, 1) == "footprint", "footprint exact")
assert(t.at(-2, 1) == 10 and t.kind(-2, 1) == "yard", "yard flat")
assert(t.kind(-4, 1) == "skirt" and t.at(-4, 1) > 10 and t.at(-4, 1) < 14, "skirt between")
assert(t.at(-2 - cfg.radius, 1) == 14, "untouched at the radius")
for z = t.z0, t.z1 do for x = t.x0, t.x1 do
	assert(math.abs(t.at(x, z) - t.was(x, z)) <= cfg.cap, "cap")
end end
assert(t.violations == 0, "slope walkable, got " .. t.violations)

-- A pit far deeper than the cap: yard clamped to the cap, never beyond.
t = smoothing.targets(pads, flat(0), cfg)
assert(t.at(-2, 1) == 5, "yard capped")
assert(t.at(1, 1) == 10, "footprint is never capped")

-- Two pads at different heights: the ground between lies between them, and the
-- steps stay walkable.
local two = pads_of({0, 0, 10}, {10, 0, 14})
t = smoothing.targets(two, flat(12), cfg)
assert(t.at(1, 1) == 10 and t.at(11, 1) == 14)
local lo, hi = 99, -99
for x = 4, 9 do
	local v = t.at(x, 1)
	assert(v >= 10 and v <= 14, "between the pads")
	lo, hi = math.min(lo, v), math.max(hi, v)
end
assert(t.at(5, 1) <= t.at(6, 1) + 1 and t.at(8, 1) >= t.at(5, 1), "rises toward the higher pad")
-- A cliff in the natural ground is relaxed in the skirt, within the cap.
t = smoothing.targets(pads, function(x) return x < -6 and 20 or 10 end, cfg)
for z = t.z0, t.z1 do for x = t.x0, t.x1 do
	assert(math.abs(t.at(x, z) - t.was(x, z)) <= cfg.cap)
end end

-- nil heights (water) are left alone and ignored as neighbors.
t = smoothing.targets(pads, function(x, z) if x == -4 then return nil end return 12 end, cfg)
assert(t.at(-4, 1) == nil and t.was(-4, 1) == nil)
-- An overhang (second return of height_at) in the skirt or the yard (x=-1) is not a column
-- (#209): no target, no pad. In the footprint it is set like any other.
t = smoothing.targets(pads, function(x, z) return 30, x == -6 or x == -1 or x == 1 end, cfg)
assert(t.at(-6, 1) == nil and t.was(-6, 1) == nil and t.pad(-6, 1) == nil and t.kind(-6, 1) == nil, "skirt overhang left alone")
assert(t.at(-5, 1) ~= nil and t.at(-7, 1) ~= nil, "its neighbours are still smoothed")
assert(t.at(-1, 1) == nil and t.kind(-1, 1) == nil, "yard overhang left alone")
assert(t.at(1, 1) == 10, "footprint overhang is set")
-- Empty plan.
assert(smoothing.targets({}, flat(1), cfg).at(0, 0) == nil)

-- apply: record swaps on a fake map.
local swaps, map = {}, {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local engine = {
	registered_nodes = {air = {walkable = false}, ["mcl_core:dirt"] = {walkable = true}, ["mcl_core:stone"] = {walkable = true}},
	swap_node = function(p, n) map[key(p.x, p.y, p.z)] = n.name; swaps[#swaps + 1] = n.name end,
	get_node = function(p) return {name = map[key(p.x, p.y, p.z)] or (p.y <= 0 and "mcl_core:stone" or "air")} end, -- ground at y 0
}
local small = pads_of({0, 0, 10, "mcl_core:sand"})
local tt = smoothing.targets(small, flat(14), cfg)
local stats = smoothing.apply(small, tt, function() return {y = 14} end, cfg, engine)
assert(stats.cut > 0 and stats.filled == 0 and stats.steepest == 4, "cut counts")
assert(map[key(1, 10, 1)] == "mcl_core:sand", "surface at the pad height")
assert(map[key(1, 14, 1)] == "air" and map[key(1, 17, 1)] == "air", "above removed")
assert(map[key(1, 9, 1)] == "mcl_core:sandstone", "sandstone under sand (air below filled)")

map = {}
tt = smoothing.targets(small, flat(7), cfg)
stats = smoothing.apply(small, tt, function() return {y = 7} end, cfg, engine)
assert(stats.filled > 0 and map[key(1, 10, 1)] == "mcl_core:sand" and map[key(1, 8, 1)] == "mcl_core:sandstone")

-- terraform on a fake map: flat ground at 14 and a structure block at (8,16,1).
-- The structure and its neighbors are kept.
local ids = {air = 1, ["mcl_core:dirt_with_grass"] = 2, struct = 3, ["mcl_core:dirt"] = 4,
	["mcl_core:tree"] = 5, ["mcl_core:cactus"] = 6, ["mcl_bamboo:bamboo"] = 7, ["mcl_farming:sweet_berry_bush_3"] = 8}
local names = {"air", "mcl_core:dirt_with_grass", "struct", "mcl_core:dirt", "mcl_core:tree", "mcl_core:cactus",
	"mcl_bamboo:bamboo", "mcl_farming:sweet_berry_bush_3"}
local IGNORE = 99
local world = {}
local function at(x, y, z)
	if x < -30 then return "ignore" end
	local k = world[x .. "," .. y .. "," .. z]
	if k then return k end
	if x == 8 and y == 16 and z == 1 then return "struct" end
	-- A 5-high trunk and a 3-high cactus on the flat ground in the holes' reach.
	if x == 26 and z == 5 and y >= 15 and y <= 19 then return "mcl_core:tree" end
	if x == 26 and z == 9 and y >= 15 and y <= 17 then return "mcl_core:cactus" end
	-- Bamboo stalks (15..18) and sweet berry bushes (15) on the flat ground, in the
	-- footprints of the first pad (cut to 10) and of a third one at 20 (filled).
	if (x == 81 and z == 1 or x == 2 and z == 3) and y >= 15 and y <= 18 then return "mcl_bamboo:bamboo" end
	if (x == 82 and z == 2 or x == 2 and z == 2) and y == 15 then return "mcl_farming:sweet_berry_bush_3" end
	-- Blocks under the shaft floor are not generated yet.
	if x >= 13 and x <= 14 and z >= 0 and z <= 2 and y < -20 then return "ignore" end
	-- A shaft in the gap beyond the smoothing, down to a floor at -8.
	if x >= 13 and x <= 14 and z >= 0 and z <= 2 and y > -8 and y <= 14 then return "air" end
	return y <= 14 and "mcl_core:dirt_with_grass" or "air"
end
VoxelArea = {new = function(_, e)
	local dx, dy = e.MaxEdge.x - e.MinEdge.x + 1, e.MaxEdge.y - e.MinEdge.y + 1
	return {index = function(_, x, y, z)
		return (z - e.MinEdge.z) * dx * dy + (y - e.MinEdge.y) * dx + (x - e.MinEdge.x) + 1
	end}
end}
local fake = {
	CONTENT_IGNORE = IGNORE, CONTENT_AIR = 1,
	registered_nodes = {
		air = {walkable = false}, ["mcl_core:dirt_with_grass"] = {walkable = true},
		struct = {walkable = true, is_ground_content = false, groups = {}},
		["mcl_core:tree"] = {walkable = true, groups = {tree = 1}}, ["mcl_core:cactus"] = {walkable = true},
		["mcl_bamboo:bamboo"] = {walkable = true, groups = {plant = 1}},
		["mcl_farming:sweet_berry_bush_3"] = {walkable = false, groups = {plant = 1}},
		["mcl_core:dirt"] = {walkable = true},
	},
	get_name_from_content_id = function(id) return names[id] or "ignore" end,
	pos_to_string = function(p) return ("(%d,%d,%d)"):format(p.x, p.y, p.z) end,
	log = function(_, m) logs[#logs + 1] = m end,
	swap_node = function(p, n) world[p.x .. "," .. p.y .. "," .. p.z] = n.name end,
	get_node = function(p) return {name = at(p.x, p.y, p.z)} end,
	get_voxel_manip = function()
		local vm, a, b = {}
		function vm:read_from_map(x, y) a, b = x, y; return x, y end
		function vm:get_data()
			local data, va = {}, VoxelArea:new({MinEdge = a, MaxEdge = b})
			for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do
				local n = at(x, y, z)
				data[va:index(x, y, z)] = n == "ignore" and IGNORE or ids[n]
			end end end
			return data
		end
		return vm
	end,
}
local fragments = dofile("village_fragments.lua")
local test = fragments.structure_test(fake)
local fell, loads = nil, 0
local env = {
	settlements = {schematic_table = schematics, surface_mat = {["mcl_core:dirt_with_grass"] = true}},
	engine = fake,
	original = function() fell = true end,
	load_node = function(pos) loads = loads + 1; return {name = at(pos.x, pos.y, pos.z)} end,
	scan = function(area) return fragments.scan_structures(area, test, fake) end,
	clear_trees = function() end,
}
-- An overhang in the skirt (#209): a 2-thick slab (y 30..31) over 4 air (26..29) above
-- the real ground at 14, at x=-6; a normal hill (top 18) at x=-6, z=2 is still cut.
for y = 15, 40 do world["-6,"..y..",1"] = "air" end
for y = 30, 31 do world["-6,"..y..",1"] = "mcl_core:dirt_with_grass" end
for y = 15, 17 do world["-6,"..y..",2"] = "mcl_core:dirt" end
world["-6,18,2"] = "mcl_core:dirt_with_grass"
assert(smoothing.terraform(plan_of({0, 0, 10, "mcl_core:dirt_with_grass"}, {40, 0, 14, "mcl_core:dirt_with_grass"}, {80, 0, 20, "mcl_core:dirt_with_grass"}), nil, env) == true and not fell,
	"smooths without waiting")
assert(loads > 0)
assert(world["8,16,1"] == nil, "structure block not removed")
assert(world["8,14,1"] == nil and world["8,15,1"] == nil, "ground beside the structure untouched")
assert(world["1,10,1"] == "mcl_core:dirt_with_grass" and world["1,14,1"] == "air", "footprint cut to the pad")
-- Growth on a column the smoothing moves (#214, #224). The clearing of trees is stubbed
-- out here, so the smoothing alone must cope. A 4-high bamboo stalk on ground 14 under a
-- pad at 20: the ground is read under the stalk, so the fill reaches 20 with no stalk left
-- inside it or over it; a berry bush on a raised column stands on the new surface.
for y = 15, 19 do assert(at(81, y, 1) == "mcl_core:dirt", "no stalk inside the fill at y=" .. y .. ": " .. at(81, y, 1)) end
assert(at(81, 20, 1) == "mcl_core:dirt_with_grass" and at(81, 21, 1) == "air", "surface at the pad, nothing over it")
assert(at(82, 20, 2) == "mcl_core:dirt_with_grass" and at(82, 21, 2) == "mcl_farming:sweet_berry_bush_3", "bush re-seated on the raised ground")
assert(at(82, 15, 2) == "mcl_core:dirt", "the old bush spot is fill")
-- Cut to 10: the stalk is gone above the surface and the bush stands on it.
for y = 11, 18 do assert(at(2, y, 3) == (y == 11 and "air" or "air"), "stalk removed from the cut column at y=" .. y) end
assert(at(2, 10, 3) == "mcl_core:dirt_with_grass")
assert(at(2, 10, 2) == "mcl_core:dirt_with_grass" and at(2, 11, 2) == "mcl_farming:sweet_berry_bush_3", "bush moved down with the cut")
assert(at(2, 15, 2) == "air", "no bush left at the old height")
-- The whole overhang column is as nature made it: slab at 30..31, air 15..29 and above 31,
-- and the ground (14 and below) untouched.
for y = 15, 40 do
	local want = (y == 30 or y == 31) and "mcl_core:dirt_with_grass" or "air"
	assert(world["-6," .. y .. ",1"] == want, "overhang column changed at y=" .. y .. ": " .. tostring(world["-6," .. y .. ",1"]))
end
for y = 0, 14 do assert(world["-6," .. y .. ",1"] == nil, "ground under the overhang written at y=" .. y) end
assert(world["-6,18,2"] == "air", "a normal hill beside it is still cut")
-- The ground beside it was smoothed to 13, so the shaft is filled from its floor to 13.
assert(world["13,13,1"] == "mcl_core:dirt_with_grass" and world["13,12,1"] == "mcl_core:dirt"
	and world["13,0,1"] == "mcl_core:dirt" and world["13,-7,1"] == "mcl_core:dirt", "shaft filled to the rim")
assert(world["13,14,1"] == nil, "nothing above the rim")
-- A tree or a cactus is not a peak: no ramp is built round it.
for key in pairs(world) do
	local x, z = key:match("^(-?%d+),%-?%d+,(-?%d+)$")
	x, z = tonumber(x), tonumber(z)
	assert(not (x >= 23 and x <= 29 and z >= 2 and z <= 12), "nothing built round a trunk or a cactus: " .. key)
end
local joined = table.concat(logs, "\n")
assert(joined:find("holes: ", 1, true), "reports the fill")
assert(joined:find("unloaded blocks skipped", 1, true), "reports skipped blocks")

-- An empty plan falls back to the original.
assert(smoothing.terraform({}, nil, env) == false and fell, "fallback on empty plan")

print("village_smoothing: ok")
